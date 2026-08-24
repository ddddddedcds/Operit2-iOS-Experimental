//! Workflow execution engine (Step 1: core, no external tool dependency).
//!
//! Ported from the upstream Operit (Android/Kotlin) `WorkflowExecutor.kt`:
//! dependency-graph build (explicit connections + parameter-reference edges),
//! cycle detection (DFS three-color), reachability (forward+reverse BFS),
//! topological execution (Kahn) with conditional edge evaluation
//! (error/success/true/false/regex), and per-node execution for
//! Condition / Logic / Extract nodes. Execute nodes are abstracted behind
//! [`WorkflowAction`] so tool execution can be wired up later (Step 2).

use std::collections::{HashMap, HashSet, VecDeque};

use operit_model::Workflow::{
    ConditionNode, ConditionOperator, ExecuteNode, ExtractMode, ExtractNode, LogicNode,
    LogicOperator, ParameterValue, TriggerNode, Workflow, WorkflowNode, WorkflowNodeConnection,
};

/// Per-node execution state.
#[derive(Debug, Clone, PartialEq)]
pub enum NodeExecutionState {
    Pending,
    Running,
    Success(String),
    Skipped(String),
    Failed(String),
}

impl NodeExecutionState {
    pub fn is_skipped(&self) -> bool {
        matches!(self, NodeExecutionState::Skipped(_))
    }
    pub fn is_success(&self) -> bool {
        matches!(self, NodeExecutionState::Success(_))
    }
    pub fn is_failed(&self) -> bool {
        matches!(self, NodeExecutionState::Failed(_))
    }
    pub fn result(&self) -> Option<&str> {
        match self {
            NodeExecutionState::Success(result) => Some(result),
            NodeExecutionState::Skipped(reason) => Some(reason),
            _ => None,
        }
    }
}

/// Dependency graph: adjacency list + in-degree.
#[derive(Debug, Clone)]
pub struct DependencyGraph {
    pub adjacency_list: HashMap<String, Vec<String>>,
    pub in_degree: HashMap<String, usize>,
}

/// Workflow execution result.
#[derive(Debug, Clone)]
pub struct WorkflowExecutionResult {
    pub workflow_id: String,
    pub success: bool,
    pub node_results: HashMap<String, NodeExecutionState>,
    pub message: String,
}

/// Action executed by an [`ExecuteNode`]. Step 2 wires this to the fork's tool
/// system (`operit-tools` / TS plugins). Step 1 keeps it a plain trait so the
/// engine compiles and is fully testable without tools.
#[async_trait::async_trait]
pub trait WorkflowAction: Send + Sync {
    /// Executes one tool action with resolved parameters.
    async fn execute(
        &self,
        action_type: &str,
        parameters: &[(String, String)],
    ) -> Result<String, String>;
}

/// Workflow executor (core engine, no external tool dependency in Step 1).
pub struct WorkflowExecutor {
    action: Option<Box<dyn WorkflowAction>>,
}

impl WorkflowExecutor {
    pub fn new() -> Self {
        Self { action: None }
    }

    pub fn with_action(action: Box<dyn WorkflowAction>) -> Self {
        Self { action: Some(action) }
    }

