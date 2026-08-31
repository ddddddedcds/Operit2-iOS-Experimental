use std::sync::{Arc, Mutex, OnceLock};

use serde_json::Value;

use crate::plugins::toolpkg::ToolPkgHookBridgeSupport::ToolPkgBridgeRuntime;
use operit_plugin_sdk::toolpkg::ToolPkgCommonPluginConstants::TOOLPKG_EVENT_TOOL_LIFECYCLE;
use operit_plugin_sdk::toolpkg::ToolPkgHooks::ToolPkgToolLifecycleHookRegistration;
use operit_plugin_sdk::toolpkg::ToolPkgParser::ToolPkgContainerRuntime;
use operit_tools::tools::AIToolHook::{AIToolHook, AIToolHookDecision};
use operit_tools::ConversationMarkupManager::ToolResult;
use operit_tools::ToolExecutionManager::AITool;
use operit_util::ChainLogger::{self, PLUGIN_CHAIN};

static TOOL_LIFECYCLE_HOOKS: OnceLock<Mutex<Vec<ToolPkgToolLifecycleHookRegistration>>> =
    OnceLock::new();

pub struct ToolPkgToolLifecycleBridge;

impl ToolPkgToolLifecycleBridge {
    /// Registers tool lifecycle hooks for one application runtime.
    pub fn register(runtime: ToolPkgBridgeRuntime) {
        let mut handler = runtime.tool_handler();
        handler.addToolHook(Arc::new(ToolLifecycleBridge { runtime }));
    }

    #[allow(non_snake_case)]
    pub fn syncToolPkgRegistrations(activeContainers: Vec<ToolPkgContainerRuntime>) {
        let hooks = activeContainers
            .iter()
            .flat_map(|container| {
                container.toolLifecycleHooks.iter().map(|hook| {
                    ToolPkgToolLifecycleHookRegistration {
                        containerPackageName: container.packageName.clone(),
                        hookId: hook.id.clone(),
                        functionName: hook.function.clone(),
                        functionSource: hook.functionSource.clone(),
                    }
                })
            })
            .collect::<Vec<_>>();
        *TOOL_LIFECYCLE_HOOKS
            .get_or_init(|| Mutex::new(Vec::new()))
            .lock()
            .expect("toolpkg tool lifecycle hook mutex poisoned") = hooks;
    }
}

struct ToolLifecycleBridge {
    runtime: ToolPkgBridgeRuntime,
}

impl AIToolHook for ToolLifecycleBridge {
    fn id(&self) -> &str {
        "builtin.toolpkg.tool-lifecycle-bridge"
    }

    fn onToolCallRequested(&self, tool: &AITool) {
        let payload = build_base_payload(tool);
        deliver_async(self.runtime.clone(), "tool_call_requested", payload);
    }

    fn onToolCallIntercept(&self, tool: &AITool) -> AIToolHookDecision {
        let payload = build_base_payload(tool);
        let manager = match self.runtime.try_package_manager() {
            Some(manager) => manager,
            None => {
                ChainLogger::warn(
                    PLUGIN_CHAIN,
                    "plugin.toolpkg.tool_lifecycle.intercept.skip",
                    &[
                        ("tool", tool.name.clone()),
                        ("reason", "package manager lock busy".to_string()),
                    ],
                );
                return AIToolHookDecision::Allow;
            }
        };
        let hooks = TOOL_LIFECYCLE_HOOKS
            .get_or_init(|| Mutex::new(Vec::new()))
            .lock()
            .expect("toolpkg tool lifecycle hook mutex poisoned")
            .clone();
        for hook in hooks {
            let result = manager.runToolPkgMainHook(
                &hook.containerPackageName,
                &hook.functionName,
                TOOLPKG_EVENT_TOOL_LIFECYCLE,
                Some("tool_call_intercept"),
                Some(&hook.hookId),
                hook.functionSource.as_deref(),
                payload.clone(),
                None,
                None,
                None,
            );
            let decoded = match result {
                Ok(raw) => operit_plugin_sdk::toolpkg::ToolPkgHooks::decodeToolPkgHookResult(raw),
                Err(error) => {
                    ChainLogger::error(
                        PLUGIN_CHAIN,
                        "plugin.toolpkg.tool_lifecycle.intercept.error",
                        &[("error", error)],
                    );
                    return AIToolHookDecision::Block(
                        "ToolPkg tool lifecycle intercept failed.".to_string(),
                    );
                }
            };
            return decide_intercept_action(decoded.as_ref());
        }
        AIToolHookDecision::Allow
    }

