use std::cell::Cell;
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use operit_host_api::HostEnvironmentDescriptor;
use operit_host_api::HostManager::HostManager;
use operit_plugin_sdk::javascript::{
    JsExecutionHost, JsToolCallRequest, JsToolCallResult, JsToolCallResultData,
    JsToolNameResolutionRequest, JsToolPkgIpcRequest, JsToolPkgResourceRequest,
    JsToolPkgWasmRequest, JsToolPkgWasmResult,
};
use operit_plugin_sdk::js_sdk::tool_types::BuiltinToolName;
use operit_plugin_sdk::package::ToolPackage;
use operit_store::RuntimeStorePaths::RuntimeStorePaths;
use operit_tools::files::PathMapper::PathMapper;
use operit_tools::tools::mcp::MCPManager::MCPManager;
use operit_tools::tools::mcp::MCPToolExecutor::MCPToolExecutor;
use operit_tools::tools::packTool::RuntimePackageManager::RuntimePackageManager;
use operit_tools::tools::AIToolHook::{AIToolHook, AIToolHookDecision};
use operit_tools::tools::PackageToolExecutor::PackageToolExecutor;
use operit_tools::tools::ToolPermissionSystem::{AiPermissionMode, ToolPermissionSystem};
use operit_tools::tools::ToolRegistration::registerAllTools;
use operit_tools::tools::ToolResultDataClasses::{stringResultData, ToolResultData};
use operit_tools::ConversationMarkupManager::ToolResult;
use operit_tools::ToolExecutionManager::{
    AITool, ToolAccessSpec, ToolBoundary, ToolEffect, ToolExecutionManager, ToolExecutor,
    ToolParameter, ToolRuntimeContextGuard, ToolValidationResult,
};
use operit_util::ChainLogger::{self, TOOL_CHAIN};
use operit_util::LocaleUtils::LocaleUtils;
use operit_util::OperitPaths;
use serde::{Deserialize, Serialize};

use crate::runtime_support::{ToolRuntimeDependencies, ToolRuntimeSupport};

const PACKAGE_PROXY_TOOL_NAME: &str = "package_proxy";

/// Monotonic id for each `executeTool` invocation, used to correlate the
/// synchronous tool-execution stages in device logs. The chain runs inline on
/// the single WASM worker thread, so timing gaps between stages localize the
/// 60s block.
static TOOL_EXEC_INV: AtomicUsize = AtomicUsize::new(0);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ToolRegistrationVisibility {
    PUBLIC,
    INTERNAL,
}

#[derive(Clone)]
pub struct AIToolHandler {
    inner: Arc<Mutex<AIToolHandlerState>>,
    nestedExecutionAuthorization: PackageNestedExecutionAuthorizationState,
}

/// Default hard timeout (ms) for one tool invocation, mirroring operit1's
/// `JsTimeoutConfig` (`MAIN_TIMEOUT_SECONDS = 1800` -> `TOOL_CALL_TIMEOUT_MS`).
///
/// Semantic difference worth knowing: operit1 pairs this bound with cooperative
/// cancellation (`ensureActive()` checkpoints), so a hung script unwinds and
/// frees its thread. Here the bound only stops the *caller* from waiting — the
/// worker thread is NOT aborted (Rust std has no thread cancellation) and keeps
/// running to completion. True cancellation still needs the async-runtime
/// migration (§14.3 / §15.1).
pub const DEFAULT_TOOL_EXECUTION_TIMEOUT_MS: u64 = 1_800_000;

pub struct AIToolHandlerState {
    /// Hard timeout (ms) applied to a single `ToolExecutor::invokeAndStream`
    /// call. Defaults to [`DEFAULT_TOOL_EXECUTION_TIMEOUT_MS`] (operit1 parity);
    /// `0` disables the bound entirely.
    toolExecutionTimeoutMs: u64,
    availableTools: BTreeMap<String, Box<dyn ToolExecutor>>,
    toolVisibility: BTreeMap<String, ToolRegistrationVisibility>,
    unavailableBuiltinTools: BTreeMap<BuiltinToolName, String>,
    defaultToolsRegistered: bool,
    context: HostManager,
    runtimeDependencies: ToolRuntimeDependencies,
    hooks: Vec<Arc<dyn AIToolHook>>,
    toolPermissionSystem: ToolPermissionSystem,
    packageManager: Option<Arc<Mutex<RuntimePackageManager>>>,
}

thread_local! {
    static ASYNC_TOOL_EXECUTION_SCOPE_DEPTH: Cell<usize> = const { Cell::new(0) };
}

/// Marks synchronous nested tool calls as descendants of an approved async invocation.
struct AsyncToolExecutionScope;

/// Tracks one package executor's nested authorization across worker threads.
#[derive(Clone)]
struct PackageNestedExecutionAuthorizationState {
    depth: Arc<AtomicUsize>,
}

/// Keeps one package executor's nested authorization active across worker threads.
pub(crate) struct PackageNestedExecutionAuthorization {
    depth: Arc<AtomicUsize>,
}

impl AsyncToolExecutionScope {
    /// Enters one approved asynchronous tool execution call stack.
    fn enter() -> Self {
        ASYNC_TOOL_EXECUTION_SCOPE_DEPTH.with(|depth| depth.set(depth.get() + 1));
        Self
    }

    /// Reports whether the current thread is executing an approved async tool stack.
    fn isActive() -> bool {
        ASYNC_TOOL_EXECUTION_SCOPE_DEPTH.with(|depth| depth.get() > 0)
    }

    /// Reads this thread's scope depth so it can be carried into a worker thread.
    ///
    /// Thread-locals are **not** inherited by spawned threads, so anything that
    /// moves tool execution onto another thread (see `run_with_timeout`) must
    /// propagate the depth explicitly or nested package authorization silently
    /// stops being inherited.
    fn currentDepth() -> usize {
        ASYNC_TOOL_EXECUTION_SCOPE_DEPTH.with(|depth| depth.get())
    }

    /// Installs `depth` on this thread, restoring the previous value on drop.
    fn restoreDepth(depth: usize) -> AsyncToolExecutionScopeDepthGuard {
        AsyncToolExecutionScopeDepthGuard::new(depth)
    }
}

/// Installs an async-tool-execution depth on one thread and restores the previous
/// value on drop. Lets a worker thread inherit the caller's authorization depth.
struct AsyncToolExecutionScopeDepthGuard {
    previous: usize,
}

impl AsyncToolExecutionScopeDepthGuard {
    fn new(depth: usize) -> Self {
        let previous = ASYNC_TOOL_EXECUTION_SCOPE_DEPTH.with(|value| {
            let previous = value.get();
            value.set(depth);
            previous
        });
        Self { previous }
    }
}

impl Drop for AsyncToolExecutionScopeDepthGuard {
    fn drop(&mut self) {
        ASYNC_TOOL_EXECUTION_SCOPE_DEPTH.with(|value| value.set(self.previous));
    }
}

impl Drop for AsyncToolExecutionScope {
    /// Leaves the approved asynchronous tool execution call stack.
    fn drop(&mut self) {
        ASYNC_TOOL_EXECUTION_SCOPE_DEPTH.with(|depth| {
            let current = depth.get();
            debug_assert!(current > 0, "async tool execution scope underflow");
            depth.set(current - 1);
        });
    }
}

impl PackageNestedExecutionAuthorizationState {
    /// Creates an inactive authorization state for one package executor.
    fn new() -> Self {
        Self {
            depth: Arc::new(AtomicUsize::new(0)),
        }
    }

    /// Activates cross-thread authorization for one approved package invocation.
    fn enter(&self) -> PackageNestedExecutionAuthorization {
        assert!(
            AsyncToolExecutionScope::isActive(),
            "package execution must inherit an approved async tool scope"
        );
        self.depth.fetch_add(1, Ordering::AcqRel);
        PackageNestedExecutionAuthorization {
            depth: self.depth.clone(),
        }
    }

    /// Reports whether one package invocation currently owns authorization.
    fn isActive(&self) -> bool {
        self.depth.load(Ordering::Acquire) > 0
    }
}