    /// Executes a workflow. Returns node results keyed by node id.
    pub fn execute(&self, workflow: &Workflow, trigger_extras: &HashMap<String, String>) -> WorkflowExecutionResult {
        let mut node_results: HashMap<String, NodeExecutionState> = HashMap::new();

        // 1. Find trigger nodes.
        let all_trigger_nodes: Vec<&TriggerNode> = workflow
            .nodes
            .iter()
            .filter_map(|node| match node {
                WorkflowNode::Trigger(t) => Some(t),
                _ => None,
            })
            .collect();

        if all_trigger_nodes.is_empty() {
            return WorkflowExecutionResult {
                workflow_id: workflow.id.clone(),
                success: false,
                node_results,
                message: "Workflow has no trigger node, cannot execute".to_string(),
            };
        }

        // Manual triggers only when no specific trigger is requested (Step 1 runs all).
        let trigger_nodes: Vec<&TriggerNode> = all_trigger_nodes
            .iter()
            .filter(|t| t.triggerType == "manual" || t.triggerType == "schedule")
            .cloned()
            .collect();
        if trigger_nodes.is_empty() {
            return WorkflowExecutionResult {
                workflow_id: workflow.id.clone(),
                success: false,
                node_results,
                message: "No manual/schedule trigger type trigger node".to_string(),
            };
        }

        // 2. Build dependency graph (explicit connections + reference deps).
        let dependency_graph = build_dependency_graph(workflow);

        // 3. Cycle detection.
        if detect_cycle(&dependency_graph.adjacency_list, workflow) {
            return WorkflowExecutionResult {
                workflow_id: workflow.id.clone(),
                success: false,
                node_results,
                message: "Workflow has circular dependencies, cannot execute".to_string(),
            };
        }

        // 4. Mark trigger nodes as success (payload = serialized extras).
        let trigger_payload = serde_json::to_string(trigger_extras).unwrap_or_else(|_| "{}".to_string());
        let trigger_ids: Vec<String> = trigger_nodes.iter().map(|t| t.id.clone()).collect();
        for trigger in &trigger_nodes {
            node_results.insert(trigger.id.clone(), NodeExecutionState::Success(trigger_payload.clone()));
        }

        // 5. Topological execution.
        let ok = self.execute_topological_order(
            workflow,
            &dependency_graph,
            &trigger_ids,
            &trigger_payload,
            &mut node_results,
        );

        WorkflowExecutionResult {
            workflow_id: workflow.id.clone(),
            success: ok,
            node_results,
            message: if ok { "Workflow executed successfully".to_string() } else { "Workflow execution failed".to_string() },
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn execute_topological_order(
        &self,
        workflow: &Workflow,
        dependency_graph: &DependencyGraph,
        trigger_ids: &[String],
        trigger_payload: &str,
        node_results: &mut HashMap<String, NodeExecutionState>,
    ) -> bool {
        let reachable = get_reachable_node_ids(trigger_ids, &dependency_graph.adjacency_list);
        let node_by_id: HashMap<&String, &WorkflowNode> =
            workflow.nodes.iter().map(|n| (n.id(), n)).collect();
        let trigger_id_set: HashSet<&String> = workflow
            .nodes
            .iter()
            .filter_map(|node| match node {
                WorkflowNode::Trigger(t) => Some(&t.id),
                _ => None,
            })
            .collect();
        let started_trigger_ids: HashSet<&String> = trigger_ids.iter().collect();

        let mut queue: VecDeque<String> = VecDeque::new();
        let mut current_in_degree: HashMap<String, usize> = HashMap::new();

        for node_id in &reachable {
            if trigger_id_set.contains(node_id) {
                continue;
            }
            current_in_degree.insert(node_id.clone(), 0);
        }

        for (source_id, targets) in &dependency_graph.adjacency_list {
            if !reachable.contains(source_id) || trigger_id_set.contains(source_id) {
                continue;
            }
            for target_id in targets {
                if !reachable.contains(target_id) || trigger_id_set.contains(target_id) {
                    continue;
                }
                *current_in_degree.entry(target_id.clone()).or_insert(0) += 1;
            }
        }

        for (node_id, degree) in &current_in_degree {
            if *degree == 0 {
                queue.push_back(node_id.clone());
            }
        }

        let mut has_failure = false;

        while let Some(current_node_id) = queue.pop_front() {
            if node_results.contains_key(&current_node_id) {
                continue;
            }
            let Some(node) = node_by_id.get(&current_node_id).copied() else {
                continue;
            };

            // Evaluate incoming conditional edges.
            let incoming: Vec<&WorkflowNodeConnection> = workflow
                .connections
                .iter()
                .filter(|conn| conn.targetNodeId == current_node_id)
                .filter(|conn| reachable.contains(&conn.sourceNodeId))
                .filter(|conn| {
                    !(trigger_id_set.contains(&conn.sourceNodeId)
                        && !started_trigger_ids.contains(&conn.sourceNodeId))
                })
                .collect();

            let should_execute = if incoming.is_empty() {
                true
            } else {
                incoming.iter().any(|conn| {
                    let source_node = node_by_id.get(&conn.sourceNodeId).copied();
                    let source_state = node_results.get(&conn.sourceNodeId);
                    if source_state.map(|s| s.is_skipped()).unwrap_or(false) {
                        return false;
                    }
                    let raw_condition = conn.condition.as_deref().unwrap_or("").trim();
                    let effective_condition = if raw_condition.is_empty()
                        && matches!(
                            source_node,
                            Some(WorkflowNode::Condition(_)) | Some(WorkflowNode::Logic(_))
                        ) {
                        "true"
                    } else {
                        raw_condition
                    };
                    let condition_key = effective_condition.trim().to_lowercase();
                    match condition_key.as_str() {
                        "error" | "failed" | "on_error" => {
                            return source_state.map(|s| s.is_failed()).unwrap_or(false);
                        }
                        "success" | "ok" | "on_success" => {
                            return source_state.map(|s| s.is_success()).unwrap_or(false);
                        }
                        _ => {}
                    }
                    if effective_condition.is_empty() {
                        return source_state.map(|s| s.is_success()).unwrap_or(false);
                    }
                    let desired_bool = match effective_condition.to_lowercase().as_str() {
                        "true" => Some(true),
                        "false" => Some(false),
                        _ => None,
                    };
                    let source_result = source_state.and_then(|s| s.result());
                    let Some(source_result) = source_result else {
                        return false;
                    };
                    if let Some(desired) = desired_bool {
                        return parse_boolean_like(source_result).unwrap_or(false) == desired;
                    }
                    // Treat condition as a regex matched against the source result.
                    regex::Regex::new(effective_condition)
                        .map(|re| re.is_match(source_result))
                        .unwrap_or(false)
                })
            };

            if !should_execute {
                node_results.insert(
                    node.id().clone(),
                    NodeExecutionState::Skipped("Condition not met".to_string()),
                );
                // Propagate to successors.
                if let Some(targets) = dependency_graph.adjacency_list.get(&current_node_id) {
                    for next in targets {
                        if let Some(degree) = current_in_degree.get_mut(next) {
                            *degree = degree.saturating_sub(1);
                            if *degree == 0 {
                                queue.push_back(next.clone());
                            }
                        }
                    }
                }
                continue;
            }

            let node_ok = self.execute_node(
                node,
                workflow,
                &incoming,
                node_by_id.clone(),
                node_results,
                trigger_payload,
            );
            if !node_ok {
                has_failure = true;
            }

            if let Some(targets) = dependency_graph.adjacency_list.get(&current_node_id) {
                for next in targets {
                    if let Some(degree) = current_in_degree.get_mut(next) {
                        *degree = degree.saturating_sub(1);
                        if *degree == 0 {
                            queue.push_back(next.clone());
                        }
                    }
                }
            }
        }

        if !has_failure {
            return true;
        }

        // Error edges that handled a failure make the run acceptable.
        let outgoing_by_source: HashMap<&String, Vec<&WorkflowNodeConnection>> =
            workflow.connections.iter().fold(HashMap::new(), |mut map, conn| {
                map.entry(&conn.sourceNodeId).or_default().push(conn);
                map
            });
        let has_unhandled_failure = node_results.iter().any(|(node_id, state)| {
            if !state.is_failed() {
                return false;
            }
            let handled = outgoing_by_source
                .get(node_id)
                .map(|conns| {
                    conns.iter().any(|conn| {
                        is_error_condition(conn.condition.as_deref())
                            && node_results
                                .get(&conn.targetNodeId)
                                .map(|s| s.is_success())
                                .unwrap_or(false)
                    })
                })
                .unwrap_or(false);
            !handled
        });

        !has_unhandled_failure
    }

    #[allow(clippy::too_many_arguments)]
    fn execute_node(
        &self,
        node: &WorkflowNode,
        _workflow: &Workflow,
        incoming: &[&WorkflowNodeConnection],
        node_by_id: HashMap<&String, &WorkflowNode>,
        node_results: &mut HashMap<String, NodeExecutionState>,
        trigger_payload: &str,
    ) -> bool {
        match node {
            WorkflowNode::Trigger(_) => {
                node_results.insert(node.id().clone(), NodeExecutionState::Success(trigger_payload.to_string()));
                true
            }
            WorkflowNode::Condition(condition) => {
                node_results.insert(node.id().clone(), NodeExecutionState::Running);
                match self.execute_condition(condition, node_results) {
                    Ok(result) => {
                        node_results.insert(node.id().clone(), NodeExecutionState::Success(result.to_string()));
                        true
                    }
                    Err(error) => {
                        node_results.insert(node.id().clone(), NodeExecutionState::Failed(error));
                        false
                    }
                }
            }
            WorkflowNode::Logic(logic) => {
                node_results.insert(node.id().clone(), NodeExecutionState::Running);
                let inputs: Vec<bool> = incoming
                    .iter()
                    .filter_map(|conn| {
                        let state = node_results.get(&conn.sourceNodeId)?;
                        if state.is_skipped() {
                            return None;
                        }
                        parse_boolean_like(state.result()?)
                    })
                    .collect();
                let ok = match logic.operator {
                    LogicOperator::AND => !inputs.is_empty() && inputs.iter().all(|b| *b),
                    LogicOperator::OR => inputs.iter().any(|b| *b),
                };
                node_results.insert(node.id().clone(), NodeExecutionState::Success(ok.to_string()));
                true
            }
            WorkflowNode::Extract(extract) => {
                node_results.insert(node.id().clone(), NodeExecutionState::Running);
                match self.execute_extract(extract, incoming, node_results) {
                    Ok(result) => {
                        node_results.insert(node.id().clone(), NodeExecutionState::Success(result));
                        true
                    }
                    Err(error) => {
                        node_results.insert(node.id().clone(), NodeExecutionState::Failed(error));
                        false
                    }
                }
            }
            WorkflowNode::Execute(execute) => {
                node_results.insert(node.id().clone(), NodeExecutionState::Running);
                if execute.actionType.trim().is_empty() {
                    let error = format!("Execute node '{}' has no action type", execute.name);
                    node_results.insert(node.id().clone(), NodeExecutionState::Failed(error.clone()));
                    return false;
                }
                // Resolve parameters (StaticValue / NodeReference).
                let mut parameters: Vec<(String, String)> = Vec::new();
                let mut resolve_err: Option<String> = None;
                for (key, value) in &execute.actionConfig {
                    match resolve_parameter_value(value, node_results) {
                        Ok(resolved) => {
                            if !key.trim().is_empty() {
                                parameters.push((key.trim().to_string(), resolved));
                            }
                        }
                        Err(error) => {
                            resolve_err = Some(error);
                            break;
                        }
                    }
                }
                if let Some(error) = resolve_err {
                    node_results.insert(node.id().clone(), NodeExecutionState::Failed(error.clone()));
                    return false;
                }
                match &self.action {
                    Some(action) => {
                        // Step 2: async tool execution. For Step 1 we call a
                        // synchronous shim — see execute_action for details.
                        match self.execute_action(action.as_ref(), &execute.actionType, &parameters) {
                            Ok(result) => {
                                node_results.insert(node.id().clone(), NodeExecutionState::Success(result));
                                true
                            }
                            Err(error) => {
                                node_results.insert(node.id().clone(), NodeExecutionState::Failed(error.clone()));
                                false
                            }
                        }
                    }
                    None => {
                        let error = format!(
                            "Execute node '{}' needs action '{}' but no WorkflowAction is registered",
                            execute.name, execute.actionType
                        );
                        node_results.insert(node.id().clone(), NodeExecutionState::Failed(error.clone()));
                        false
                    }
                }
            }
        }
    }

    /// Synchronous wrapper so Step 1 remains fully sync and testable.
    fn execute_action(
        &self,
        action: &dyn WorkflowAction,
        action_type: &str,
        parameters: &[(String, String)],
    ) -> Result<String, String> {
        // Build a small current-thread runtime and drive the async action on
        // the calling thread (no std::thread, so Wasm boundary guards pass).
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|error| format!("failed to build tokio runtime: {error}"))?;
        rt.block_on(action.execute(action_type, parameters))
    }

    fn execute_condition(
        &self,
        condition: &ConditionNode,
        node_results: &HashMap<String, NodeExecutionState>,
    ) -> Result<bool, String> {
        let left = resolve_parameter_value(&condition.left, node_results)?;
        let right = resolve_parameter_value(&condition.right, node_results)?;
        compare_values(&left, &right, &condition.operator)
    }

    fn execute_extract(
        &self,
        extract: &ExtractNode,
        incoming: &[&WorkflowNodeConnection],
        node_results: &HashMap<String, NodeExecutionState>,
    ) -> Result<String, String> {
        let mut source_text = String::new();
        if !matches!(extract.mode, ExtractMode::RANDOM_INT | ExtractMode::RANDOM_STRING) {
            source_text = resolve_parameter_value(&extract.source, node_results)?;
            if source_text.trim().is_empty() && matches!(extract.source, ParameterValue::StaticValue { .. }) {
                if let Some(fallback_id) = incoming.first().map(|conn| conn.sourceNodeId.clone()) {
                    if let Some(state) = node_results.get(&fallback_id) {
                        if state.is_success() && !state.is_skipped() {
                            source_text = state.result().unwrap_or("").to_string();
                        }
                    }
                }
            }
        }

        let extracted = match extract.mode {
            ExtractMode::REGEX => extract_by_regex(
                &source_text,
                &extract.expression,
                extract.group,
                &extract.defaultValue,
            ),
            ExtractMode::JSON => extract_by_json_path(
                &source_text,
                &extract.expression,
                &extract.defaultValue,
            ),
            ExtractMode::SUB => substring_by_index(
                &source_text,
                extract.startIndex,
                extract.length,
                &extract.defaultValue,
            ),
            ExtractMode::CONCAT => {
                let mut other_text = String::new();
                for other in &extract.others {
                    other_text.push_str(&resolve_parameter_value(other, node_results)?);
                }
                format!("{source_text}{other_text}")
            }
            ExtractMode::RANDOM_INT => {
                if extract.useFixed {
                    let fixed = extract.fixedValue.trim();
                    fixed
                        .parse::<i64>()
                        .map_err(|_| format!("fixed value must be an integer: {}", extract.fixedValue))?
                        .to_string()
                } else {
                    random_int(extract.randomMin, extract.randomMax).to_string()
                }
            }
            ExtractMode::RANDOM_STRING => {
                if extract.useFixed {
                    extract.fixedValue.clone()
                } else {
                    random_string(extract.randomStringLength, &extract.randomStringCharset)
                }
            }
        };
        Ok(extracted)
    }
}

impl Default for WorkflowExecutor {
    fn default() -> Self {
        Self::new()
    }
}

// ---------- free helpers ----------

fn is_error_condition(condition: Option<&str>) -> bool {
    matches!(
        condition.map(|c| c.trim().to_lowercase()).as_deref(),
        Some("error") | Some("failed") | Some("on_error")
    )
}

fn parse_boolean_like(value: &str) -> Option<bool> {
    match value.trim().to_lowercase().as_str() {
        "true" | "1" | "yes" | "y" | "on" => Some(true),
        "false" | "0" | "no" | "n" | "off" => Some(false),
        _ => None,
    }
}

fn parse_double_or_null_strict(value: &str) -> Option<f64> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    trimmed.parse::<f64>().ok()
}

