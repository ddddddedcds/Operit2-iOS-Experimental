//! Workflow Step 2: wire [`WorkflowAction`] to the fork's tool system.
//!
//! [`ToolSystemWorkflowAction`] executes an [`ExecuteNode`] by invoking the
//! same tool execution pipeline the chat uses (`ToolExecutionManager`).
//! It holds a clone of the runtime `AIToolHandler` plus the shared package
//! manager, so workflow execution does not need to lock the whole
//! `OperitApplication` while tools run.

use std::sync::Arc;

use operit_model::Workflow::Workflow;
use operit_tools::ToolExecutionManager::{
    AITool, ToolExecutionManager, ToolExposureMode, ToolInvocation, ToolParameter,
};
use operit_tools::tools::AIToolHandler::AIToolHandler;
use operit_tools::tools::packTool::RuntimePackageManager::RuntimePackageManager;
use operit_tools::tools::packTool::TracedMutex;

use super::WorkflowExecutor::WorkflowAction;

/// Executes workflow ExecuteNodes through the chat tool pipeline.
pub struct ToolSystemWorkflowAction {
    tool_handler: AIToolHandler,
    package_manager: Arc<TracedMutex<RuntimePackageManager>>,
}

impl ToolSystemWorkflowAction {
    /// Creates an action from the runtime tool handler and its package manager.
    pub fn new(tool_handler: AIToolHandler, package_manager: Arc<TracedMutex<RuntimePackageManager>>) -> Self {
        Self {
            tool_handler,
            package_manager,
        }
    }
}

#[async_trait::async_trait]
impl WorkflowAction for ToolSystemWorkflowAction {
    async fn execute(
        &self,
        action_type: &str,
        parameters: &[(String, String)],
    ) -> Result<String, String> {
        let tool_name = action_type.trim();
        if tool_name.is_empty() {
            return Err("ExecuteNode action type is empty".to_string());
        }

        // Snapshot the package manager (mirrors EnhancedAIService).
        let package_manager_snapshot = self
            .package_manager
            .lock()
            .map_err(|_| "package manager mutex poisoned".to_string())?
            .clone();

        let mut handler = self.tool_handler.clone();
        handler.registerDefaultTools();

        let tool_parameters = parameters
            .iter()
            .map(|(name, value)| ToolParameter {
                name: name.clone(),
                value: value.clone(),
            })
            .collect::<Vec<_>>();

        let invocation = ToolInvocation {
            tool: AITool {
                name: tool_name.to_string(),
                parameters: tool_parameters,
            },
            rawText: format!("<tool name=\"{tool_name}\">workflow-execute</tool>"),
            responseLocation: (0, 0),
        };

        let (emitted_messages, results) = ToolExecutionManager::executeInvocations(
            &[invocation],
            &mut handler,
            &package_manager_snapshot,
            None, // callerName
            None, // callerChatId
            None, // callerCardId
            None, // workspacePath
            ToolExposureMode::FULL,
        )
        .await;

        // Successful tool calls surface in emitted messages; failures carry
        // an error on the ToolResult.
        let first_failure = results.iter().find(|result| !result.success);
        if let Some(failure) = first_failure {
            return Err(failure
                .error
                .clone()
                .unwrap_or_else(|| format!("tool '{}' failed", failure.toolName)));
        }

        let emitted = emitted_messages.join("\n");
        if !emitted.trim().is_empty() {
            return Ok(emitted);
        }

        // Fall back to the first success result body.
        if let Some(result) = results.first() {
            let body = result.result.toJson();
            if !body.trim().is_empty() && body.trim() != "null" {
                return Ok(body);
            }
        }

        Ok(String::new())
    }
}

/// Helper to build a [`ToolSystemWorkflowAction`] from an application handle.
/// Kept as a small factory so callers do not need to reach into internals.
///
/// NOTE: the application mutex is `tokio::sync::Mutex` (see LocalCoreProxy),
/// so this helper must run inside an async context that owns the lock guard.
/// Callers outside async contexts should instead build the action directly
/// from `app.aiToolHandler()` + `app.packageManager()`.
pub async fn workflow_action_from_application(
    application: &std::sync::Arc<tokio::sync::Mutex<crate::core::application::OperitApplication::OperitApplication>>,
) -> Result<ToolSystemWorkflowAction, String> {
    let app = application.lock().await;
    let tool_handler = app.aiToolHandler();
    let package_manager = app.packageManager();
    Ok(ToolSystemWorkflowAction::new(tool_handler, package_manager))
}

/// Re-exports so the executor module can construct workflows with tool actions.
#[allow(unused_imports)]
pub use operit_model::Workflow as WorkflowModel;