impl Drop for PackageNestedExecutionAuthorization {
    /// Releases one package-scoped cross-thread authorization grant.
    fn drop(&mut self) {
        let previous = self.depth.fetch_sub(1, Ordering::AcqRel);
        assert!(
            previous > 0,
            "package nested execution authorization underflow"
        );
    }
}

impl AIToolHandler {
    fn truncateLogValue(value: &str, maxChars: usize) -> String {
        let mut truncated = String::new();
        for character in value.chars().take(maxChars) {
            truncated.push(character);
        }
        if value.chars().count() > maxChars {
            truncated.push_str("...");
        }
        truncated
    }

    fn summarizeToolParameters(tool: &AITool) -> String {
        if tool.parameters.is_empty() {
            return String::new();
        }
        let mut parts = Vec::new();
        for parameter in tool.parameters.iter().take(3) {
            parts.push(format!(
                "{}={}",
                parameter.name,
                Self::truncateLogValue(&parameter.value, 120)
            ));
        }
        let mut summary = parts.join(", ");
        if tool.parameters.len() > 3 {
            summary.push_str(", ...");
        }
        Self::truncateLogValue(&summary, 320)
    }

    /// Creates an isolated tool handler with explicit runtime dependencies.
    pub fn new(context: HostManager, runtimeDependencies: ToolRuntimeDependencies) -> Self {
        Self {
            inner: Arc::new(Mutex::new(AIToolHandlerState {
                toolExecutionTimeoutMs: DEFAULT_TOOL_EXECUTION_TIMEOUT_MS,
                availableTools: BTreeMap::new(),
                toolVisibility: BTreeMap::new(),
                unavailableBuiltinTools: BTreeMap::new(),
                defaultToolsRegistered: false,
                context,
                runtimeDependencies,
                hooks: Vec::new(),
                toolPermissionSystem: ToolPermissionSystem::getInstance(),
                packageManager: None,
            })),
            nestedExecutionAuthorization: PackageNestedExecutionAuthorizationState::new(),
        }
    }

    /// Creates a handler sharing tools while owning an isolated package authorization token.
    pub(crate) fn withIsolatedNestedExecutionAuthorization(&self) -> Self {
        Self {
            inner: self.inner.clone(),
            nestedExecutionAuthorization: PackageNestedExecutionAuthorizationState::new(),
        }
    }

    /// Carries the approved async call context into one package's worker threads.
    pub(crate) fn enterPackageNestedExecutionAuthorization(
        &self,
    ) -> PackageNestedExecutionAuthorization {
        self.nestedExecutionAuthorization.enter()
    }

    /// Reports whether this call stack or package worker owns nested authorization.
    fn hasNestedExecutionAuthorization(&self) -> bool {
        AsyncToolExecutionScope::isActive() || self.nestedExecutionAuthorization.isActive()
    }

    /// Removes one registered tool and its visibility metadata.
    #[allow(non_snake_case)]
    pub fn unregisterTool(&mut self, toolName: String) {
        let mut guard = self.inner.lock().expect("AIToolHandler mutex poisoned");
        guard.availableTools.remove(&toolName);
        guard.toolVisibility.remove(&toolName);
    }

    /// Removes all tools registered for an MCP server namespace.
    #[allow(non_snake_case)]
    pub fn unregisterMcpServerTools(&mut self, serverName: &str) -> usize {
        let mut guard = self.inner.lock().expect("AIToolHandler mutex poisoned");
        let toolNames = guard
            .availableTools
            .keys()
            .filter(|toolName| {
                matches!(toolName.split_once(':'), Some((name, _)) if name == serverName)
            })
            .cloned()
            .collect::<Vec<_>>();
        let count = toolNames.len();
        for toolName in toolNames {
            guard.availableTools.remove(&toolName);
            guard.toolVisibility.remove(&toolName);
        }
        count
    }

    /// Removes the package registration created for an MCP server.
    #[allow(non_snake_case)]
    pub fn unregisterMcpServerPackage(&mut self, serverName: &str) -> bool {
        let packageManager = {
            self.inner
                .lock()
                .expect("AIToolHandler mutex poisoned")
                .packageManager
                .clone()
        };
        let Some(packageManager) = packageManager else {
            return false;
        };
        let mut guard = packageManager
            .lock()
            .expect("package manager mutex poisoned");
        guard.unregisterMCPServerPackage(serverName)
    }

    /// Returns the permission system used before write or package tool execution.
    #[allow(non_snake_case)]
    pub fn getToolPermissionSystem(&self) -> ToolPermissionSystem {
        self.inner
            .lock()
            .expect("AIToolHandler mutex poisoned")
            .toolPermissionSystem
            .clone()
    }

    /// Adds a tool lifecycle hook when a hook with the same id is not already registered.
    #[allow(non_snake_case)]
    pub fn addToolHook(&mut self, hook: Arc<dyn AIToolHook>) {
        let mut guard = self.inner.lock().expect("AIToolHandler mutex poisoned");
        if !guard
            .hooks
            .iter()
            .any(|existing| existing.id() == hook.id())
        {
            guard.hooks.push(hook);
        }
    }

    /// Removes a tool lifecycle hook by hook id.
    #[allow(non_snake_case)]
    pub fn removeToolHook(&mut self, hookId: &str) {
        self.inner
            .lock()
            .expect("AIToolHandler mutex poisoned")
            .hooks
            .retain(|hook| hook.id() != hookId);
    }

    /// Removes every registered tool lifecycle hook.
    #[allow(non_snake_case)]
    pub fn clearToolHooks(&mut self) {
        self.inner
            .lock()
            .expect("AIToolHandler mutex poisoned")
            .hooks
            .clear();
    }

    fn notifyHooks<F>(&self, action: F)
    where
        F: Fn(&dyn AIToolHook),
    {
        let hooks = self
            .inner
            .lock()
            .expect("AIToolHandler mutex poisoned")
            .hooks
            .clone();
        for hook in hooks {
            action(hook.as_ref());
        }
    }

    /// Notifies hooks that a tool call has been requested.
    #[allow(non_snake_case)]
    pub fn notifyToolCallRequested(&self, tool: &AITool, inv: usize) {
        let hooks = self
            .inner
            .lock()
            .expect("AIToolHandler mutex poisoned")
            .hooks
            .clone();
        ChainLogger::info(
            TOOL_CHAIN,
            "tool.notify.enter",
            &[
                ("inv", inv.to_string()),
                ("hookCount", hooks.len().to_string()),
            ],
        );
        for (idx, hook) in hooks.iter().enumerate() {
            ChainLogger::info(
                TOOL_CHAIN,
                "tool.notify.hook",
                &[
                    ("inv", inv.to_string()),
                    ("idx", idx.to_string()),
                    ("hookCount", hooks.len().to_string()),
                ],
            );
            hook.onToolCallRequested(tool);
        }
        ChainLogger::info(
            TOOL_CHAIN,
            "tool.notify.exit",
            &[
                ("inv", inv.to_string()),
                ("hookCount", hooks.len().to_string()),
            ],
        );
    }

    /// Returns the first hook decision for a tool call before execution begins.
    #[allow(non_snake_case)]
    pub fn checkToolInterception(&self, tool: &AITool) -> AIToolHookDecision {
        let hooks = self
            .inner
            .lock()
            .expect("AIToolHandler mutex poisoned")
            .hooks
            .clone();
        for hook in hooks {
            match hook.onToolCallIntercept(tool) {
                AIToolHookDecision::Allow => {}
                decision @ AIToolHookDecision::Block(_) => return decision,
            }
        }
        AIToolHookDecision::Allow
    }

    /// Builds the standard failed result emitted when a hook blocks a tool call.
    #[allow(non_snake_case)]
    pub fn toolInterceptionResult(tool: &AITool, decision: AIToolHookDecision) -> ToolResult {
        let reason = match decision {
            AIToolHookDecision::Allow => "Tool call was not blocked.".to_string(),
            AIToolHookDecision::Block(reason) => reason,
        };
        ToolResult {
            toolName: tool.name.clone(),
            success: false,
            result: stringResultData(""),
            error: Some(reason),
        }
    }

    /// Notifies hooks that permission was checked for a tool call.
    #[allow(non_snake_case)]
    pub fn notifyToolPermissionChecked(&self, tool: &AITool, granted: bool, reason: Option<&str>) {
        self.notifyHooks(|hook| hook.onToolPermissionChecked(tool, granted, reason));
    }

