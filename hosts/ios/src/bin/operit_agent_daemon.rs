// operit_agent_daemon.rs
//
// 常驻设备控制 daemon（B1 slot-in）：在 operit-ios 的 deb 里顶替 operit-agent.m，
// 1:1 复用其控制协议（agent.sock / config.plist / screen.png / agent.log），
// 调用 hosts/ios 的 run_device_agent_loop（#98a）跑"截图→autoglm→do()/finish()→设备动作"循环。
//
// 关键：循环跑在本进程（LaunchDaemon，mobile 用户，RunAtLoad；KeepAlive 已移除，
// 避免 daemon 被 AMFI -9 后在设备上形成重启循环），不依赖 Operit.app 前台 Task，
// 规避 iOS 退后台挂起（P0 死结）。
#![cfg(target_os = "ios")]

use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LazyLock, Mutex};
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

use operit_host_ios_native::device_agent::{run_device_agent_loop, DeviceAgentConfig};
use operit_host_ios_native::device_automation::IosDeviceAutomationHost;

// All on-device paths are resolved at runtime from the active jailbreak root
// (see `operit_ios_env`): the data root is the real /var/mobile/.operit.
const AUTOGLM_ENDPOINT: &str = "https://open.bigmodel.cn/api/paas/v4/chat/completions";
const DAEMON_VERSION: &str = "0.3.9";

struct State {
    running: bool,
    goal: String,
}
static STATE: Mutex<State> = Mutex::new(State {
    running: false,
    goal: String::new(),
});
static STOP: LazyLock<Mutex<Arc<AtomicBool>>> =
    LazyLock::new(|| Mutex::new(Arc::new(AtomicBool::new(false))));

/// Cached daemon config pushed by the app over the TCP control channel.
///
/// The app pushes its LLM credentials over loopback TCP; `resolve_config`
/// prefers this cache and falls back to the on-disk plist.
struct CachedConfig {
    api_key: String,
    provider: String,
    base_url: String,
    model: String,
}
static CACHED_CONFIG: LazyLock<Mutex<Option<CachedConfig>>> =
    LazyLock::new(|| Mutex::new(None));

/// In-memory cache of daemon-scheduled workflows (id -> workflow). Updated on
/// schedule/list/remove; the scheduler loop walks this instead of re-reading
/// every JSON file each tick.
static SCHEDULED_WORKFLOWS: LazyLock<Mutex<HashMap<String, operit_model::Workflow::Workflow>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

fn now_hms() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let s = secs % 86400;
    let h = s / 3600;
    let m = (s % 3600) / 60;
    let sec = s % 60;
    format!("{:02}:{:02}:{:02}", h, m, sec)
}

fn log_line(msg: &str) {
    let _ = fs::create_dir_all(operit_ios_env::data_root().join("logs"));
    if let Ok(mut f) = OpenOptions::new()
        .create(true)
        .append(true)
        .open(operit_ios_env::data_root().join("logs/agent.log"))
    {
        let _ = writeln!(f, "[{}] {}", now_hms(), msg);
    }
}

fn write_screen(png: &[u8]) {
    let _ = fs::write(operit_ios_env::data_root().join("screen.png"), png);
}

fn set_running(v: bool) {
    STATE.lock().unwrap().running = v;
}

/// Build a `DeviceAgentConfig` from the four credential fields, mirroring the
/// Obj-C operit-agent.m chatCompletion logic.
fn build_config(api_key: &str, provider: &str, base_url: &str, model: &str) -> Option<DeviceAgentConfig> {
    if api_key.is_empty() {
        return None;
    }
    let (endpoint, model) = if provider == "custom" {
        let b = base_url.trim_end_matches('/');
        let ep = if b.is_empty() {
            AUTOGLM_ENDPOINT.to_string()
        } else {
            format!("{}/chat/completions", b)
        };
        (ep, model.to_string())
    } else {
        (
            AUTOGLM_ENDPOINT.to_string(),
            if model.is_empty() {
                "autoglm-phone".to_string()
            } else {
                model.to_string()
            },
        )
    };
    Some(DeviceAgentConfig {
        api_key: api_key.to_string(),
        api_base: endpoint,
        model,
    })
}

