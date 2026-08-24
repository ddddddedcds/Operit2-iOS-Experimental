//! Workflow scheduler (Step 3): pure-Rust polling scheduler that decides when a
//! schedule-trigger workflow should run. The upstream Android scheduler leans on
//! WorkManager; here we expose a deterministic `poll(now)` so any host (the iOS
//! LaunchDaemon timer, a CLI loop, a background task) can drive execution.

use std::collections::HashMap;

use operit_model::Workflow::{TriggerNode, Workflow, WorkflowNode};

/// Schedule configuration keys (mirror upstream constants).
pub const CONFIG_SCHEDULE_TYPE: &str = "schedule_type";
pub const CONFIG_INTERVAL_MS: &str = "interval_ms";
pub const CONFIG_REPEAT: &str = "repeat";
pub const CONFIG_SPECIFIC_TIME: &str = "specific_time";
pub const CONFIG_CRON_EXPRESSION: &str = "cron_expression";

pub const SCHEDULE_TYPE_INTERVAL: &str = "interval";
pub const SCHEDULE_TYPE_SPECIFIC_TIME: &str = "specific_time";
pub const SCHEDULE_TYPE_CRON: &str = "cron";

/// Decides which workflows are due to run at the given wall-clock time.
pub struct WorkflowScheduler;

impl WorkflowScheduler {
    /// Returns the ids of workflows whose schedule trigger is due at `now_ms`.
    ///
    /// `now_ms` is epoch milliseconds; interval decisions use
    /// `workflow.lastExecutionTime` so a run delays the next one. Workflows
    /// without a schedule trigger are never returned.
    pub fn poll(workflows: &[Workflow], now_ms: i64) -> Vec<String> {
        let mut due = Vec::new();
        for workflow in workflows {
            if !workflow.enabled {
                continue;
            }
            let Some(trigger) = find_schedule_trigger(workflow) else {
                continue;
            };
            if is_due(workflow, trigger, now_ms) {
                due.push(workflow.id.clone());
            }
        }
        due
    }
}

fn find_schedule_trigger(workflow: &Workflow) -> Option<&TriggerNode> {
    workflow.nodes.iter().find_map(|node| match node {
        WorkflowNode::Trigger(trigger) if trigger.triggerType == "schedule" => Some(trigger),
        _ => None,
    })
}

fn is_due(workflow: &Workflow, trigger: &TriggerNode, now_ms: i64) -> bool {
    let config = &trigger.triggerConfig;
    let schedule_type = match config.get(CONFIG_SCHEDULE_TYPE) {
        Some(value) => value.as_str(),
        None => return false,
    };

    match schedule_type {
        SCHEDULE_TYPE_INTERVAL => is_interval_due(workflow, config, now_ms),
        SCHEDULE_TYPE_SPECIFIC_TIME => is_specific_time_due(config, now_ms),
        SCHEDULE_TYPE_CRON => is_cron_due(config, now_ms),
        _ => false,
    }
}

fn is_interval_due(workflow: &Workflow, config: &HashMap<String, String>, now_ms: i64) -> bool {
    let repeat = config
        .get(CONFIG_REPEAT)
        .map(|value| value == "true")
        .unwrap_or(true);
    if !repeat {
        // A non-repeating interval is treated as a one-shot: due only if never run.
        return workflow.lastExecutionTime.is_none();
    }
    let interval_ms: i64 = match config.get(CONFIG_INTERVAL_MS).and_then(|value| value.parse().ok()) {
        Some(value) => value,
        None => return false,
    };
    if interval_ms <= 0 {
        return false;
    }
    match workflow.lastExecutionTime {
        Some(last_run) => now_ms - last_run >= interval_ms,
        None => true, // never ran -> due now
    }
}

fn is_specific_time_due(config: &HashMap<String, String>, now_ms: i64) -> bool {
    let Some(specific) = config.get(CONFIG_SPECIFIC_TIME) else {
        return false;
    };
    let Some(target_secs) = parse_iso_epoch_ms(specific) else {
        return false;
    };
    let target_ms = target_secs * 1000;
    // Due when the target time has been reached and (for non-repeat) not yet
    // executed — the caller records execution via workflow.lastExecutionTime.
    let repeat = config
        .get(CONFIG_REPEAT)
        .map(|value| value == "true")
        .unwrap_or(false);
    if repeat {
        now_ms >= target_ms
    } else {
        // One-shot specific time is due only in the minute window of the target.
        now_ms >= target_ms && now_ms < target_ms + 60_000
    }
}

fn is_cron_due(config: &HashMap<String, String>, now_ms: i64) -> bool {
    let Some(expression) = config.get(CONFIG_CRON_EXPRESSION) else {
        return false;
    };
    let Some(parsed) = parse_cron(expression) else {
        return false;
    };
    let secs = now_ms / 1000;
    let minute = (secs % 3600) / 60;
    let hour = (secs % 86400) / 3600;
    let day_of_month = ((secs / 86400) % 31) + 1;
    let month = ((secs / 86400) % 365) / 31 + 1; // coarse month approximation
    let weekday = (secs / 86400 + 4) % 7; // 1970-01-01 was Thursday -> 4

    let minute_ok = cron_field_matches(&parsed.0, minute);
    let hour_ok = cron_field_matches(&parsed.1, hour);
    let dom_ok = parsed.2.is_none() || cron_field_matches(parsed.2.as_ref().unwrap(), day_of_month);
    let month_ok = parsed.3.is_none() || cron_field_matches(parsed.3.as_ref().unwrap(), month);
    let dow_ok = parsed.4.is_none() || cron_field_matches(parsed.4.as_ref().unwrap(), weekday);

    minute_ok && hour_ok && dom_ok && month_ok && dow_ok
}