    /// Notifies hooks that tool execution is about to start.
    #[allow(non_snake_case)]
    pub fn notifyToolExecutionStarted(&self, tool: &AITool) {
        self.notifyHooks(|hook| hook.onToolExecutionStarted(tool));
    }

    /// Notifies hooks that tool execution returned a result.
    #[allow(non_snake_case)]
    pub fn notifyToolExecutionResult(&self, tool: &AITool, result: &ToolResult) {
        self.notifyHooks(|hook| hook.onToolExecutionResult(tool, result));
    }

    /// Notifies hooks that tool execution failed before producing a normal result.
    #[allow(non_snake_case)]
    pub fn notifyToolExecutionError(&self, tool: &AITool, message: &str) {
        self.notifyHooks(|hook| hook.onToolExecutionError(tool, message));
    }

    /// Notifies hooks that tool execution has fully finished.
    #[allow(non_snake_case)]
    pub fn notifyToolExecutionFinished(&self, tool: &AITool) {
        self.notifyHooks(|hook| hook.onToolExecutionFinished(tool));
    }

    /// Returns every registered tool name regardless of visibility.
    #[allow(non_snake_case)]
    pub fn getAllToolNames(&self) -> Vec<String> {
        self.inner
            .lock()
            .expect("AIToolHandler mutex poisoned")
            .availableTools
            .keys()
            .cloned()
            .collect()
    }

    /// Returns the host environment descriptor associated with this handler.
    #[allow(non_snake_case)]
    pub fn getHostEnvironmentDescriptor(&self) -> HostEnvironmentDescriptor {
        self.inner
            .lock()
            .expect("AIToolHandler mutex poisoned")
            .context
            .hostEnvironment
            .clone()
    }

    /// Returns the host manager associated with this handler.
    #[allow(non_snake_case)]
    pub fn getContext(&self) -> HostManager {
        self.inner
            .lock()
            .expect("AIToolHandler mutex poisoned")
            .context
            .clone()
    }

    /// Returns the dependency set associated with this handler.
    #[allow(non_snake_case)]
    pub fn runtimeDependencies(&self) -> ToolRuntimeDependencies {
        self.inner
            .lock()
            .expect("AIToolHandler mutex poisoned")
            .runtimeDependencies
            .clone()
    }

    /// Returns the runtime support implementation associated with this handler.
    #[allow(non_snake_case)]
    pub fn runtimeSupport(&self) -> Arc<dyn ToolRuntimeSupport> {
        self.runtimeDependencies().shared_runtime_support()
    }

    /// Returns the shared package manager, creating it with this handler context.
    #[allow(non_snake_case)]
    pub fn getOrCreatePackageManager(&self) -> Arc<Mutex<RuntimePackageManager>> {
        {
            let guard = self.inner.lock().expect("AIToolHandler mutex poisoned");
            if let Some(packageManager) = &guard.packageManager {
                return packageManager.clone();
            }
        }
        let packageManager = Arc::new(Mutex::new(RuntimePackageManager::new(
            RuntimeStorePaths::default(),
            self.clone(),
        )));
        let mut guard = self.inner.lock().expect("AIToolHandler mutex poisoned");
        if let Some(existingPackageManager) = &guard.packageManager {
            return existingPackageManager.clone();
        }
        guard.packageManager = Some(packageManager.clone());
        packageManager
    }

    /// Returns tool names that should be visible to normal callers.
    #[allow(non_snake_case)]
    pub fn getPublicToolNames(&self) -> Vec<String> {
        let guard = self.inner.lock().expect("AIToolHandler mutex poisoned");
        guard
            .toolVisibility
            .iter()
            .filter(|(_, visibility)| **visibility == ToolRegistrationVisibility::PUBLIC)
            .map(|(name, _)| name.clone())
            .collect()
    }

    /// Returns tool names reserved for internal runtime calls.
    #[allow(non_snake_case)]
    pub fn getInternalToolNames(&self) -> Vec<String> {
        let guard = self.inner.lock().expect("AIToolHandler mutex poisoned");
        guard
            .toolVisibility
            .iter()
            .filter(|(_, visibility)| **visibility == ToolRegistrationVisibility::INTERNAL)
            .map(|(name, _)| name.clone())
            .collect()
    }

    /// Registers a public tool executor.
    #[allow(non_snake_case)]
    pub fn registerTool(&mut self, name: String, executor: Box<dyn ToolExecutor>) {
        self.registerToolWithVisibility(name, executor, ToolRegistrationVisibility::PUBLIC);
    }

    /// Registers an internal tool executor.
    #[allow(non_snake_case)]
    pub fn registerInternalTool(&mut self, name: String, executor: Box<dyn ToolExecutor>) {
        self.registerToolWithVisibility(name, executor, ToolRegistrationVisibility::INTERNAL);
    }

    /// Registers one statically declared built-in tool with explicit visibility.
    #[allow(non_snake_case)]
    pub fn registerBuiltinTool(
        &mut self,
        name: BuiltinToolName,
        executor: Box<dyn ToolExecutor>,
        visibility: ToolRegistrationVisibility,
    ) {
        let toolName = name.as_str().to_string();
        let mut guard = self.inner.lock().expect("AIToolHandler mutex poisoned");
        assert!(
            !guard.availableTools.contains_key(&toolName),
            "Built-in tool is registered more than once: {toolName}"
        );
        assert!(
            !guard.unavailableBuiltinTools.contains_key(&name),
            "Built-in tool cannot be both registered and unavailable: {toolName}"
        );
        guard.availableTools.insert(
            toolName.clone(),
            Box::new(ContractCheckedBuiltinToolExecutor { name, executor }),
        );
        guard.toolVisibility.insert(toolName, visibility);
    }

    /// Marks built-in tools as unavailable because their required host capability is absent.
    #[allow(non_snake_case)]
    pub(crate) fn markBuiltinToolsUnavailable(&mut self, names: &[BuiltinToolName], reason: &str) {
        let mut guard = self.inner.lock().expect("AIToolHandler mutex poisoned");
        for name in names {
            assert!(
                !guard.availableTools.contains_key(name.as_str()),
                "Registered built-in tool cannot be marked unavailable: {name}"
            );
            assert!(
                guard
                    .unavailableBuiltinTools
                    .insert(*name, reason.to_string())
                    .is_none(),
                "Built-in tool is marked unavailable more than once: {name}"
            );
        }
    }

    /// Registers a tool executor with explicit public or internal visibility.
    #[allow(non_snake_case)]
    pub fn registerToolWithVisibility(
        &mut self,
        name: String,
        executor: Box<dyn ToolExecutor>,
        visibility: ToolRegistrationVisibility,
    ) {
        assert!(
            BuiltinToolName::from_name(&name).is_none(),
            "Built-in tools must use registerBuiltinTool: {name}"
        );
        let mut guard = self.inner.lock().expect("AIToolHandler mutex poisoned");
        guard.availableTools.insert(name.clone(), executor);
        guard.toolVisibility.insert(name, visibility);
    }

    /// Returns the configured visibility for one tool.
    #[allow(non_snake_case)]
    pub fn getToolVisibility(&self, toolName: &str) -> Option<ToolRegistrationVisibility> {
        self.inner
            .lock()
            .expect("AIToolHandler mutex poisoned")
            .toolVisibility
            .get(toolName)
            .copied()
    }

    /// Registers built-in public and internal tools once for this handler.
    #[allow(non_snake_case)]
    pub fn registerDefaultTools(&mut self) {
        {
            let guard = self.inner.lock().expect("AIToolHandler mutex poisoned");
            if guard.defaultToolsRegistered {
                return;
            }
        }
        let context = {
            self.inner
                .lock()
                .expect("AIToolHandler mutex poisoned")
                .context
                .clone()
        };
        registerAllTools(self, &context);
        let mut guard = self.inner.lock().expect("AIToolHandler mutex poisoned");
        for name in BuiltinToolName::ALL {
            let registered = guard.availableTools.contains_key(name.as_str());
            let unavailable = guard.unavailableBuiltinTools.contains_key(name);
            assert!(
                registered ^ unavailable,
                "Built-in tool must be exactly registered or unavailable: {name}"
            );
        }
        guard.defaultToolsRegistered = true;
    }