/// Read the app-written shared config.plist (XML).
/// in a different physical dir than the one the app wrote, so it may be
/// missing/empty; `resolve_config` covers that case via the TCP-pushed cache.
fn load_config() -> Option<DeviceAgentConfig> {
    let file = File::open(operit_ios_env::data_root().join("config.plist")).ok()?;
    let val: plist::Value = plist::from_reader(file).ok()?;
    let dict = val.into_dictionary()?;
    let get = |k: &str| -> String {
        dict.get(k)
            .and_then(|v| v.as_string())
            .unwrap_or("")
            .to_string()
    };
    let api_key = get("apiKey");
    let provider = get("apiProvider");
    let base_url = get("apiBaseUrl");
    let model = get("apiModel");
    build_config(&api_key, &provider, &base_url, &model)
}

/// Resolve the daemon config: prefer the app-pushed TCP cache,
/// fall back to the on-disk config.plist (rootless / non-jb).
fn resolve_config() -> Option<DeviceAgentConfig> {
    if let Some(c) = CACHED_CONFIG.lock().unwrap().as_ref() {
        return build_config(&c.api_key, &c.provider, &c.base_url, &c.model);
    }
    load_config()
}

fn run_task(goal: String, stop: Arc<AtomicBool>) {
    let _ = fs::remove_file(operit_ios_env::data_root().join("logs/agent.log"));
    log_line(&format!("任务开始: {}", goal));

    let cfg = match resolve_config() {
        Some(c) => c,
        None => {
            log_line("错误：未填 API Key（请在 Operit App 设置中填写）");
            set_running(false);
            return;
        }
    };

    let host = Arc::new(IosDeviceAutomationHost::new());
    let log_fn = |m: &str| log_line(m);
    let shot_fn = |p: &[u8]| write_screen(p);
    let result = run_device_agent_loop(&goal, host, &cfg, stop, &log_fn, &shot_fn);
    log_line(&format!("任务结束: {}", result));
    set_running(false);
}

fn dispatch(line: &str) -> String {
    match line {
        "ping" => {
            // 用字节串字面量 b"OK|pong"（原始字节存 .rodata，不受 release 下
            // LLVM 字符串合并消除 "pong" 字面量的怪象影响），App 以此探测 daemon 在线。
            std::str::from_utf8(b"OK|pong").unwrap().to_string()
        }
        "status" => {
            let st = STATE.lock().unwrap();
            format!(
                "OK|{}|{}",
                if st.running { "running" } else { "idle" },
                st.goal
            )
        }
        "start" => {
            let running = STATE.lock().unwrap().running;
            if running {
                return "OK|already running".to_string();
            }
            let flag = Arc::new(AtomicBool::new(false));
            *STOP.lock().unwrap() = flag.clone();
            let goal = STATE.lock().unwrap().goal.clone();
            STATE.lock().unwrap().running = true;
            thread::spawn(move || run_task(goal, flag));
            "OK|started".to_string()
        }
        "stop" => {
            STOP.lock().unwrap().store(true, Ordering::Relaxed);
            "OK|stopping".to_string()
        }
        _ if line.starts_with("goal ") => {
            let g = line[5..].to_string();
            STATE.lock().unwrap().goal = g;
            "OK|goal set".to_string()
        }
        "goal" => {
            STATE.lock().unwrap().goal = String::new();
            "OK|goal set".to_string()
        }
        _ if line.starts_with("config ") => {
            // App pushes LLM credentials over TCP. Payload:
            // "config <apiKey>|<apiProvider>|<apiBaseUrl>|<apiModel>".
            let rest = &line[7..];
            let parts: Vec<&str> = rest.split('|').collect();
            if parts.len() == 4 {
                *CACHED_CONFIG.lock().unwrap() = Some(CachedConfig {
                    api_key: parts[0].to_string(),
                    provider: parts[1].to_string(),
                    base_url: parts[2].to_string(),
                    model: parts[3].to_string(),
                });
                "OK|config set".to_string()
            } else {
                "ERR|bad config payload".to_string()
            }
        }
        _ if line.starts_with("workflow.schedule ") => {
            // App registers a workflow for daemon-side scheduling:
            // "workflow.schedule <workflow-json>".
            match workflow_schedule(&line[18..]) {
                Ok(id) => format!("OK|scheduled {id}"),
                Err(e) => format!("ERR|{e}"),
            }
        }
        "workflow.list" => match workflow_list() {
            Ok(ids) => {
                if ids.is_empty() {
                    "OK|(none)".to_string()
                } else {
                    format!("OK|{}", ids.join(","))
                }
            }
            Err(e) => format!("ERR|{e}"),
        },
        _ if line.starts_with("workflow.remove ") => {
            let id = line[16..].trim();
            match workflow_remove(id) {
                Ok(()) => "OK|removed".to_string(),
                Err(e) => format!("ERR|{e}"),
            }
        }
        _ if line.starts_with("tool.trustCacheAdd ") => {
            // "tool.trustCacheAdd <path>" — add an arbitrary binary's cdhash to
            // the jailbreak trustcache via jbctl (Dopamine), so freshly
            // re-signed binaries are trusted by AMFI without a reboot.
            match jbctl_trustcache_add(line[19..].trim()) {
                Ok(()) => "OK|trustcache add issued".to_string(),
                Err(e) => format!("ERR|{e}"),
            }
        }
        _ if line.starts_with("tool.procSetDebugged ") => {
            // "tool.procSetDebugged <pid>" — mark a process as debugged
            // (Dopamine jbctl), allowing invalid code pages inside it.
            let pid = line[20..].trim();
            match jbctl_proc_set_debugged(pid) {
                Ok(()) => format!("OK|proc {pid} set debugged"),
                Err(e) => format!("ERR|{e}"),
            }
        }
        _ if line.starts_with("dbg.root") => {
            // Debug: print the resolved data/binary roots + jailbreak type.
            format!(
                "OK|data={} bin={:?} jb={:?}",
                operit_ios_env::data_root().display(),
                operit_ios_env::binary_root(),
                operit_ios_env::detect_jailbreak()
            )
        }
        _ if line.starts_with("dbg.openSqlite ") => {
            // Debug: attempt to open an SQLite db at the given path through the
            // same host stack the app uses (IosRuntimeStorageHost), to isolate
            // whether EACCES is path/permission-based or app-process-specific.
            let p = line[15..].trim();
            match dbg_open_sqlite(p) {
                Ok(msg) => format!("OK|{msg}"),
                Err(e) => format!("ERR|{e}"),
            }
        }
        _ => "ERR|unknown".to_string(),
    }
}

