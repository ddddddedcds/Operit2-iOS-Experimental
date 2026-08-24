//! Workflow surface for the app runtime.
//!
//! The pure engine (executor + scheduler + repository) lives in
//! `operit-workflow-core` so the standalone iOS daemon can link it without the
//! full tool system. This module re-exports it and adds the app-only
//! [`ToolSystemWorkflowAction`] that wires ExecuteNode to the chat tool pipeline.

pub mod ToolSystemWorkflowAction;

pub use operit_workflow_core::WorkflowExecutor;
pub use operit_workflow_core::WorkflowScheduler;
pub use operit_workflow_core::{
    NodeExecutionState, WorkflowAction, WorkflowExecutionResult,
};