    fn onToolPermissionChecked(&self, tool: &AITool, granted: bool, reason: Option<&str>) {
        let mut payload = build_base_payload(tool);
        payload["granted"] = Value::Bool(granted);
        payload["reason"] = reason
            .map(|value| Value::String(value.to_string()))
            .unwrap_or(Value::Null);
        deliver_async(self.runtime.clone(), "tool_permission_checked", payload);
    }

    fn onToolExecutionStarted(&self, tool: &AITool) {
        deliver_async(
            self.runtime.clone(),
            "tool_execution_started",
            build_base_payload(tool),
        );
    }

    fn onToolExecutionResult(&self, tool: &AITool, result: &ToolResult) {
        let mut payload = build_base_payload(tool);
        payload["success"] = Value::Bool(result.success);
        payload["errorMessage"] = result
            .error
            .as_ref()
            .map(|value| Value::String(value.clone()))
            .unwrap_or(Value::Null);
        payload["resultText"] = Value::String(result.result.toString());
        payload["resultJson"] =
            serde_json::from_str::<Value>(&result.result.toJson()).unwrap_or(Value::Null);
        deliver_async(self.runtime.clone(), "tool_execution_result", payload);
    }

    fn onToolExecutionError(&self, tool: &AITool, message: &str) {
        let mut payload = build_base_payload(tool);
        payload["success"] = Value::Bool(false);
        payload["errorMessage"] = Value::String(message.to_string());
        deliver_async(self.runtime.clone(), "tool_execution_error", payload);
    }

    fn onToolExecutionFinished(&self, tool: &AITool) {
        deliver_async(
            self.runtime.clone(),
            "tool_execution_finished",
            build_base_payload(tool),
        );
    }
}

fn build_base_payload(tool: &AITool) -> Value {
    let parameters = tool
        .parameters
        .iter()
        .map(|parameter| {
            (
                parameter.name.clone(),
                Value::String(parameter.value.clone()),
            )
        })
        .collect::<serde_json::Map<_, _>>();
    serde_json::json!({
        "toolName": tool.name,
        "parameters": parameters,
        "description": null
    })
}

fn deliver(runtime: &ToolPkgBridgeRuntime, eventName: &str, eventPayload: Value) {
    let snapshot = TOOL_LIFECYCLE_HOOKS
        .get_or_init(|| Mutex::new(Vec::new()))
        .lock()
        .expect("toolpkg tool lifecycle hook mutex poisoned")
        .clone();
    ChainLogger::info(
        PLUGIN_CHAIN,
        "plugin.toolpkg.tool_lifecycle.scan",
        &[
            ("event", eventName.to_string()),
            ("hookCount", snapshot.len().to_string()),
        ],
    );
    let manager = match runtime.try_package_manager() {
        Some(manager) => manager,
        None => {
            ChainLogger::warn(
                PLUGIN_CHAIN,
                "plugin.toolpkg.tool_lifecycle.skip",
                &[
                    ("event", eventName.to_string()),
                    ("reason", "package manager lock busy".to_string()),
                ],
            );
            return;
        }
    };
    for hook in snapshot {
        ChainLogger::info(
            PLUGIN_CHAIN,
            "plugin.toolpkg.tool_lifecycle.run.start",
            &[
                ("event", eventName.to_string()),
                ("package", hook.containerPackageName.clone()),
                ("hookId", hook.hookId.clone()),
                ("function", hook.functionName.clone()),
            ],
        );
        match manager.runToolPkgMainHook(
            &hook.containerPackageName,
            &hook.functionName,
            TOOLPKG_EVENT_TOOL_LIFECYCLE,
            Some(eventName),
            Some(&hook.hookId),
            hook.functionSource.as_deref(),
            eventPayload.clone(),
            None,
            None,
            None,
        ) {
            Ok(_) => ChainLogger::info(
                PLUGIN_CHAIN,
                "plugin.toolpkg.tool_lifecycle.run.done",
                &[
                    ("event", eventName.to_string()),
                    ("package", hook.containerPackageName.clone()),
                    ("hookId", hook.hookId.clone()),
                ],
            ),
            Err(error) => ChainLogger::error(
                PLUGIN_CHAIN,
                "plugin.toolpkg.tool_lifecycle.run.error",
                &[
                    ("event", eventName.to_string()),
                    ("package", hook.containerPackageName.clone()),
                    ("hookId", hook.hookId.clone()),
                    ("function", hook.functionName.clone()),
                    ("error", error),
                ],
            ),
        }
    }
}