    #[allow(non_snake_case)]
    pub fn getToolExecutor(&mut self, _toolName: &str) -> Option<&mut Box<dyn ToolExecutor>> {
        None
    }

    /// Returns whether a tool executor is already registered.
    #[allow(non_snake_case)]
    pub fn hasToolExecutor(&self, toolName: &str) -> bool {
        self.inner
            .lock()
            .expect("AIToolHandler mutex poisoned")
            .availableTools
            .contains_key(toolName)
    }

    /// Ensures default or package tools are registered, then reports whether a tool exists.
    #[allow(non_snake_case)]
    pub fn getToolExecutorOrActivate(&mut self, toolName: &str) -> bool {
        if self.hasToolExecutor(toolName) {
            if let Some((packageName, _)) = toolName.split_once(':') {
                let packageName = packageName.trim();
                if !packageName.is_empty() {
                    let packageManager = self.getOrCreatePackageManager();
                    let isMcpAvailable = packageManager
                        .lock()
                        .expect("package manager mutex poisoned")
                        .getAvailableServerPackages()
                        .contains_key(packageName);
                    if isMcpAvailable && !self.isMcpServiceActive(packageName) {
                        let _ = packageManager
                            .lock()
                            .expect("package manager mutex poisoned")
                            .usePackage(packageName);
                    }
                }
            }
            return self.hasToolExecutor(toolName);
        }

        self.registerDefaultTools();
        if self.hasToolExecutor(toolName) {
            return true;
        }

        if toolName.contains(':') {
            let packageName = toolName
                .split_once(':')
                .map(|(name, _)| name.trim())
                .unwrap_or("");
            if !packageName.is_empty() {
                let packageManager = self.getOrCreatePackageManager();
                let selectedPackage = {
                    let mut guard = packageManager
                        .lock()
                        .expect("package manager mutex poisoned");
                    let isPackageAvailable = guard.getAvailablePackages().contains_key(packageName);
                    let isMcpAvailable =
                        guard.getAvailableServerPackages().contains_key(packageName);
                    if isPackageAvailable || isMcpAvailable {
                        let _ = guard.usePackage(packageName);
                        guard
                            .getEffectivePackageTools(packageName)
                            .filter(|package| !guard.isToolPkgContainer(&package.name))
                    } else {
                        None
                    }
                };
                if let Some(selectedPackage) = selectedPackage {
                    self.registerPackageTools(packageManager, selectedPackage);
                }
            }
        }

        self.hasToolExecutor(toolName)
    }

    #[allow(non_snake_case)]
    fn isMcpServiceActive(&self, packageName: &str) -> bool {
        let mcpManager = MCPManager::getInstance(self.getContext());
        let Some(client) = mcpManager.getOrCreateClient(packageName) else {
            return false;
        };
        client
            .getServiceInfo()
            .map(|info| info.active && info.ready)
            .unwrap_or(false)
    }

    #[allow(non_snake_case)]
    fn registerPackageTools(
        &mut self,
        packageManager: Arc<Mutex<RuntimePackageManager>>,
        toolPackage: ToolPackage,
    ) {
        let isMcpPackage = toolPackage.category == "MCP"
            || toolPackage
                .tools
                .first()
                .map(|tool| tool.script.contains("/* MCPJS"))
                .unwrap_or(false);
        let executableTools = toolPackage
            .tools
            .iter()
            .filter(|packageTool| !packageTool.advice)
            .cloned()
            .collect::<Vec<_>>();
        let context = self.getContext();
        for packageTool in executableTools {
            let toolName = format!("{}:{}", toolPackage.name, packageTool.name);
            if isMcpPackage {
                self.registerTool(
                    toolName,
                    Box::new(MCPToolExecutor::new(MCPManager::getInstance(
                        context.clone(),
                    ))),
                );
            } else {
                self.registerTool(
                    toolName,
                    Box::new(PackageToolExecutor::new(
                        toolPackage.clone(),
                        packageManager.clone(),
                        self.clone(),
                    )),
                );
            }
        }
    }

    /// Rejects interactive permission requests from synchronous execution callers.
    fn executeAccessPreflight(
        &self,
        tool: &AITool,
        executor: &dyn ToolExecutor,
    ) -> Result<ToolAccessSpec, ToolResult> {
        let accessSpec = executor.accessSpec(tool).map_err(|error| ToolResult {
            toolName: tool.name.clone(),
            success: false,
            result: stringResultData(""),
            error: Some(format!("Tool access declaration failed: {error}")),
        })?;

        let permissionSystem = self.getToolPermissionSystem();
        let mode = permissionSystem
            .getAiPermissionMode()
            .map_err(|error| ToolResult {
                toolName: tool.name.clone(),
                success: false,
                result: stringResultData(""),
                error: Some(error.to_string()),
            })?;
        if !mode.allowsEffect(accessSpec.effect) {
            return Err(ToolResult {
                toolName: tool.name.clone(),
                success: false,
                result: stringResultData(""),
                error: Some(format!(
                    "AI permission mode {} does not allow {:?} tool execution.",
                    mode.name(),
                    accessSpec.effect
                )),
            });
        }

        if let Err(error) = self.checkWorkspaceBoundary(tool, &accessSpec) {
            return Err(ToolResult {
                toolName: tool.name.clone(),
                success: false,
                result: stringResultData(""),
                error: Some(error),
            });
        }

        if self.hasNestedExecutionAuthorization() {
            return Ok(accessSpec);
        }

        if mode == AiPermissionMode::WorkspaceWrite
            && accessSpec.effect == ToolEffect::WRITE
            && matches!(accessSpec.boundary, ToolBoundary::None)
            && tool.name.split_once(':').is_none()
        {
            return Err(self.asyncPermissionRequiredResult(tool));
        }

        if tool.name.split_once(':').is_some() {
            return Err(self.asyncPermissionRequiredResult(tool));
        }

        Ok(accessSpec)
    }

    /// Runs access validation and asynchronously obtains every required approval.
    async fn executeAccessPreflightAsync(
        &self,
        tool: &AITool,
        accessSpec: ToolAccessSpec,
    ) -> Result<(ToolAccessSpec, bool), ToolResult> {
        let permissionSystem = self.getToolPermissionSystem();
        let mode = permissionSystem
            .getAiPermissionMode()
            .map_err(|error| ToolResult {
                toolName: tool.name.clone(),
                success: false,
                result: stringResultData(""),
                error: Some(error.to_string()),
            })?;
        if !mode.allowsEffect(accessSpec.effect) {
            return Err(ToolResult {
                toolName: tool.name.clone(),
                success: false,
                result: stringResultData(""),
                error: Some(format!(
                    "AI permission mode {} does not allow {:?} tool execution.",
                    mode.name(),
                    accessSpec.effect
                )),
            });
        }

        if let Err(error) = self.checkWorkspaceBoundary(tool, &accessSpec) {
            return Err(ToolResult {
                toolName: tool.name.clone(),
                success: false,
                result: stringResultData(""),
                error: Some(error),
            });
        }

        let usesPackagePermission =
            tool.name == PACKAGE_PROXY_TOOL_NAME || tool.name.split_once(':').is_some();
        let packageApprovalTool = if tool.name == PACKAGE_PROXY_TOOL_NAME {
            let resolvedTarget = ToolExecutionManager::resolveProxyTargetTool(tool);
            (resolvedTarget.name != tool.name).then_some(resolvedTarget)
        } else {
            tool.name.split_once(':').map(|_| tool.clone())
        };

        let mut permitsNestedInteractiveExecution = false;
        if mode == AiPermissionMode::WorkspaceWrite
            && accessSpec.effect == ToolEffect::WRITE
            && matches!(accessSpec.boundary, ToolBoundary::None)
            && !usesPackagePermission
        {
            let approved = permissionSystem
                .checkSandboxEscapeApprovalAsync(tool)
                .await
                .map_err(|error| ToolResult {
                    toolName: tool.name.clone(),
                    success: false,
                    result: stringResultData(""),
                    error: Some(error.to_string()),
                })?;
            if !approved {
                let error = "User cancelled the tool execution.".to_string();
                self.notifyToolPermissionChecked(tool, false, Some(&error));
                return Err(ToolResult {
                    toolName: tool.name.clone(),
                    success: false,
                    result: stringResultData(""),
                    error: Some(error),
                });
            }
            self.notifyToolPermissionChecked(
                tool,
                true,
                Some("WorkspaceWrite non-file WRITE approved for this session."),
            );
            permitsNestedInteractiveExecution = true;
        }

        if let Some(packageApprovalTool) = packageApprovalTool {
            let approved = permissionSystem
                .checkPackageToolApprovalAsync(&packageApprovalTool)
                .await
                .map_err(|error| ToolResult {
                    toolName: packageApprovalTool.name.clone(),
                    success: false,
                    result: stringResultData(""),
                    error: Some(error.to_string()),
                })?;
            if !approved {
                let error = "User cancelled the tool execution.".to_string();
                self.notifyToolPermissionChecked(&packageApprovalTool, false, Some(&error));
                return Err(ToolResult {
                    toolName: packageApprovalTool.name.clone(),
                    success: false,
                    result: stringResultData(""),
                    error: Some(error),
                });
            }
            self.notifyToolPermissionChecked(
                &packageApprovalTool,
                true,
                Some("PackageTool approved."),
            );
            permitsNestedInteractiveExecution = true;
        }

        Ok((accessSpec, permitsNestedInteractiveExecution))
    }