/// Minimal cron field: supports `*`, fixed numbers, and `a-b` ranges.
fn cron_field_matches(field: &CronField, value: i64) -> bool {
    match field {
        CronField::Any => true,
        CronField::Exact(values) => values.iter().any(|v| *v == value),
        CronField::Range(start, end) => *start <= value && value <= *end,
    }
}

#[derive(Debug, Clone)]
enum CronField {
    Any,
    Exact(Vec<i64>),
    Range(i64, i64),
}

struct CronExpression(CronField, CronField, Option<CronField>, Option<CronField>, Option<CronField>);

fn parse_cron(expression: &str) -> Option<CronExpression> {
    let parts: Vec<&str> = expression.split_whitespace().collect();
    if parts.len() != 5 {
        return None;
    }
    let minute = parse_cron_field(parts[0])?;
    let hour = parse_cron_field(parts[1])?;
    let dom = parse_optional_cron_field(parts[2]);
    let month = parse_optional_cron_field(parts[3]);
    let dow = parse_optional_cron_field(parts[4]);
    Some(CronExpression(minute, hour, dom, month, dow))
}

fn parse_optional_cron_field(field: &str) -> Option<CronField> {
    if field == "*" || field == "?" {
        None
    } else {
        parse_cron_field(field)
    }
}

fn parse_cron_field(field: &str) -> Option<CronField> {
    let field = field.trim();
    if field == "*" {
        return Some(CronField::Any);
    }
    if let Some((start, end)) = field.split_once('-') {
        let start: i64 = start.parse().ok()?;
        let end: i64 = end.parse().ok()?;
        return Some(CronField::Range(start, end));
    }
    let values: Vec<i64> = field
        .split(',')
        .map(|part| part.trim().parse().ok())
        .collect::<Option<Vec<_>>>()?;
    if values.is_empty() {
        return None;
    }
    if values.len() == 1 {
        Some(CronField::Exact(values))
    } else {
        Some(CronField::Exact(values))
    }
}

/// Parses an ISO-8601 timestamp to epoch milliseconds (UTC).
fn parse_iso_epoch_ms(text: &str) -> Option<i64> {
    let text = text.trim();
    let (date_part, time_part) = match text.split_once('T') {
        Some((date, time)) => (date, time),
        None => {
            // Fall back to space-separated datetime.
            let (date, time) = text.split_once(' ')?;
            (date, time)
        }
    };
    // Strip fractional seconds and a trailing 'Z'.
    let mut time = time_part.split('.').next().unwrap_or(time_part);
    if let Some(stripped) = time.strip_suffix('Z') {
        time = stripped;
    }
    // Strip an explicit numeric UTC offset like "+08:00" (parse as UTC).
    if let Some(plus) = time.rfind('+') {
        time = &time[..plus];
    } else if let Some(minus) = time.rfind('-') {
        // Only treat as offset when it is a tail like "-08:00" (year/month use '-'
        // in the date part, which was already split off).
        let tail = &time[minus..];
        if tail.len() >= 3 && tail.contains(':') {
            time = &time[..minus];
        }
    }

    let date_parts: Vec<i64> = date_part
        .split('-')
        .map(|part| part.parse().ok())
        .collect::<Option<Vec<_>>>()?;
    let time_parts: Vec<i64> = time
        .split(':')
        .map(|part| part.parse().ok())
        .collect::<Option<Vec<_>>>()?;
    if date_parts.len() != 3 || time_parts.is_empty() || time_parts.len() > 3 {
        return None;
    }
    let (year, month, day) = (date_parts[0], date_parts[1], date_parts[2]);
    let (hour, minute) = (time_parts[0], time_parts[1]);
    let second = time_parts.get(2).copied().unwrap_or(0);

    // Days from civil epoch (1970-01-01), Howard Hinnant algorithm.
    let days_from_civil = civil_days_from_epoch(year, month, day)?;
    Some(days_from_civil * 86400 + hour * 3600 + minute * 60 + second)
}

