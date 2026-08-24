//! Extension dispatch for hand-added core methods that are not part of the
//! generated core-proxy protocol (waifu, workflow, ...).
//!
//! `dispatchCall` first asks this module whether it owns the (target, method)
//! pair; when it returns `Some`, that result is used. Otherwise the call falls
//! through to the generated dispatcher. Keeping extensions here (instead of
//! inline `if` blocks inside `dispatchCall`) means each new method is one match
//! arm, visible in one place, with no coupling to the codegen output.

use operit_link::{CoreCallRequest, CoreLinkError, CoreValue};

use crate::{LocalCoreProxy, decode_core_arg, object_args, to_core_value};

/// Extension dispatch table. Returns `Some(result)` when the request belongs to
/// this extension surface; `None` when it should fall through to codegen.
#[allow(non_snake_case)]
pub async fn dispatchExtension(
    proxy: &LocalCoreProxy,
    request: &CoreCallRequest,
) -> Option<Result<CoreValue, CoreLinkError>> {
    let key = request.targetPath.key();
    match (key.as_str(), request.methodName.as_str()) {
        // waifu.splitMessageBySentences
        ("waifu", "splitMessageBySentences") => Some(waifu_split_sentences(request)),
        // workflow.*
        ("workflow", "execute") => Some(workflow_execute(proxy, request).await),
        ("workflow", "schedulerPoll") => Some(workflow_scheduler_poll(request)),
        ("workflow", "scheduleDaemon") => Some(workflow_schedule_daemon(request)),
        ("workflow", "daemonList") => Some(workflow_daemon_list(request)),
        _ => None,
    }
}

fn waifu_split_sentences(request: &CoreCallRequest) -> Result<CoreValue, CoreLinkError> {
    let mut args = object_args(request.args.clone())?;
    let content: String = decode_core_arg(&mut args, "content")?;
    let remove_punctuation: bool = decode_core_arg(&mut args, "removePunctuation")?;
    let sentences =
        operit_util::WaifuMessageProcessor::WaifuMessageProcessor::split_message_by_sentences(
            &content,
            remove_punctuation,
        );
    to_core_value(sentences)
}

async fn workflow_execute(
    proxy: &LocalCoreProxy,
    request: &CoreCallRequest,
) -> Result<CoreValue, CoreLinkError> {
    let mut args = object_args(request.args.clone())?;
    let workflow_json: String = decode_core_arg(&mut args, "workflowJson")?;
    let extras_json: String = decode_core_arg(&mut args, "triggerExtras")?;
    let workflow: operit_model::Workflow::Workflow = serde_json::from_str(&workflow_json)
        .map_err(|error| CoreLinkError::new("INVALID_ARGS", format!("workflowJson: {error}")))?;
    let extras: std::collections::HashMap<String, String> =
        serde_json::from_str(&extras_json).unwrap_or_default();

    // Build a tool-capable action from the application.
    let application = proxy.application.lock().await;
    let tool_handler = application.aiToolHandler();
    let package_manager = application.packageManager();
    drop(application);
    let action =
        operit_runtime::core::workflow::ToolSystemWorkflowAction::ToolSystemWorkflowAction::new(
            tool_handler,
            package_manager,
        );
    let executor =
        operit_runtime::core::workflow::WorkflowExecutor::WorkflowExecutor::with_action(Box::new(
            action,
        ));
    let result = executor.execute(&workflow, &extras);
    let payload = serde_json::json!({
        "success": result.success,
        "message": result.message,
        "nodes": result.node_results.iter().map(|(id, state)| {
            serde_json::json!({
                "id": id,
                "state": match state {
                    operit_runtime::core::workflow::WorkflowExecutor::NodeExecutionState::Success(v) => serde_json::json!({"kind": "success", "value": v}),
                    operit_runtime::core::workflow::WorkflowExecutor::NodeExecutionState::Skipped(r) => serde_json::json!({"kind": "skipped", "value": r}),
                    operit_runtime::core::workflow::WorkflowExecutor::NodeExecutionState::Failed(e) => serde_json::json!({"kind": "failed", "value": e}),
                    _ => serde_json::json!({"kind": "pending"}),
                }
            })
        }).collect::<Vec<_>>(),
    });
    to_core_value(payload)
}

fn workflow_scheduler_poll(request: &CoreCallRequest) -> Result<CoreValue, CoreLinkError> {
    let mut args = object_args(request.args.clone())?;
    let workflows_json: String = decode_core_arg(&mut args, "workflowsJson")?;
    let now_ms: i64 = decode_core_arg(&mut args, "nowMs")?;
    let workflows: Vec<operit_model::Workflow::Workflow> = serde_json::from_str(&workflows_json)
        .map_err(|error| CoreLinkError::new("INVALID_ARGS", format!("workflowsJson: {error}")))?;
    let due = operit_runtime::core::workflow::WorkflowScheduler::WorkflowScheduler::poll(
        &workflows,
        now_ms,
    );
    to_core_value(due)
}

/// Forwards a workflow to the standalone daemon for daemon-side scheduling
/// (survives app termination). The daemon owns the 8890 control socket, so the
/// app-embedded core acts as a relay: `workflow.scheduleDaemon(workflowJson)`.
fn workflow_schedule_daemon(request: &CoreCallRequest) -> Result<CoreValue, CoreLinkError> {
    let mut args = object_args(request.args.clone())?;
    let workflow_json: String = decode_core_arg(&mut args, "workflowJson")?;
    let response = daemon_tcp_command(&format!("workflow.schedule {workflow_json}\n"));
    to_core_value(response)
}

/// Lists workflows registered on the daemon: `workflow.daemonList`.
fn workflow_daemon_list(request: &CoreCallRequest) -> Result<CoreValue, CoreLinkError> {
    let _ = request;
    let response = daemon_tcp_command("workflow.list\n");
    to_core_value(response)
}

/// Sends one line to the daemon control socket (127.0.0.1:8890) and returns the
/// daemon's reply (or an error string when the daemon is unreachable).
///
/// `std::net` is forbidden by the Wasm platform boundary guard, so this relay
/// is compiled out on wasm (the daemon only exists on iOS anyway).
#[cfg(not(target_arch = "wasm32"))]
fn daemon_tcp_command(payload: &str) -> String {
    use std::io::{Read, Write};
    use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpStream};

    let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1)), 8890);
    let mut stream = match TcpStream::connect_timeout(&addr, std::time::Duration::from_millis(1500))
    {
        Ok(s) => s,
        Err(_) => return "ERR|daemon unreachable".to_string(),
    };
    if stream.write_all(payload.as_bytes()).is_err() {
        return "ERR|daemon write failed".to_string();
    }
    let mut resp = String::new();
    let _ = stream.read_to_string(&mut resp);
    if resp.trim().is_empty() {
        "ERR|daemon empty response".to_string()
    } else {
        resp.trim().to_string()
    }
}

#[cfg(target_arch = "wasm32")]
fn daemon_tcp_command(_payload: &str) -> String {
    "ERR|daemon relay not available on wasm".to_string()
}