    /// Builds a typed denial for callers that have not migrated to asynchronous execution.
    fn asyncPermissionRequiredResult(&self, tool: &AITool) -> ToolResult {
        let error = "Interactive tool permission requires asynchronous tool execution.".to_string();
        self.notifyToolPermissionChecked(tool, false, Some(&error));
        ToolResult {
            toolName: tool.name.clone(),
            success: false,
            result: stringResultData(""),
            error: Some(error),
        }
    }

    fn checkWorkspaceBoundary(
        &self,
        tool: &AITool,
        accessSpec: &ToolAccessSpec,
    ) -> Result<(), String> {
        match &accessSpec.boundary {
            ToolBoundary::None => Ok(()),
            ToolBoundary::FilePath { effect } => self.checkWorkspacePath(tool, "path", *effect),
            ToolBoundary::FilePair {
                source,
                destination,
            } => {
                self.checkWorkspacePath(tool, "source", *source)?;
                self.checkWorkspacePath(tool, "destination", *destination)
            }
        }
    }

    fn checkWorkspacePath(
        &self,
        tool: &AITool,
        parameterName: &str,
        effect: ToolEffect,
    ) -> Result<(), String> {
        let path = tool
            .parameters
            .iter()
            .find(|parameter| parameter.name == parameterName)
            .map(|parameter| parameter.value.trim())
            .ok_or_else(|| format!("{parameterName} parameter is required"))?;
        if path.is_empty() {
            return Err(format!("{parameterName} parameter is required"));
        }

        let runtimeContext = ToolExecutionManager::currentToolRuntimeContext()
            .ok_or_else(|| "File tool execution requires tool runtime context".to_string())?;
        let workspacePath = runtimeContext
            .workspacePath
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| "File tool execution requires a current workspace".to_string())?;