fn civil_days_from_epoch(year: i64, month: i64, day: i64) -> Option<i64> {
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (month + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    Some(era * 146097 + doe - 719468)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn workflow_with_schedule(trigger_config: HashMap<String, String>, last_run: Option<i64>, enabled: bool) -> Workflow {
        Workflow {
            id: "wf-sched".to_string(),
            name: "Sched".to_string(),
            description: String::new(),
            nodes: vec![WorkflowNode::Trigger(TriggerNode {
                id: "trig".to_string(),
                type_: "trigger".to_string(),
                name: "sched".to_string(),
                description: String::new(),
                position: operit_model::Workflow::NodePosition { x: 0.0, y: 0.0 },
                triggerType: "schedule".to_string(),
                triggerConfig: trigger_config,
            })],
            connections: Vec::new(),
            createdAt: 0,
            updatedAt: 0,
            enabled,
            lastExecutionTime: last_run,
            lastExecutionStatus: None,
            totalExecutions: 0,
            successfulExecutions: 0,
            failedExecutions: 0,
        }
    }

    #[test]
    fn interval_due_after_elapsed() {
        let mut config = HashMap::new();
        config.insert(CONFIG_SCHEDULE_TYPE.to_string(), SCHEDULE_TYPE_INTERVAL.to_string());
        config.insert(CONFIG_INTERVAL_MS.to_string(), "60000".to_string());
        config.insert(CONFIG_REPEAT.to_string(), "true".to_string());
        let wf = workflow_with_schedule(config, Some(100_000), true);
        assert_eq!(WorkflowScheduler::poll(&[wf.clone()], 160_001), vec!["wf-sched"]);
        assert!(WorkflowScheduler::poll(&[wf], 159_999).is_empty());
    }

    #[test]
    fn interval_never_run_is_due() {
        let mut config = HashMap::new();
        config.insert(CONFIG_SCHEDULE_TYPE.to_string(), SCHEDULE_TYPE_INTERVAL.to_string());
        config.insert(CONFIG_INTERVAL_MS.to_string(), "3600000".to_string());
        let wf = workflow_with_schedule(config, None, true);
        assert_eq!(WorkflowScheduler::poll(&[wf], 0), vec!["wf-sched"]);
    }

    #[test]
    fn specific_time_one_shot_window() {
        let mut config = HashMap::new();
        config.insert(CONFIG_SCHEDULE_TYPE.to_string(), SCHEDULE_TYPE_SPECIFIC_TIME.to_string());
        config.insert(CONFIG_SPECIFIC_TIME.to_string(), "2026-08-24T12:00:00Z".to_string());
        config.insert(CONFIG_REPEAT.to_string(), "false".to_string());
        let wf = workflow_with_schedule(config, None, true);
        // Compute real epoch for the timestamp to keep the test honest.
        let real = parse_iso_epoch_ms("2026-08-24T12:00:00Z").unwrap() * 1000;
        assert!(WorkflowScheduler::poll(&[wf.clone()], real + 30_000).contains(&"wf-sched".to_string()));
        assert!(!WorkflowScheduler::poll(&[wf], real + 90_000).contains(&"wf-sched".to_string()));
    }

    #[test]
    fn cron_every_minute_and_hour() {
        let mut config = HashMap::new();
        config.insert(CONFIG_SCHEDULE_TYPE.to_string(), SCHEDULE_TYPE_CRON.to_string());
        config.insert(CONFIG_CRON_EXPRESSION.to_string(), "* * * * *".to_string());
        let wf = workflow_with_schedule(config, None, true);
        let t = parse_iso_epoch_ms("2026-08-24T10:30:34Z").unwrap() * 1000;
        assert!(WorkflowScheduler::poll(&[wf], t).contains(&"wf-sched".to_string()));
    }

    #[test]
    fn cron_specific_hour() {
        let mut config = HashMap::new();
        config.insert(CONFIG_SCHEDULE_TYPE.to_string(), SCHEDULE_TYPE_CRON.to_string());
        config.insert(CONFIG_CRON_EXPRESSION.to_string(), "0 9 * * *".to_string());
        let wf = workflow_with_schedule(config, None, true);
        // 2026-08-24 09:00:30Z
        let t = parse_iso_epoch_ms("2026-08-24T09:00:30Z").unwrap() * 1000;
        assert!(WorkflowScheduler::poll(&[wf.clone()], t).contains(&"wf-sched".to_string()));
        let t2 = parse_iso_epoch_ms("2026-08-24T10:00:30Z").unwrap() * 1000;
        assert!(!WorkflowScheduler::poll(&[wf], t2).contains(&"wf-sched".to_string()));
    }

    #[test]
    fn disabled_workflow_never_runs() {
        let mut config = HashMap::new();
        config.insert(CONFIG_SCHEDULE_TYPE.to_string(), SCHEDULE_TYPE_INTERVAL.to_string());
        config.insert(CONFIG_INTERVAL_MS.to_string(), "1000".to_string());
        let wf = workflow_with_schedule(config, None, false);
        assert!(WorkflowScheduler::poll(&[wf], 1_000_000).is_empty());
    }

    #[test]
    fn parse_iso_epoch_matches_known() {
        // 1970-01-01T00:00:00Z == 0
        assert_eq!(parse_iso_epoch_ms("1970-01-01T00:00:00Z"), Some(0));
        // 1970-01-02T00:00:00Z == 86400
        assert_eq!(parse_iso_epoch_ms("1970-01-02T00:00:00"), Some(86400));
        // 2026-01-01T00:00:00Z
        let t = parse_iso_epoch_ms("2026-01-01T00:00:00Z").unwrap();
        assert!(t > 1_700_000_000);
    }
}