fn compare_values(left: &str, right: &str, operator: &ConditionOperator) -> Result<bool, String> {
    let left_num = parse_double_or_null_strict(left);
    let right_num = parse_double_or_null_strict(right);
    let mismatch = || format!("Condition type mismatch: left='{left}', right='{right}'");

    match operator {
        ConditionOperator::EQ => {
            match (left_num, right_num) {
                (Some(l), Some(r)) => Ok(l == r),
                (Some(_), None) | (None, Some(_)) => Err(mismatch()),
                (None, None) => Ok(left == right),
            }
        }
        ConditionOperator::NE => {
            match (left_num, right_num) {
                (Some(l), Some(r)) => Ok(l != r),
                (Some(_), None) | (None, Some(_)) => Err(mismatch()),
                (None, None) => Ok(left != right),
            }
        }
        ConditionOperator::GT => match (left_num, right_num) {
            (Some(l), Some(r)) => Ok(l > r),
            (Some(_), None) | (None, Some(_)) => Err(mismatch()),
            (None, None) => Ok(left > right),
        },
        ConditionOperator::GTE => match (left_num, right_num) {
            (Some(l), Some(r)) => Ok(l >= r),
            (Some(_), None) | (None, Some(_)) => Err(mismatch()),
            (None, None) => Ok(left >= right),
        },
        ConditionOperator::LT => match (left_num, right_num) {
            (Some(l), Some(r)) => Ok(l < r),
            (Some(_), None) | (None, Some(_)) => Err(mismatch()),
            (None, None) => Ok(left < right),
        },
        ConditionOperator::LTE => match (left_num, right_num) {
            (Some(l), Some(r)) => Ok(l <= r),
            (Some(_), None) | (None, Some(_)) => Err(mismatch()),
            (None, None) => Ok(left <= right),
        },
        ConditionOperator::CONTAINS => Ok(left.contains(right)),
        ConditionOperator::NOT_CONTAINS => Ok(!left.contains(right)),
        ConditionOperator::IN | ConditionOperator::NOT_IN => {
            // Parse list: try JSON array (any value type), else comma-separated.
            let items: Vec<String> = serde_json::from_str::<Vec<serde_json::Value>>(right)
                .map(|values| {
                    values
                        .iter()
                        .map(|v| match v {
                            serde_json::Value::String(s) => s.clone(),
                            other => other.to_string(),
                        })
                        .collect()
                })
                .unwrap_or_else(|_| {
                    right
                        .split(',')
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty())
                        .collect()
                });
            let contains = if items.is_empty() {
                false
            } else {
                let left_num = parse_double_or_null_strict(left);
                let item_nums: Vec<Option<f64>> = items.iter().map(|i| parse_double_or_null_strict(i)).collect();
                let list_all_num = item_nums.iter().all(|n| n.is_some());
                let list_all_str = item_nums.iter().all(|n| n.is_none());
                if !list_all_num && !list_all_str {
                    return Err(format!("IN list type mismatch: {right}"));
                }
                if list_all_num {
                    let ln = left_num.ok_or_else(|| mismatch())?;
                    item_nums.into_iter().flatten().any(|n| n == ln)
                } else {
                    if left_num.is_some() {
                        return Err(mismatch());
                    }
                    items.iter().any(|item| item == left)
                }
            };
            if matches!(operator, ConditionOperator::IN) {
                Ok(contains)
            } else {
                Ok(!contains)
            }
        }
    }
}