        let context = self.getContext();
        let paths = RuntimeStorePaths::default();
        let mapper = PathMapper::new(paths.runtime_dir().to_path_buf(), paths.workspace_dir());
        let resolvedWorkspace = mapper.resolve(workspacePath)?;
        let resolvedPath = mapper.resolve(path)?;
        let relative = PathMapper::relativePath(&resolvedWorkspace.vfsPath, &resolvedPath.vfsPath)?;
        if relative.is_none() {
            return Err(format!(
                "{:?} file access is limited to current workspace: {}",
                effect, resolvedWorkspace.vfsPath
            ));
        }
        Ok(())
    }

    /// Executes a tool through hooks, permissions, limits, and a resolved executor.
    #[allow(non_snake_case)]
    pub async fn executeToolSafelyWithResolvedExecutor(
        &mut self,
        tool: &AITool,
    ) -> Option<Vec<ToolResult>> {
        let parameterSummary = Self::summarizeToolParameters(tool);
        ChainLogger::info(
            TOOL_CHAIN,
            "tool.stream.request",
            &[
                ("tool", tool.name.clone()),
                ("parameterCount", tool.parameters.len().to_string()),
                ("parameters", parameterSummary.clone()),
            ],
        );
        if !self.getToolExecutorOrActivate(&tool.name) {
            ChainLogger::warn(
                TOOL_CHAIN,
                "tool.stream.not_found",
                &[("tool", tool.name.clone())],
            );
            return None;
        }

        let Some(mut executor) = ({
            self.inner
                .lock()
                .expect("AIToolHandler mutex poisoned")
                .availableTools
                .remove(&tool.name)
        }) else {
            ChainLogger::warn(
                TOOL_CHAIN,
                "tool.stream.not_registered",
                &[("tool", tool.name.clone())],
            );
            return None;
        };

        let validationResult = executor.validateParameters(tool);
        let startMs = operit_host_api::TimeUtils::currentTimeMillis();
        let collected = if validationResult.valid {
            let accessSpec = executor.accessSpec(tool).map_err(|error| ToolResult {
                toolName: tool.name.clone(),
                success: false,
                result: stringResultData(""),
                error: Some(format!("Tool access declaration failed: {error}")),
            });
            match accessSpec {
                Ok(accessSpec) => match self.executeAccessPreflightAsync(tool, accessSpec).await {
                    Ok((accessSpec, permitsNestedInteractiveExecution)) => {
                        ChainLogger::info(
                            TOOL_CHAIN,
                            "tool.stream.start",
                            &[
                                ("tool", tool.name.clone()),
                                ("parameters", parameterSummary.clone()),
                                ("effect", format!("{:?}", accessSpec.effect)),
                            ],
                        );
                        let _executionScope =
                            permitsNestedInteractiveExecution.then(AsyncToolExecutionScope::enter);
                        executor.invokeAndStream(tool)
                    }
                    Err(errorResult) => vec![errorResult],
                },
                Err(errorResult) => vec![errorResult],
            }
        } else {
            ChainLogger::warn(
                TOOL_CHAIN,
                "tool.stream.validation_failed",
                &[
                    ("tool", tool.name.clone()),
                    ("error", validationResult.errorMessage.clone()),
                ],
            );
            vec![ToolResult {
                toolName: tool.name.clone(),
                success: false,
                result: stringResultData(""),
                error: Some(format!(
                    "Invalid parameters: {}",
                    validationResult.errorMessage
                )),
            }]
        };

        self.inner
            .lock()
            .expect("AIToolHandler mutex poisoned")
            .availableTools
            .insert(tool.name.clone(), executor);
        let elapsedMs = operit_host_api::TimeUtils::currentTimeMillis().saturating_sub(startMs);
        let finalResult = collected.last().cloned();
        if let Some(finalResult) = finalResult {
            if finalResult.success {
                ChainLogger::info(
                    TOOL_CHAIN,
                    "tool.stream.done",
                    &[
                        ("tool", tool.name.clone()),
                        ("resultCount", collected.len().to_string()),
                        ("elapsedMs", elapsedMs.to_string()),
                        (
                            "resultChars",
                            ChainLogger::lenField(&finalResult.result.toString()),
                        ),
                    ],
                );
            } else if let Some(error) = finalResult.error.clone() {
                ChainLogger::error(
                    TOOL_CHAIN,
                    "tool.stream.error",
                    &[
                        ("tool", tool.name.clone()),
                        ("resultCount", collected.len().to_string()),
                        ("elapsedMs", elapsedMs.to_string()),
                        ("parameters", parameterSummary.clone()),
                        ("error", error),
                        (
                            "resultChars",
                            ChainLogger::lenField(&finalResult.result.toString()),
                        ),
                    ],
                );
            } else {
                ChainLogger::error(
                    TOOL_CHAIN,
                    "tool.stream.error",
                    &[
                        ("tool", tool.name.clone()),
                        ("resultCount", collected.len().to_string()),
                        ("elapsedMs", elapsedMs.to_string()),
                        ("parameters", parameterSummary.clone()),
                        (
                            "resultChars",
                            ChainLogger::lenField(&finalResult.result.toString()),
                        ),
                    ],
                );
            }
        } else {
            ChainLogger::error(
                TOOL_CHAIN,
                "tool.stream.empty_result",
                &[
                    ("tool", tool.name.clone()),
                    ("elapsedMs", elapsedMs.to_string()),
                ],
            );
        }
        if elapsedMs >= 3000 {
            ChainLogger::warn(
                TOOL_CHAIN,
                "tool.stream.slow",
                &[
                    ("tool", tool.name.clone()),
                    ("elapsedMs", elapsedMs.to_string()),
                    ("parameters", parameterSummary.clone()),
                ],
            );
        }
        Some(collected)
    }

    /// Executes a tool on behalf of an already-authorized package proxy invocation.
    ///
    /// Enters a nested execution scope before dispatching so the synchronous access
    /// preflight short-circuits and permits package-namespaced tools (e.g. `pkg:tool`)
    /// instead of denying them with
    /// "Interactive tool permission requires asynchronous tool execution."
    /// Tools reached through `package_proxy` are already gated by the role-card
    /// tool-access check, so re-running the async approval flow is unnecessary. This
    /// mirrors how compose_dsl plugin tools are already permitted via the same scope.
    pub fn executeToolViaPackageProxy(&mut self, tool: AITool) -> ToolResult {
        let _scope = AsyncToolExecutionScope::enter();
        self.executeTool(tool)
    }

    /// Resolves and executes a tool request through the registered tool chain.
    #[allow(non_snake_case)]
    pub fn executeTool(&mut self, tool: AITool) -> ToolResult {
        let inv = TOOL_EXEC_INV.fetch_add(1, Ordering::SeqCst) + 1;
        ChainLogger::info(
            TOOL_CHAIN,
            "tool.exec.enter",
            &[("inv", inv.to_string()), ("tool", tool.name.clone())],
        );
        ChainLogger::info(
            TOOL_CHAIN,
            "tool.execute.request",
            &[
                ("inv", inv.to_string()),
                ("tool", tool.name.clone()),
                ("parameterCount", tool.parameters.len().to_string()),
            ],
        );
        self.notifyToolCallRequested(&tool, inv);
        ChainLogger::info(
            TOOL_CHAIN,
            "tool.stage.notify_requested",
            &[("inv", inv.to_string()), ("tool", tool.name.clone())],
        );
        ChainLogger::info(
            TOOL_CHAIN,
            "tool.stage.Z2_pre_intercept",
            &[("inv", inv.to_string()), ("tool", tool.name.clone())],
        );
        let interception = self.checkToolInterception(&tool);
        ChainLogger::info(
            TOOL_CHAIN,
            "tool.stage.interception",
            &[("tool", tool.name.clone())],
        );
        if let AIToolHookDecision::Block(_) = interception {
            let result = Self::toolInterceptionResult(&tool, interception);
            self.notifyToolExecutionResult(&tool, &result);
            self.notifyToolExecutionFinished(&tool);
            return result;
        }
        self.getToolExecutorOrActivate(&tool.name);
        ChainLogger::info(
            TOOL_CHAIN,
            "tool.stage.activate",
            &[("tool", tool.name.clone())],
        );
        let Some(mut executor) = ({
            self.inner
                .lock()
                .expect("AIToolHandler mutex poisoned")
                .availableTools
                .remove(&tool.name)
        }) else {
            let notFoundResult = ToolResult {
                toolName: tool.name.clone(),
                success: false,
                result: stringResultData(""),
                error: Some(format!("Tool not found: {}", tool.name)),
            };
            self.notifyToolExecutionResult(&tool, &notFoundResult);
            self.notifyToolExecutionFinished(&tool);
            ChainLogger::warn(
                TOOL_CHAIN,
                "tool.execute.not_found",
                &[("tool", tool.name.clone())],
            );
            return notFoundResult;
        };

        ChainLogger::info(
            TOOL_CHAIN,
            "tool.stage.executor_removed",
            &[("tool", tool.name.clone())],
        );
        let validationResult = executor.validateParameters(&tool);
        ChainLogger::info(
            TOOL_CHAIN,
            "tool.stage.validated",
            &[("tool", tool.name.clone())],
        );
        if !validationResult.valid {
            let validationError = validationResult.errorMessage;
            let validationFailedResult = ToolResult {
                toolName: tool.name.clone(),
                success: false,
                result: stringResultData(""),
                error: Some(validationError.clone()),
            };
            self.notifyToolExecutionResult(&tool, &validationFailedResult);
            self.notifyToolExecutionFinished(&tool);
            ChainLogger::warn(
                TOOL_CHAIN,
                "tool.execute.validation_failed",
                &[("tool", tool.name.clone()), ("error", validationError)],
            );
            self.inner
                .lock()
                .expect("AIToolHandler mutex poisoned")
                .availableTools
                .insert(tool.name.clone(), executor);
            return validationFailedResult;
        }

        ChainLogger::info(TOOL_CHAIN, "tool.stage.Z3_pre_preflight", &[("inv", inv.to_string()), ("tool", tool.name.clone())]);
        ChainLogger::info(
            TOOL_CHAIN,
            "tool.stage.preflight_enter",
            &[("inv", inv.to_string()), ("tool", tool.name.clone())],
        );
        let preflight = self.executeAccessPreflight(&tool, executor.as_ref());
        ChainLogger::info(
            TOOL_CHAIN,
            "tool.stage.preflight_done",
            &[("inv", inv.to_string()), ("tool", tool.name.clone())],
        );
        if let Err(accessDeniedResult) = preflight {
            self.notifyToolExecutionResult(&tool, &accessDeniedResult);
            self.notifyToolExecutionFinished(&tool);
            self.inner
                .lock()
                .expect("AIToolHandler mutex poisoned")
                .availableTools
                .insert(tool.name.clone(), executor);
            return accessDeniedResult;
        }

        self.notifyToolExecutionStarted(&tool);
        ChainLogger::info(
            TOOL_CHAIN,
            "tool.execute.start",
            &[("inv", inv.to_string()), ("tool", tool.name.clone())],
        );
        let _inheritedExecutionScope = self
            .hasNestedExecutionAuthorization()
            .then(AsyncToolExecutionScope::enter);
        // Bounded wait: the executor is owned (it was removed from
        // `availableTools` above) and `ToolExecutor: Send`, so it can move into
        // the watchdog thread. On timeout the executor is *not* returned — the
        // tool stays absent from `availableTools` until the next call re-activates
        // it via `getToolExecutorOrActivate` -> `registerDefaultTools`.
        let timeoutMs = self
            .inner
            .lock()
            .expect("AIToolHandler mutex poisoned")
            .toolExecutionTimeoutMs;
        // Thread-locals are NOT inherited by the spawned thread, so the caller's
        // async-execution depth (nested package authorization) and tool runtime
        // context must be carried across explicitly — otherwise enabling a
        // timeout would silently strip both from every tool invocation.
        let inheritedDepth = AsyncToolExecutionScope::currentDepth();
        let inheritedContext = ToolExecutionManager::currentToolRuntimeContext();
        let invocationTool = tool.clone();
        let invocation = run_with_timeout(timeoutMs, move || {
            let _depthGuard = AsyncToolExecutionScope::restoreDepth(inheritedDepth);
            let _contextGuard = ToolRuntimeContextGuard::install(inheritedContext);
            (executor.invokeAndStream(&invocationTool), executor)
        });
        let (collected, restoredExecutor) = match invocation {
            Some((results, executor)) => (results, Some(executor)),
            None => {
                ChainLogger::error(
                    TOOL_CHAIN,
                    "tool.execute.timeout",
                    &[
                        ("tool", tool.name.clone()),
                        ("timeoutMs", timeoutMs.to_string()),
                    ],
                );
                (
                    vec![ToolResult {
                        toolName: tool.name.clone(),
                        success: false,
                        result: stringResultData(""),
                        error: Some(format!(
                            "Tool execution timed out after {timeoutMs}ms: {}",
                            tool.name
                        )),
                    }],
                    None,
                )
            }
        };
        if collected.is_empty() {
            ChainLogger::error(
                TOOL_CHAIN,
                "tool.execute.empty_result",
                &[("tool", tool.name.clone())],
            );
        }
        let result = collected
            .last()
            .cloned()
            .expect("ToolExecutor.invokeAndStream must return at least one ToolResult");
        self.notifyToolExecutionResult(&tool, &result);
        self.notifyToolExecutionFinished(&tool);
        if result.success {
            ChainLogger::info(
                TOOL_CHAIN,
                "tool.execute.done",
                &[
                    ("tool", tool.name.clone()),
                    (
                        "resultChars",
                        ChainLogger::lenField(&result.result.toString()),
                    ),
                ],
            );
        } else {
            if let Some(error) = result.error.as_ref() {
                ChainLogger::error(
                    TOOL_CHAIN,
                    "tool.execute.error",
                    &[
                        ("tool", tool.name.clone()),
                        ("error", error.clone()),
                        (
                            "resultChars",
                            ChainLogger::lenField(&result.result.toString()),
                        ),
                    ],
                );
            } else {
                ChainLogger::error(
                    TOOL_CHAIN,
                    "tool.execute.error",
                    &[
                        ("tool", tool.name.clone()),
                        (
                            "resultChars",
                            ChainLogger::lenField(&result.result.toString()),
                        ),
                    ],
                );
            }
        }
        // Only re-register when the invocation returned; on timeout the executor
        // is still owned by the leaked watchdog thread.
        if let Some(executor) = restoredExecutor {
            self.inner
                .lock()
                .expect("AIToolHandler mutex poisoned")
                .availableTools
                .insert(tool.name.clone(), executor);
        }
        result
    }

    /// Sets the hard timeout (ms) for a single tool invocation. `0` disables it
    /// (default), preserving the pre-existing unbounded behaviour.
    #[allow(non_snake_case)]
    pub fn setToolExecutionTimeoutMs(&self, timeoutMs: u64) {
        self.inner
            .lock()
            .expect("AIToolHandler mutex poisoned")
            .toolExecutionTimeoutMs = timeoutMs;
    }

    /// Returns the configured hard timeout (ms) for a single tool invocation.
    #[allow(non_snake_case)]
    pub fn getToolExecutionTimeoutMs(&self) -> u64 {
        self.inner
            .lock()
            .expect("AIToolHandler mutex poisoned")
            .toolExecutionTimeoutMs
    }

    #[allow(non_snake_case)]
    /// Removes all registered executors and returns their ownership to the caller.
    pub fn takeExecutors(&mut self) -> BTreeMap<String, Box<dyn ToolExecutor>> {
        let mut guard = self.inner.lock().expect("AIToolHandler mutex poisoned");
        if !guard.defaultToolsRegistered {
            drop(guard);
            self.registerDefaultTools();
            guard = self.inner.lock().expect("AIToolHandler mutex poisoned");
        }
        std::mem::take(&mut guard.availableTools)
    }

    #[allow(non_snake_case)]
    /// Restores a previously removed executor registry.
    pub fn restoreExecutors(&mut self, executors: BTreeMap<String, Box<dyn ToolExecutor>>) {
        self.inner
            .lock()
            .expect("AIToolHandler mutex poisoned")
            .availableTools = executors;
    }

    /// Clears registered tools and runtime-only handler state.
    pub fn reset(&mut self) {
        let mut guard = self.inner.lock().expect("AIToolHandler mutex poisoned");
        guard.availableTools.clear();
        guard.toolVisibility.clear();
        guard.unavailableBuiltinTools.clear();
        guard.defaultToolsRegistered = false;
    }
}