/// Debug helper mirroring `AppleRuntimeStorageHost::openSqliteDatabase`.
fn dbg_open_sqlite(path: &str) -> Result<String, String> {
    use operit_host_api::RuntimeSqliteHost;
    let host = operit_host_apple_native::AppleRuntimeStorageHost::new(
        operit_ios_env::data_root().join("runtime"),
        operit_ios_env::data_root().join("workspaces"),
    );
    let _conn = host
        .openSqliteDatabase(path)
        .map_err(|e| format!("open failed: {e}"))?;
    Ok(format!("opened: {path}"))
}

/// Runs `jbctl trustcache add <cdhash>` for the binary at `path` by computing
/// its cdhash first (CDHash = the `CodeDirectory` hash, i.e. cdhash of the
/// Mach-O). Simplest robust approach: use `ldid -H <path>` output when
/// available, else derive via `codesign -dr` on macOS — but on-device we rely
/// on `ldid` (always present in Procursus). Falls back to returning the raw
/// jbctl output on failure so callers see what happened.
fn jbctl_trustcache_add(path: &str) -> Result<(), String> {
    // Compute cdhash with ldid (Procursus ships it; same tool postinst uses).
    let ldid_out = std::process::Command::new("/var/jb/usr/bin/ldid")
        .arg("-H")
        .arg(path)
        .output();
    let cdhash = match ldid_out {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout)
            .lines()
            .find_map(|l| {
                let l = l.trim();
                if l.len() >= 40 && l.bytes().all(|b| b.is_ascii_hexdigit()) {
                    Some(l.to_string())
                } else {
                    None
                }
            })
            .ok_or_else(|| "ldid -H produced no cdhash".to_string())?,
        Ok(out) => {
            return Err(format!(
                "ldid -H failed: {}",
                String::from_utf8_lossy(&out.stderr)
            ))
        }
        Err(e) => return Err(format!("ldid missing: {e}")),
    };
    let status = std::process::Command::new("/var/jb/usr/bin/jbctl")
        .args(["trustcache", "add", &cdhash])
        .status()
        .map_err(|e| format!("jbctl missing: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("jbctl trustcache add exit {:?}", status.code()))
    }
}