fn extract_by_regex(source: &str, pattern: &str, group: i32, default_value: &str) -> String {
    if pattern.trim().is_empty() {
        return default_value.to_string();
    }
    match regex::Regex::new(pattern) {
        Ok(re) => re
            .captures(source)
            .and_then(|caps| caps.get(group as usize).map(|m| m.as_str().to_string()))
            .unwrap_or_else(|| default_value.to_string()),
        Err(_) => default_value.to_string(),
    }
}

fn extract_by_json_path(source: &str, path: &str, default_value: &str) -> String {
    if path.trim().is_empty() {
        return default_value.to_string();
    }
    let trimmed = source.trim();
    let value: serde_json::Value = if trimmed.starts_with('[') {
        serde_json::from_str(trimmed).unwrap_or(serde_json::Value::Null)
    } else {
        serde_json::from_str(trimmed).unwrap_or(serde_json::Value::Null)
    };
    if value.is_null() {
        return default_value.to_string();
    }

    let mut current = value;
    for segment in path.split('.').map(|s| s.trim()).filter(|s| !s.is_empty()) {
        // Parse optional [index] suffixes, e.g. "items[0]".
        let (name, indexes) = read_index_token(segment);
        if !name.is_empty() {
            current = current.get(name).cloned().unwrap_or(serde_json::Value::Null);
        }
        for idx in indexes {
            current = current.get(idx).cloned().unwrap_or(serde_json::Value::Null);
        }
        if current.is_null() {
            return default_value.to_string();
        }
    }
    if current.is_null() {
        default_value.to_string()
    } else {
        current.to_string()
    }
}