impl AIToolHandlerState {
    /// Returns the host manager associated with this handler state.
    #[allow(non_snake_case)]
    pub fn getContext(&self) -> &HostManager {
        &self.context
    }
}

impl JsExecutionHost for AIToolHandler {
    /// Executes an SDK JavaScript tool request through the registered Operit tool chain.
    fn execute_tool_call(&self, request: JsToolCallRequest) -> JsToolCallResult {
        let tool_name = request.qualified_tool_name();
        ChainLogger::info(
            TOOL_CHAIN,
            "tool.ffi.enter",
            &[("tool", tool_name.clone())],
        );
        let tool = AITool {
            name: request.qualified_tool_name(),
            parameters: request
                .parameters
                .into_iter()
                .map(|(name, value)| ToolParameter {
                    name,
                    value: match value {
                        serde_json::Value::Null => String::new(),
                        serde_json::Value::String(value) => value,
                        value => value.to_string(),
                    },
                })
                .collect(),
        };
        let mut handler = self.clone();
        // JavaScript `Tools.*` calls originate from a script that is already running inside an
        // approved tool execution: the package owning the script was authorized before it ever
        // started. `AsyncToolExecutionScope` is thread-local while script callbacks run on the
        // JS worker thread, so that inherited authorization is lost across the thread boundary.
        // Re-entering the scope here puts nested tool calls back on the approved stack, which
        // lets the access preflight return immediately instead of blocking on an interactive
        // approval round-trip that can never complete while the script itself is still running
        // (that wait is what cost a full 60s before the tool finally executed).
        let _nestedExecutionScope = AsyncToolExecutionScope::enter();
        let result = handler.executeTool(tool);
        let data = match result.result {
            ToolResultData::BinaryResultData(data) => JsToolCallResultData::Binary(data.value),
            ToolResultData::StringResultData(data) => {
                JsToolCallResultData::Value(serde_json::Value::String(data.value))
            }
            ToolResultData::BooleanResultData(data) => {
                JsToolCallResultData::Value(serde_json::Value::Bool(data.value))
            }
            ToolResultData::IntResultData(data) => JsToolCallResultData::Value(
                serde_json::Value::Number(serde_json::Number::from(data.value)),
            ),
            data => JsToolCallResultData::Value(
                serde_json::from_str(&data.toJson())
                    .expect("ToolResultData JSON conversion must succeed"),
            ),
        };
        ChainLogger::info(
            TOOL_CHAIN,
            "tool.ffi.exit",
            &[
                ("tool", tool_name.clone()),
                ("success", result.success.to_string()),
            ],
        );
        JsToolCallResult {
            success: result.success,
            data,
            error: result.error,
        }
    }

    /// Returns the current host language.
    fn package_language(&self) -> Result<String, String> {
        LocaleUtils::getCurrentLanguage(&self.getContext(), "")
    }

    /// Reads one runtime environment variable.
    fn read_environment_variable(&self, key: &str) -> Result<Option<String>, String> {
        self.runtimeDependencies()
            .runtime_support()
            .readEnvironmentVariable(key)
    }

    /// Returns the plugin configuration directory.
    fn plugin_config_dir(&self, plugin_id: &str) -> Result<String, String> {
        OperitPaths::pluginConfigDir(plugin_id).map(|path| path.to_string_lossy().to_string())
    }

    /// Reads one ToolPkg text resource.
    fn read_toolpkg_text_resource(&self, target: &str, path: &str) -> Result<String, String> {
        self.getOrCreatePackageManager()
            .lock()
            .expect("package manager mutex poisoned")
            .readToolPkgTextResource(target, path, true)
            .ok_or_else(|| format!("ToolPkg text resource not found: {target}/{path}"))
    }

    /// Materializes one ToolPkg binary resource.
    fn materialize_toolpkg_resource(
        &self,
        request: JsToolPkgResourceRequest,
    ) -> Result<String, String> {
        crate::tools::ToolJsRuntime::materializeToolPkgResource(self, request)
    }

    /// Calls one ToolPkg WASM export through the active package manager.
    fn call_toolpkg_wasm(
        &self,
        request: JsToolPkgWasmRequest,
    ) -> Result<JsToolPkgWasmResult, String> {
        self.getOrCreatePackageManager()
            .lock()
            .expect("package manager mutex poisoned")
            .callToolPkgWasm(request, true)
    }

    /// Dispatches one Compose DSL controller command.
    fn handle_compose_webview_controller_command(
        &self,
        payload_json: &str,
    ) -> Result<String, String> {
        self.getContext()
            .composeDslWebViewHost
            .as_ref()
            .ok_or_else(|| "ComposeDslWebViewHost is not registered".to_string())?
            .handleControllerCommand(payload_json)
            .map_err(|error| error.to_string())
    }

