//! Workflow repository: JSON persistence for workflows and their execution
//! records, using the runtime storage host (same pattern as
//! UserMarkdownRepository).

use std::sync::Arc;

use operit_host_api::RuntimeStorageHost;
use operit_model::Workflow::Workflow;
use operit_model::WorkflowExecutionLog::{WorkflowExecutionRecord, WorkflowLogLevel};

/// Persists workflows and execution records under `workflows/`.
pub struct WorkflowRepository {
    storageHost: Arc<dyn RuntimeStorageHost>,
}

impl WorkflowRepository {
    /// Creates a repository backed by the runtime storage host.
    pub fn new(storageHost: Arc<dyn RuntimeStorageHost>) -> Self {
        Self { storageHost }
    }

    fn workflow_path(&self, id: &str) -> String {
        format!("workflows/{}.json", sanitize_id(id))
    }

    fn record_path(&self, workflow_id: &str, record_id: &str) -> String {
        format!("workflows/records/{}/{}.json", sanitize_id(workflow_id), sanitize_id(record_id))
    }

    /// Lists all persisted workflows.
    pub fn listWorkflows(&self) -> Result<Vec<Workflow>, String> {
        let entries = self
            .storageHost
            .list("workflows/")
            .map_err(|error| format!("list workflows failed: {error}"))?;
        let mut workflows = Vec::new();
        for entry in entries {
            let path = entry.path.clone();
            if !path.ends_with(".json") {
                continue;
            }
            if let Ok(bytes) = self.storageHost.readBytes(&path) {
                if let Ok(workflow) = serde_json::from_slice::<Workflow>(&bytes) {
                    workflows.push(workflow);
                }
            }
        }
        workflows.sort_by(|left, right| right.updatedAt.cmp(&left.updatedAt));
        Ok(workflows)
    }

    /// Loads one workflow by id.
    pub fn getWorkflow(&self, id: &str) -> Result<Option<Workflow>, String> {
        let path = self.workflow_path(id);
        if !self
            .storageHost
            .exists(&path)
            .map_err(|error| format!("check workflow exists failed: {error}"))?
        {
            return Ok(None);
        }
        let bytes = self
            .storageHost
            .readBytes(&path)
            .map_err(|error| format!("read workflow failed: {error}"))?;
        let workflow = serde_json::from_slice(&bytes)
            .map_err(|error| format!("parse workflow failed: {error}"))?;
        Ok(Some(workflow))
    }

    /// Saves (create or update) a workflow.
    pub fn saveWorkflow(&self, workflow: &Workflow) -> Result<(), String> {
        let path = self.workflow_path(&workflow.id);
        let bytes = serde_json::to_vec(workflow)
            .map_err(|error| format!("serialize workflow failed: {error}"))?;
        self.storageHost
            .writeBytes(&path, &bytes)
            .map_err(|error| format!("write workflow failed: {error}"))
    }

    /// Deletes a workflow by id.
    pub fn deleteWorkflow(&self, id: &str) -> Result<(), String> {
        let path = self.workflow_path(id);
        self.storageHost
            .delete(&path, false)
            .map_err(|error| format!("delete workflow failed: {error}"))
    }

    /// Appends an execution record for a workflow.
    pub fn saveExecutionRecord(&self, workflow_id: &str, record: &WorkflowExecutionRecord) -> Result<(), String> {
        let path = self.record_path(workflow_id, &record.id);
        let bytes = serde_json::to_vec(record)
            .map_err(|error| format!("serialize record failed: {error}"))?;
        self.storageHost
            .writeBytes(&path, &bytes)
            .map_err(|error| format!("write record failed: {error}"))
    }

    /// Lists execution records for a workflow (most recent first).
    pub fn listExecutionRecords(&self, workflow_id: &str) -> Result<Vec<WorkflowExecutionRecord>, String> {
        let prefix = format!("workflows/records/{}/", sanitize_id(workflow_id));
        let entries = self
            .storageHost
            .list(&prefix)
            .map_err(|error| format!("list records failed: {error}"))?;
        let mut records = Vec::new();
        for entry in entries {
            let path = entry.path.clone();
            if !path.ends_with(".json") {
                continue;
            }
            if let Ok(bytes) = self.storageHost.readBytes(&path) {
                if let Ok(record) = serde_json::from_slice::<WorkflowExecutionRecord>(&bytes) {
                    records.push(record);
                }
            }
        }
        records.reverse();
        Ok(records)
    }
}

/// Builds a simple execution record from node outcomes.
pub fn build_execution_record(
    workflow_id: &str,
    success: bool,
    message: String,
) -> WorkflowExecutionRecord {
    WorkflowExecutionRecord {
        id: format!("rec-{}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0)),
        entries: vec![operit_model::WorkflowExecutionLog::WorkflowExecutionLogEntry {
            level: if success { WorkflowLogLevel::INFO } else { WorkflowLogLevel::ERROR },
            message,
        }],
    }
}

fn sanitize_id(id: &str) -> String {
    id.chars()
        .filter(|ch| ch.is_ascii_alphanumeric() || *ch == '-' || *ch == '_' || *ch == '.')
        .collect()
}