fn read_index_token(token: &str) -> (String, Vec<usize>) {
    let name = token.split('[').next().unwrap_or("").to_string();
    let mut indexes = Vec::new();
    let mut rest = token;
    while let Some(open) = rest.find('[') {
        rest = &rest[open + 1..];
        if let Some(close) = rest.find(']') {
            if let Ok(idx) = rest[..close].trim().parse::<usize>() {
                indexes.push(idx);
            }
            rest = &rest[close + 1..];
        } else {
            break;
        }
    }
    (name, indexes)
}

fn substring_by_index(source: &str, start_index: i32, length: i32, default_value: &str) -> String {
    if source.is_empty() || start_index < 0 || (start_index as usize) > source.len() {
        return default_value.to_string();
    }
    let start = start_index as usize;
    let end_exclusive = if length < 0 {
        source.len()
    } else {
        (start + length as usize).min(source.len())
    };
    if end_exclusive < start {
        return default_value.to_string();
    }
    source[start..end_exclusive].to_string()
}

fn random_int(min_value: i32, max_value: i32) -> i32 {
    let low = min_value.min(max_value);
    let high = min_value.max(max_value);
    if low == high {
        return low;
    }
    let range = (high as i64) - (low as i64) + 1;
    (low as i64 + (rand_util::next_u64() % range as u64) as i64) as i32
}

fn random_string(length: i32, charset: &str) -> String {
    let safe_length = length.max(0) as usize;
    if safe_length == 0 {
        return String::new();
    }
    let safe_charset = if charset.is_empty() {
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    } else {
        charset
    };
    let chars: Vec<char> = safe_charset.chars().collect();
    if chars.is_empty() {
        return String::new();
    }
    (0..safe_length)
        .map(|_| chars[(rand_util::next_u64() % chars.len() as u64) as usize])
        .collect()
}

/// Minimal non-cryptographic randomness (no external dep needed for Step 1).
mod rand_util {
    use std::sync::atomic::{AtomicU64, Ordering};

    static SEED: AtomicU64 = AtomicU64::new(0);

    pub fn next_u64() -> u64 {
        let mut seed = SEED.load(Ordering::Relaxed);
        if seed == 0 {
            // Use the host time abstraction (std::time is forbidden by the
            // Wasm platform boundary guard).
            let nanos = operit_host_api::TimeUtils::currentTimeMillisU128() as u64;
            seed = nanos ^ 0x9E3779B97F4A7C15;
            SEED.store(seed, Ordering::Relaxed);
        }
        // xorshift64*
        seed ^= seed >> 12;
        seed ^= seed << 25;
        seed ^= seed >> 27;
        SEED.store(seed, Ordering::Relaxed);
        seed.wrapping_mul(0x2545F4914F6CDD1D)
    }
}

fn resolve_parameter_value(
    value: &ParameterValue,
    node_results: &HashMap<String, NodeExecutionState>,
) -> Result<String, String> {
    match value {
        ParameterValue::StaticValue { value } => Ok(value.clone()),
        ParameterValue::NodeReference { nodeId } => {
            match node_results.get(nodeId) {
                Some(NodeExecutionState::Success(result)) => Ok(result.clone()),
                Some(NodeExecutionState::Skipped(reason)) => Ok(reason.clone()),
                Some(NodeExecutionState::Failed(_)) => {
                    Err(format!("Referenced node failed: {nodeId}"))
                }
                _ => Err(format!("Referenced node not completed: {nodeId}")),
            }
        }
    }
}