    /// Decodes and forwards one Compose DSL file-picker request to the registered host owner.
    fn open_compose_file_picker(&self, payload_json: &str) -> Result<String, String> {
        let request = operit_host_api::ComposeDslFilePickerRequest::parse(payload_json)
            .map_err(|error| error.to_string())?;
        self.getContext()
            .composeDslWebViewHost
            .as_ref()
            .ok_or_else(|| "ComposeDslWebViewHost is not registered".to_string())?
            .openFilePicker(request)
            .map_err(|error| error.to_string())
    }

    /// Returns whether one package is imported.
    fn is_package_imported(&self, package_name: &str) -> Result<bool, String> {
        Ok(self
            .getOrCreatePackageManager()
            .lock()
            .expect("package manager mutex poisoned")
            .isPackageEnabled(package_name))
    }

    /// Imports one package.
    fn import_package(&self, package_name: &str) -> Result<String, String> {
        Ok(self
            .getOrCreatePackageManager()
            .lock()
            .expect("package manager mutex poisoned")
            .enablePackage(package_name))
    }

    /// Removes one package.
    fn remove_package(&self, package_name: &str) -> Result<String, String> {
        Ok(self
            .getOrCreatePackageManager()
            .lock()
            .expect("package manager mutex poisoned")
            .disablePackage(package_name))
    }

    /// Activates one package.
    fn use_package(&self, package_name: &str) -> Result<String, String> {
        Ok(self
            .getOrCreatePackageManager()
            .lock()
            .expect("package manager mutex poisoned")
            .usePackage(package_name))
    }

    /// Lists imported packages.
    fn list_imported_packages(&self) -> Result<Vec<String>, String> {
        Ok(self
            .getOrCreatePackageManager()
            .lock()
            .expect("package manager mutex poisoned")
            .getEnabledPackageNames())
    }

    /// Resolves one package-aware tool name.
    fn resolve_tool_name(&self, request: JsToolNameResolutionRequest) -> Result<String, String> {
        crate::tools::ToolJsRuntime::resolveJsToolName(self, request)
    }

    /// Invokes one ToolPkg IPC request.
    fn invoke_toolpkg_ipc(
        &self,
        request: JsToolPkgIpcRequest,
    ) -> Result<serde_json::Value, String> {
        crate::tools::ToolJsRuntime::invokeToolPkgIpc(self, request)
    }
}

pub struct FnToolExecutor {
    pub invoke: Arc<dyn Fn(&AITool) -> ToolResult + Send + Sync>,
    pub validate: Arc<dyn Fn(&AITool) -> ToolValidationResult + Send + Sync>,
    pub effect: ToolEffect,
}

/// Enforces the registered name and successful result contract for one built-in executor.
struct ContractCheckedBuiltinToolExecutor {
    name: BuiltinToolName,
    executor: Box<dyn ToolExecutor>,
}

impl ToolExecutor for ContractCheckedBuiltinToolExecutor {
    /// Validates parameters only for the exact built-in name bound during registration.
    fn validateParameters(&self, tool: &AITool) -> ToolValidationResult {
        assert_eq!(
            tool.name,
            self.name.as_str(),
            "Built-in executor received a different tool name"
        );
        self.executor.validateParameters(tool)
    }

    /// Delegates access classification after verifying the registered built-in name.
    fn accessSpec(&self, tool: &AITool) -> Result<ToolAccessSpec, String> {
        assert_eq!(
            tool.name,
            self.name.as_str(),
            "Built-in executor received a different tool name"
        );
        self.executor.accessSpec(tool)
    }

    /// Verifies every successful result emitted by the wrapped built-in executor.
    fn invokeAndStream(&mut self, tool: &AITool) -> Vec<ToolResult> {
        assert_eq!(
            tool.name,
            self.name.as_str(),
            "Built-in executor received a different tool name"
        );
        let results = self.executor.invokeAndStream(tool);
        for result in &results {
            if self.name != BuiltinToolName::PackageProxy {
                assert_eq!(
                    result.toolName,
                    self.name.as_str(),
                    "Built-in executor emitted a result for a different tool name"
                );
            }
            assert!(
                !result.success || self.name.accepts_runtime_result(&result.result),
                "Built-in executor emitted an incompatible successful result: {}",
                self.name
            );
            assert!(
                result.success || result.error.is_some(),
                "Built-in executor emitted a failed result without an error: {}",
                self.name
            );
        }
        results
    }
}

impl ToolExecutor for FnToolExecutor {
    fn validateParameters(&self, tool: &AITool) -> ToolValidationResult {
        (self.validate)(tool)
    }

    fn accessSpec(&self, _tool: &AITool) -> Result<ToolAccessSpec, String> {
        Ok(ToolAccessSpec {
            effect: self.effect,
            boundary: ToolBoundary::None,
        })
    }

    fn invokeAndStream(&mut self, tool: &AITool) -> Vec<ToolResult> {
        vec![(self.invoke)(tool)]
    }
}

#[cfg(test)]
mod tests {
    use super::{AsyncToolExecutionScope, PackageNestedExecutionAuthorizationState};

    /// Verifies that package authorization crosses threads without leaking across states.
    #[test]
    fn package_nested_authorization_is_cross_thread_scoped_and_isolated() {
        let authorized_state = PackageNestedExecutionAuthorizationState::new();
        let isolated_state = PackageNestedExecutionAuthorizationState::new();
        let async_scope = AsyncToolExecutionScope::enter();
        let authorization = authorized_state.enter();
        drop(async_scope);

        let worker_authorized_state = authorized_state.clone();
        let worker_isolated_state = isolated_state.clone();
        let (authorized_on_worker, isolated_on_worker) = std::thread::spawn(move || {
            (
                worker_authorized_state.isActive(),
                worker_isolated_state.isActive(),
            )
        })
        .join()
        .expect("authorization test worker must complete");

        assert!(authorized_on_worker);
        assert!(!isolated_on_worker);
        drop(authorization);
        assert!(!authorized_state.isActive());
    }
}

/// Best-effort timeout wrapper for a blocking closure.
///
/// Runs `work` on a spawned thread and waits up to `timeout_ms`. Returns `None`
/// if `work` does not finish in time. The spawned thread is **not** aborted
/// (Rust std has no thread cancellation); on timeout it leaks until `work`
/// returns on its own. Use this only where the caller must not block forever —
/// e.g. a tool execution that may hang. True cancellation requires migrating
/// tool execution to a tokio runtime so the future can be dropped.
///
/// This is the timeout discipline foundation for tool execution, and it **is**
/// wired into `executeTool` (gated by `toolExecutionTimeoutMs`, default `0` =
/// disabled so behaviour is unchanged until a caller opts in).
///
/// Correcting an earlier claim: `Box<dyn ToolExecutor>` is *not* `!Send`.
/// `ToolExecutor` already declares `Send` as a supertrait
/// (`ToolExecutionManager.rs`: `pub trait ToolExecutor: Send`), so the trait
/// object is `Send` and can move into this thread with no change to the 14 impls.
/// What still needs the async-runtime migration (§14.3 / §15.1) is *true
/// cancellation* — dropping a future — not merely bounding the wait.
pub fn run_with_timeout<F, T>(timeout_ms: u64, work: F) -> Option<T>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    if timeout_ms == 0 {
        return Some(work());
    }
    let (tx, rx) = std::sync::mpsc::channel::<T>();
    let handle = std::thread::spawn(move || {
        let value = work();
        let _ = tx.send(value);
    });
    match rx.recv_timeout(std::time::Duration::from_millis(timeout_ms)) {
        Ok(value) => {
            let _ = handle.join();
            Some(value)
        }
        Err(_) => None,
    }
}

#[cfg(test)]
mod timeout_foundation_tests {
    use super::run_with_timeout;

    #[test]
    fn returns_value_when_work_finishes_in_time() {
        let result = run_with_timeout(1000, || 42u32);
        assert_eq!(result, Some(42));
    }

    #[test]
    fn returns_none_when_work_exceeds_timeout() {
        let result = run_with_timeout(80, || {
            std::thread::sleep(std::time::Duration::from_millis(500));
            1u32
        });
        assert_eq!(result, None);
    }

    #[test]
    fn zero_timeout_runs_inline() {
        let result = run_with_timeout(0, || "inline".to_string());
        assert_eq!(result, Some("inline".to_string()));
    }
}