/// Runs `jbctl proc_set_debugged <pid>` (Dopamine).
fn jbctl_proc_set_debugged(pid: &str) -> Result<(), String> {
    let status = std::process::Command::new("/var/jb/usr/bin/jbctl")
        .args(["proc_set_debugged", pid])
        .status()
        .map_err(|e| format!("jbctl missing: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("jbctl proc_set_debugged exit {:?}", status.code()))
    }
}

// ---------- daemon-side workflow scheduling ----------

/// Directory where scheduled workflows are persisted (shared with the app).
fn workflows_dir() -> std::path::PathBuf {
    operit_ios_env::data_root().join("workflows")
}

/// Registers a workflow JSON for daemon-side scheduling.
fn workflow_schedule(workflow_json: &str) -> Result<String, String> {
    let workflow: operit_model::Workflow::Workflow = serde_json::from_str(workflow_json)
        .map_err(|e| format!("bad workflow json: {e}"))?;
    let dir = workflows_dir();
    std::fs::create_dir_all(&dir).map_err(|e| format!("mkdir: {e}"))?;
    let path = dir.join(format!("{}.json", sanitize_id(&workflow.id)));
    std::fs::write(&path, workflow_json).map_err(|e| format!("write: {e}"))?;
    let workflow_id = workflow.id.clone();
    SCHEDULED_WORKFLOWS
        .lock()
        .unwrap()
        .insert(workflow_id.clone(), workflow);
    Ok(workflow_id)
}

fn workflow_list() -> Result<Vec<String>, String> {
    // Prefer the in-memory cache; fall back to a directory scan for a fresh
    // daemon start where the cache has not been hydrated yet.
    let cached = SCHEDULED_WORKFLOWS.lock().unwrap();
    if !cached.is_empty() {
        let mut ids: Vec<String> = cached.keys().cloned().collect();
        ids.sort();
        return Ok(ids);
    }
    drop(cached);
    let dir = workflows_dir();
    if !dir.exists() {
        return Ok(Vec::new());
    }
    let mut ids = Vec::new();
    for entry in std::fs::read_dir(&dir).map_err(|e| e.to_string())? {
        let entry = entry.map_err(|e| e.to_string())?;
        let name = entry.file_name().to_string_lossy().to_string();
        if let Some(stripped) = name.strip_suffix(".json") {
            ids.push(stripped.to_string());
        }
    }
    ids.sort();
    Ok(ids)
}

fn workflow_remove(id: &str) -> Result<(), String> {
    let path = workflows_dir().join(format!("{}.json", sanitize_id(id)));
    if path.exists() {
        std::fs::remove_file(&path).map_err(|e| e.to_string())?;
    }
    SCHEDULED_WORKFLOWS.lock().unwrap().remove(id);
    Ok(())
}

fn sanitize_id(id: &str) -> String {
    id.chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_' || *c == '.')
        .collect()
}

/// Reads a boolean from the mobile-user preferences plist
/// (`~/Library/Preferences/com.ai.assistance.operit.plist`), which the iOS
/// Settings page (PreferenceLoader → operit2.plist) writes. Falls back to
/// `default_value` when the plist/key is missing or unreadable.
fn daemon_pref_bool(key: &str, default_value: bool) -> bool {
    let home = std::env::var_os("HOME").unwrap_or_default();
    let path = std::path::Path::new(&home)
        .join("Library")
        .join("Preferences")
        .join("com.ai.assistance.operit.plist");
    match plist::Value::from_file(&path) {
        Ok(plist::Value::Dictionary(map)) => match map.get(key) {
            Some(plist::Value::Boolean(v)) => *v,
            _ => default_value,
        },
        _ => default_value,
    }
}

/// Scheduler loop: every 10s walk the in-memory scheduled-workflow cache, run
/// due ones (pure logic only; ExecuteNode without an action is reported as
/// needing the app), and update `lastExecutionTime` so intervals advance.
/// Hydrates the cache once from disk on the first tick (a daemon restart must
/// pick up previously scheduled workflows without re-reading files every tick).
fn workflow_scheduler_loop() {
    thread::spawn(|| loop {
        let now_ms = operit_host_api::TimeUtils::currentTimeMillis();
        {
            let mut cache = SCHEDULED_WORKFLOWS.lock().unwrap();
            if cache.is_empty() {
                // First tick (or all removed): hydrate from disk.
                let dir = workflows_dir();
                if let Ok(entries) = std::fs::read_dir(&dir) {
                    for entry in entries.flatten() {
                        let path = entry.path();
                        if path.extension().map(|e| e == "json").unwrap_or(false) {
                            if let Ok(text) = std::fs::read_to_string(&path) {
                                if let Ok(wf) = serde_json::from_str::<operit_model::Workflow::Workflow>(&text) {
                                    cache.insert(wf.id.clone(), wf);
                                }
                            }
                        }
                    }
                }
            }
        }
        let workflows: Vec<operit_model::Workflow::Workflow> =
            SCHEDULED_WORKFLOWS.lock().unwrap().values().cloned().collect();
        if !workflows.is_empty() {
            let due = operit_workflow_core::WorkflowScheduler::WorkflowScheduler::poll(&workflows, now_ms);
            for id in due {
                let Some(workflow) = workflows.iter().find(|w| w.id == id) else {
                    continue;
                };
                log_line(&format!("workflow due: {} ({}), executing", workflow.id, workflow.name));
                let executor = operit_workflow_core::WorkflowExecutor::WorkflowExecutor::new();
                let result = executor.execute(workflow, &std::collections::HashMap::new());
                log_line(&format!(
                    "workflow {} done success={} msg={}",
                    workflow.id,
                    result.success,
                    result.message
                ));
                // Persist lastExecutionTime so the interval advances.
                let mut updated = workflow.clone();
                updated.lastExecutionTime = Some(now_ms);
                updated.lastExecutionStatus = Some(if result.success {
                    operit_model::Workflow::ExecutionStatus::SUCCESS
                } else {
                    operit_model::Workflow::ExecutionStatus::FAILED
                });
                let path = workflows_dir().join(format!("{}.json", sanitize_id(&workflow.id)));
                if let Ok(text) = serde_json::to_string(&updated) {
                    let _ = std::fs::write(&path, text);
                }
                // Keep the cache in sync with the persisted lastExecutionTime.
                SCHEDULED_WORKFLOWS
                    .lock()
                    .unwrap()
                    .insert(workflow.id.clone(), updated);
            }
        }
        std::thread::sleep(std::time::Duration::from_secs(10));
    });
}

fn handle_client(mut stream: UnixStream) {
    let mut buf = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        match stream.read(&mut byte) {
            Ok(0) => break,
            Ok(_) => {
                if byte[0] == b'\n' {
                    break;
                }
                buf.push(byte[0]);
                if buf.len() > (1 << 16) {
                    break;
                }
            }
            Err(_) => break,
        }
    }
    let line = String::from_utf8_lossy(&buf).trim().to_string();
    let resp = dispatch(&line);
    log_line(&format!("cmd={} -> {}", line, resp));
    let _ = stream.write_all(resp.as_bytes());
}