fn build_reference_dependencies(workflow: &Workflow) -> Vec<(String, String)> {
    let node_id_set: HashSet<&String> = workflow.nodes.iter().map(|n| n.id()).collect();
    let mut dependencies: Vec<(String, String)> = Vec::new();

    fn add_dependency(
        deps: &mut Vec<(String, String)>,
        source_id: &str,
        target_id: &str,
        node_id_set: &HashSet<&String>,
    ) {
        if source_id == target_id {
            return;
        }
        let has_source = node_id_set.iter().any(|s| s.as_str() == source_id);
        let has_target = node_id_set.iter().any(|s| s.as_str() == target_id);
        if !has_source || !has_target {
            return;
        }
        if !deps.iter().any(|(s, t)| s == source_id && t == target_id) {
            deps.push((source_id.to_string(), target_id.to_string()));
        }
    }

    for node in &workflow.nodes {
        match node {
            WorkflowNode::Execute(execute) => {
                for value in execute.actionConfig.values() {
                    if let ParameterValue::NodeReference { nodeId } = value {
                        add_dependency(&mut dependencies, nodeId, &execute.id, &node_id_set);
                    }
                }
            }
            WorkflowNode::Condition(condition) => {
                if let ParameterValue::NodeReference { nodeId } = &condition.left {
                    add_dependency(&mut dependencies, nodeId, &condition.id, &node_id_set);
                }
                if let ParameterValue::NodeReference { nodeId } = &condition.right {
                    add_dependency(&mut dependencies, nodeId, &condition.id, &node_id_set);
                }
            }
            WorkflowNode::Extract(extract) => {
                if let ParameterValue::NodeReference { nodeId } = &extract.source {
                    add_dependency(&mut dependencies, nodeId, &extract.id, &node_id_set);
                }
                for other in &extract.others {
                    if let ParameterValue::NodeReference { nodeId } = other {
                        add_dependency(&mut dependencies, nodeId, &extract.id, &node_id_set);
                    }
                }
            }
            _ => {}
        }
    }
    dependencies
}

fn build_dependency_graph(workflow: &Workflow) -> DependencyGraph {
    let mut adjacency_list: HashMap<String, Vec<String>> = HashMap::new();
    let mut in_degree: HashMap<String, usize> = HashMap::new();

    for node in &workflow.nodes {
        in_degree.insert(node.id().clone(), 0);
        adjacency_list.insert(node.id().clone(), Vec::new());
    }

    fn add_edge(
        adjacency: &mut HashMap<String, Vec<String>>,
        in_degree: &mut HashMap<String, usize>,
        source_id: &str,
        target_id: &str,
    ) {
        if source_id == target_id {
            return;
        }
        let targets = adjacency.entry(source_id.to_string()).or_default();
        if targets.contains(&target_id.to_string()) {
            return;
        }
        targets.push(target_id.to_string());
        *in_degree.entry(target_id.to_string()).or_insert(0) += 1;
    }

    for connection in &workflow.connections {
        add_edge(&mut adjacency_list, &mut in_degree, &connection.sourceNodeId, &connection.targetNodeId);
    }
    for (source_id, target_id) in build_reference_dependencies(workflow) {
        add_edge(&mut adjacency_list, &mut in_degree, &source_id, &target_id);
    }

    DependencyGraph { adjacency_list, in_degree }
}

fn detect_cycle(adjacency_list: &HashMap<String, Vec<String>>, workflow: &Workflow) -> bool {
    // 0 = unvisited, 1 = visiting, 2 = done
    let mut visit_state: HashMap<String, u8> = HashMap::new();
    for node in &workflow.nodes {
        visit_state.insert(node.id().clone(), 0);
    }

    fn dfs(
        node_id: &str,
        adjacency_list: &HashMap<String, Vec<String>>,
        visit_state: &mut HashMap<String, u8>,
    ) -> bool {
        visit_state.insert(node_id.to_string(), 1);
        if let Some(nexts) = adjacency_list.get(node_id) {
            for next in nexts {
                match visit_state.get(next).copied().unwrap_or(0) {
                    1 => return true,
                    0 => {
                        if dfs(next, adjacency_list, visit_state) {
                            return true;
                        }
                    }
                    _ => {}
                }
            }
        }
        visit_state.insert(node_id.to_string(), 2);
        false
    }

    for node in &workflow.nodes {
        if visit_state.get(node.id()).copied().unwrap_or(0) == 0 {
            if dfs(node.id(), adjacency_list, &mut visit_state) {
                return true;
            }
        }
    }
    false
}

fn get_reachable_node_ids(
    start_node_ids: &[String],
    adjacency_list: &HashMap<String, Vec<String>>,
) -> HashSet<String> {
    // Forward BFS.
    let mut forward_visited: HashSet<String> = HashSet::new();
    let mut queue: VecDeque<String> = VecDeque::new();
    for id in start_node_ids {
        if forward_visited.insert(id.clone()) {
            queue.push_back(id.clone());
        }
    }
    while let Some(current) = queue.pop_front() {
        if let Some(nexts) = adjacency_list.get(&current) {
            for next in nexts {
                if forward_visited.insert(next.clone()) {
                    queue.push_back(next.clone());
                }
            }
        }
    }

    // Reverse adjacency + BFS to include nodes feeding the reachable set.
    let mut reverse_adjacency: HashMap<String, Vec<String>> = HashMap::new();
    for (source_id, targets) in adjacency_list {
        for target_id in targets {
            reverse_adjacency.entry(target_id.clone()).or_default().push(source_id.clone());
        }
    }

    let mut visited = forward_visited.clone();
    let mut queue: VecDeque<String> = forward_visited.iter().cloned().collect();
    while let Some(current) = queue.pop_front() {
        if let Some(prev) = reverse_adjacency.get(&current) {
            for p in prev {
                if visited.insert(p.clone()) {
                    queue.push_back(p.clone());
                }
            }
        }
    }
    visited
}