/// Fire-and-forget variant of `deliver`.
///
/// Tool lifecycle notifications are pure events whose results are never
/// consumed by the caller, yet the synchronous `deliver` used to block the
/// WASM worker thread for up to 60s: it re-enters `getOrCreatePackageManager`'s
/// non-reentrant Mutex while that same lock was already held elsewhere on the
/// worker thread (e.g. during a compose_dsl render that triggered a tool call),
/// deadlocking until the 60s script watchdog killed the render. Dispatching
/// the delivery to the host task scheduler lets `executeTool` return
/// immediately instead of self-deadlocking. When no scheduler is available we
/// fall back to the old synchronous behaviour.
#[allow(non_snake_case)]
fn deliver_async(runtime: ToolPkgBridgeRuntime, eventName: &str, eventPayload: Value) {
    match runtime.host_manager().hostRuntimeTaskSchedulerHost.as_ref() {
        Some(scheduler) => {
            let event = eventName.to_string();
            let _ = scheduler.scheduleHostRuntimeTask(
                "toolpkg.tool_lifecycle",
                Box::new(move || {
                    deliver(&runtime, &event, eventPayload);
                }),
            );
        }
        None => {
            deliver(&runtime, eventName, eventPayload);
        }
    }
}

/// Pure decision helper extracted from `onToolCallIntercept` so the
/// block / allow / unknown branching — the exact branch that made the 60s
/// worker self-deadlock so painful to debug — is unit-testable without a
/// runtime or a live package manager.
fn decide_intercept_action(decoded: Option<&Value>) -> AIToolHookDecision {
    let Some(object) = decoded.and_then(|value| value.as_object()) else {
        return AIToolHookDecision::Allow;
    };
    match object
        .get("action")
        .and_then(Value::as_str)
        .map(|value| value.trim().to_ascii_lowercase())
        .as_deref()
    {
        Some("block") => {
            let reason = object
                .get("reason")
                .and_then(Value::as_str)
                .filter(|value| !value.trim().is_empty())
                .unwrap_or("ToolPkg tool lifecycle hook blocked the tool call.");
            AIToolHookDecision::Block(reason.to_string())
        }
        Some("allow") | None | Some(_) => AIToolHookDecision::Allow,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn intercept_allows_when_payload_missing() {
        assert!(matches!(
            decide_intercept_action(None),
            AIToolHookDecision::Allow
        ));
    }

    #[test]
    fn intercept_blocks_with_explicit_reason() {
        let payload = json!({ "action": "BLOCK", "reason": "denied by policy" });
        if let AIToolHookDecision::Block(reason) = decide_intercept_action(Some(&payload)) {
            assert_eq!(reason, "denied by policy");
        } else {
            panic!("expected Block decision");
        }
    }

    #[test]
    fn intercept_blocks_with_default_reason_when_reason_empty() {
        let payload = json!({ "action": "block", "reason": "   " });
        if let AIToolHookDecision::Block(reason) = decide_intercept_action(Some(&payload)) {
            assert_eq!(reason, "ToolPkg tool lifecycle hook blocked the tool call.");
        } else {
            panic!("expected Block decision");
        }
    }

    #[test]
    fn intercept_allows_on_allow_and_unknown_and_absent_action() {
        assert!(matches!(
            decide_intercept_action(Some(&json!({ "action": "allow" }))),
            AIToolHookDecision::Allow
        ));
        assert!(matches!(
            decide_intercept_action(Some(&json!({ "action": "frobnicate" }))),
            AIToolHookDecision::Allow
        ));
        assert!(matches!(
            decide_intercept_action(Some(&json!({}))),
            AIToolHookDecision::Allow
        ));
    }
}
