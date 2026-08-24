//! operit-workflow-core: jailbreak-process-agnostic workflow engine.
//!
//! Contains the pure execution engine ([`WorkflowExecutor`]), the polling
//! scheduler ([`WorkflowScheduler`]) and JSON persistence ([`WorkflowRepository`]).
//! It depends only on `operit-model` + `operit-host-api`, so both the app-embedded
//! runtime and the standalone iOS daemon can link it without pulling the full
//! tool system.
//!
//! The app-only `ToolSystemWorkflowAction` (wiring ExecuteNode to the chat tool
//! pipeline) stays in `operit-runtime::core::workflow`.

pub mod WorkflowExecutor;
pub mod WorkflowRepository;
pub mod WorkflowScheduler;

pub use WorkflowExecutor::{NodeExecutionState, WorkflowAction, WorkflowExecutionResult};
pub use WorkflowRepository::build_execution_record;
pub use WorkflowScheduler::{CONFIG_CRON_EXPRESSION, CONFIG_INTERVAL_MS, CONFIG_REPEAT, CONFIG_SCHEDULE_TYPE, CONFIG_SPECIFIC_TIME, SCHEDULE_TYPE_CRON, SCHEDULE_TYPE_INTERVAL, SCHEDULE_TYPE_SPECIFIC_TIME};
