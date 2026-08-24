use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub enum WorkflowLogLevel {
    INFO,
    WARN,
    ERROR,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct WorkflowExecutionLogEntry {
    pub level: WorkflowLogLevel,
    pub message: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct WorkflowExecutionRecord {
    pub id: String,
    pub entries: Vec<WorkflowExecutionLogEntry>,
}