// ---------- WorkflowNode id accessor (model helper) ----------

trait NodeId {
    fn id(&self) -> &String;
}

impl NodeId for WorkflowNode {
    fn id(&self) -> &String {
        match self {
            WorkflowNode::Trigger(t) => &t.id,
            WorkflowNode::Execute(e) => &e.id,
            WorkflowNode::Condition(c) => &c.id,
            WorkflowNode::Logic(l) => &l.id,
            WorkflowNode::Extract(e) => &e.id,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use operit_model::Workflow::{NodePosition, WorkflowNodeConnection};

    fn position(x: f32, y: f32) -> NodePosition {
        NodePosition { x, y }
    }

    fn trigger(id: &str, trigger_type: &str) -> WorkflowNode {
        WorkflowNode::Trigger(TriggerNode {
            id: id.to_string(),
            type_: "trigger".to_string(),
            name: format!("trigger-{id}"),
            description: String::new(),
            position: position(0.0, 0.0),
            triggerType: trigger_type.to_string(),
            triggerConfig: HashMap::new(),
        })
    }

    fn execute(id: &str, action_type: &str, config: HashMap<String, ParameterValue>) -> WorkflowNode {
        WorkflowNode::Execute(ExecuteNode {
            id: id.to_string(),
            type_: "execute".to_string(),
            name: format!("execute-{id}"),
            description: String::new(),
            position: position(0.0, 0.0),
            actionType: action_type.to_string(),
            actionConfig: config,
            jsCode: None,
        })
    }

    fn condition(id: &str, left: ParameterValue, operator: ConditionOperator, right: ParameterValue) -> WorkflowNode {
        WorkflowNode::Condition(ConditionNode {
            id: id.to_string(),
            type_: "condition".to_string(),
            name: format!("condition-{id}"),
            description: String::new(),
            position: position(0.0, 0.0),
            left,
            operator,
            right,
        })
    }

    fn logic(id: &str, operator: LogicOperator) -> WorkflowNode {
        WorkflowNode::Logic(LogicNode {
            id: id.to_string(),
            type_: "logic".to_string(),
            name: format!("logic-{id}"),
            description: String::new(),
            position: position(0.0, 0.0),
            operator,
        })
    }

    fn extract(id: &str, mode: ExtractMode, source: ParameterValue) -> WorkflowNode {
        WorkflowNode::Extract(ExtractNode {
            id: id.to_string(),
            type_: "extract".to_string(),
            name: format!("extract-{id}"),
            description: String::new(),
            position: position(0.0, 0.0),
            source,
            mode,
            expression: String::new(),
            group: 0,
            defaultValue: String::new(),
            others: Vec::new(),
            startIndex: 0,
            length: 0,
            randomMin: 0,
            randomMax: 0,
            randomStringLength: 0,
            randomStringCharset: String::new(),
            useFixed: false,
            fixedValue: String::new(),
        })
    }

    fn conn(source: &str, target: &str, condition: Option<&str>) -> WorkflowNodeConnection {
        WorkflowNodeConnection {
            id: format!("{source}->{target}"),
            sourceNodeId: source.to_string(),
            targetNodeId: target.to_string(),
            condition: condition.map(|s| s.to_string()),
        }
    }

    fn workflow(nodes: Vec<WorkflowNode>, connections: Vec<WorkflowNodeConnection>) -> Workflow {
        Workflow {
            id: "wf-test".to_string(),
            name: "Test".to_string(),
            description: String::new(),
            nodes,
            connections,
            createdAt: 0,
            updatedAt: 0,
            enabled: true,
            lastExecutionTime: None,
            lastExecutionStatus: None,
            totalExecutions: 0,
            successfulExecutions: 0,
            failedExecutions: 0,
        }
    }

    #[test]
    fn executes_linear_chain_with_extract() {
        // trigger -> extract(REGEX on trigger payload)
        let mut ex = extract("e1", ExtractMode::REGEX, ParameterValue::NodeReference {
            nodeId: "t1".to_string(),
        });
        if let WorkflowNode::Extract(node) = &mut ex {
            node.expression = r"(\d+)".to_string();
            node.group = 1;
        }
        let nodes = vec![trigger("t1", "manual"), ex];
        let wf = workflow(nodes, vec![conn("t1", "e1", None)]);
        let mut extras = HashMap::new();
        extras.insert("text".to_string(), "order 42 shipped".to_string());

        let result = WorkflowExecutor::new().execute(&wf, &extras);
        assert!(result.success, "{}", result.message);
        assert_eq!(
            result.node_results.get("e1"),
            Some(&NodeExecutionState::Success("42".to_string()))
        );
    }

    #[test]
    fn condition_gt_compares_numbers() {
        let nodes = vec![
            trigger("t1", "manual"),
            condition(
                "c1",
                ParameterValue::StaticValue { value: "42".to_string() },
                ConditionOperator::GT,
                ParameterValue::StaticValue { value: "10".to_string() },
            ),
        ];
        let wf = workflow(nodes, vec![conn("t1", "c1", None)]);
        let result = WorkflowExecutor::new().execute(&wf, &HashMap::new());
        assert!(result.success, "{}", result.message);
        assert_eq!(
            result.node_results.get("c1"),
            Some(&NodeExecutionState::Success("true".to_string()))
        );
    }

    #[test]
    fn detects_cycle() {
        let nodes = vec![
            trigger("t1", "manual"),
            execute("a", "tool_a", HashMap::new()),
            execute("b", "tool_b", HashMap::new()),
        ];
        let connections = vec![
            conn("t1", "a", None),
            conn("a", "b", None),
            conn("b", "a", None), // cycle a <-> b
        ];
        let wf = workflow(nodes, connections);
        let result = WorkflowExecutor::new().execute(&wf, &HashMap::new());
        assert!(!result.success);
        assert!(result.message.contains("circular"));
    }

    #[test]
    fn logic_and_requires_all_true() {
        let nodes = vec![
            trigger("t1", "manual"),
            condition(
                "c1",
                ParameterValue::NodeReference { nodeId: "t1".to_string() },
                ConditionOperator::CONTAINS,
                ParameterValue::StaticValue { value: "ok".to_string() },
            ),
            condition(
                "c2",
                ParameterValue::NodeReference { nodeId: "t1".to_string() },
                ConditionOperator::CONTAINS,
                ParameterValue::StaticValue { value: "missing".to_string() },
            ),
            logic("l1", LogicOperator::AND),
        ];
        let connections = vec![
            conn("t1", "c1", None),
            conn("t1", "c2", None),
            conn("c1", "l1", None),
            conn("c2", "l1", None),
        ];
        let wf = workflow(nodes, connections);
        let mut extras = HashMap::new();
        extras.insert("text".to_string(), "this is ok".to_string());

        let result = WorkflowExecutor::new().execute(&wf, &extras);
        assert!(result.success);
        // c2 is false -> AND yields false
        assert_eq!(
            result.node_results.get("l1"),
            Some(&NodeExecutionState::Success("false".to_string()))
        );
    }

    #[test]
    fn error_condition_edge_handles_failure() {
        struct FailAction;
        #[async_trait::async_trait]
        impl WorkflowAction for FailAction {
            async fn execute(&self, _action_type: &str, _parameters: &[(String, String)]) -> Result<String, String> {
                Err("boom".to_string())
            }
        }

        let mut nodes = vec![
            trigger("t1", "manual"),
            execute("a", "fail_tool", HashMap::new()),
            extract("recover", ExtractMode::SUB, ParameterValue::StaticValue { value: "fallback".to_string() }),
        ];
        if let WorkflowNode::Extract(node) = &mut nodes[2] {
            node.startIndex = 0;
            node.length = 8;
        }
        let connections = vec![
            conn("t1", "a", None),
            conn("a", "recover", Some("error")), // error edge
        ];
        let wf = workflow(nodes, connections);
        let executor = WorkflowExecutor::with_action(Box::new(FailAction));
        let result = executor.execute(&wf, &HashMap::new());
        // Failure handled by error edge -> success
        assert!(result.success, "{}", result.message);
        assert!(result.node_results.get("a").unwrap().is_failed());
        assert!(result.node_results.get("recover").unwrap().is_success());
    }

    #[test]
    fn json_path_extract() {
        // Unit-test the JSON path helper directly with a real JSON document.
        let doc = r#"{"user":{"name":"Alice","tags":["a","b"]},"items":[10,20]}"#;
        assert_eq!(extract_by_json_path(doc, "user.name", "d"), "\"Alice\"");
        assert_eq!(extract_by_json_path(doc, "user.tags[1]", "d"), "\"b\"");
        assert_eq!(extract_by_json_path(doc, "items[0]", "d"), "10");
        assert_eq!(extract_by_json_path(doc, "missing.key", "d"), "d");
        assert_eq!(extract_by_json_path("not json", "a.b", "d"), "d");
    }

    #[test]
    fn skip_when_condition_edge_not_met() {
        // trigger -> c1(contains "yes") -> e1 ; payload lacks "yes" so c1=false,
        // edge c1->e1 is implicit "true" expectation -> e1 skipped via c1=false?
        // c1 itself still runs and produces "false"; e1's incoming edge has no
        // condition -> requires source Success -> false -> e1 skipped.
        let nodes = vec![
            trigger("t1", "manual"),
            condition(
                "c1",
                ParameterValue::NodeReference { nodeId: "t1".to_string() },
                ConditionOperator::CONTAINS,
                ParameterValue::StaticValue { value: "yes".to_string() },
            ),
            execute("e1", "tool_x", HashMap::new()),
        ];
        let connections = vec![
            conn("t1", "c1", None),
            conn("c1", "e1", None),
        ];
        let wf = workflow(nodes, connections);
        let mut extras = HashMap::new();
        extras.insert("text".to_string(), "no match here".to_string());

        let result = WorkflowExecutor::new().execute(&wf, &extras);
        assert!(result.success);
        assert_eq!(
            result.node_results.get("c1"),
            Some(&NodeExecutionState::Success("false".to_string()))
        );
        // e1 incoming edge from c1: source result "false" not "true" -> skip
        let e1 = result.node_results.get("e1");
        assert!(matches!(e1, Some(NodeExecutionState::Skipped(_))), "e1 should be skipped, got {e1:?}");
    }

    #[test]
    fn in_operator_numeric_list() {
        let ok = compare_values("5", "[1,2,5]", &ConditionOperator::IN).unwrap();
        assert!(ok);
        let nok = compare_values("9", "[1,2,5]", &ConditionOperator::IN).unwrap();
        assert!(!nok);
        let not_in = compare_values("9", "[1,2,5]", &ConditionOperator::NOT_IN).unwrap();
        assert!(not_in);
        // comma-separated fallback
        let comma = compare_values("b", "a, b, c", &ConditionOperator::IN).unwrap();
        assert!(comma);
    }

    #[test]
    fn substring_extract_bounds() {
        assert_eq!(substring_by_index("hello world", 0, 5, "d"), "hello");
        assert_eq!(substring_by_index("hello world", 6, 100, "d"), "world");
        assert_eq!(substring_by_index("hi", 5, 2, "d"), "d");
        assert_eq!(substring_by_index("hi", -1, 2, "d"), "d");
    }
}