const AGENT_SOCK_NAME: &str = "agent.sock";

fn main() {
    let _ = fs::create_dir_all(operit_ios_env::data_root().join("logs"));
    let sock_path = operit_ios_env::data_root().join(AGENT_SOCK_NAME);
    log_line(&format!(
        "operit-agent daemon v{} 启动, unix://{}",
        DAEMON_VERSION, sock_path.display()
    ));
    // Daemon-side workflow scheduler (survives app termination). Honours the
    // iOS Settings toggle "后台调度" (PreferenceLoader → defaults key
    // workflowDaemonScheduling under com.ai.assistance.operit).
    if daemon_pref_bool("workflowDaemonScheduling", true) {
        log_line("workflow scheduling enabled (prefs), starting scheduler");
        workflow_scheduler_loop();
    } else {
        log_line("workflow scheduling disabled by prefs");
    }
    let listener = bind_agent_sock();
    for conn in listener.incoming() {
        if let Ok(stream) = conn {
            thread::spawn(move || handle_client(stream));
        }
    }
}

/// Bind the agent control socket as a Unix domain socket under the daemon's
/// data root (`agent.sock`). A Unix socket is used instead of loopback TCP so
/// the control plane is NOT reachable by every local process: the socket file
/// is created 0600 mobile:mobile, and sandboxed apps cannot path-traverse into
/// /var/mobile/.operit to open it. Only the (no-sandbox) Operit app and this
/// daemon — both running as mobile — can connect.
///
/// A stale socket file from a previous crash (no listener attached) would make
/// bind() fail, so we unlink it first. If binding still fails we exit 1 (with
/// KeepAlive removed from the plist, launchd will NOT respawn us in a loop).
fn bind_agent_sock() -> UnixListener {
    use std::os::unix::fs::PermissionsExt;
    let path = operit_ios_env::data_root().join(AGENT_SOCK_NAME);
    let _ = fs::create_dir_all(operit_ios_env::data_root());
    // Drop a leftover socket from a prior run; ignore "not found".
    let _ = fs::remove_file(&path);
    match UnixListener::bind(&path) {
        Ok(l) => {
            // Restrict to the mobile user only.
            let _ = fs::set_permissions(&path, fs::Permissions::from_mode(0o600));
            l
        }
        Err(e) => {
            log_line(&format!("agent 控制 socket 绑定失败: {:?} err={}", path, e));
            std::process::exit(1);
        }
    }
}
