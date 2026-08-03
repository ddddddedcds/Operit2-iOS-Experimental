// operit_agent_daemon.rs
//
// 常驻设备控制 daemon（B1 slot-in）：在 operit-ios 的 deb 里顶替 operit-agent.m，
// 1:1 复用其控制协议（agent.sock / config.plist / screen.png / agent.log），
// 调用 hosts/ios 的 run_device_agent_loop（#98a）跑"截图→autoglm→do()/finish()→设备动作"循环。
//
// 关键：循环跑在本进程（LaunchDaemon，mobile 用户，RunAtLoad+KeepAlive），
// 不依赖 Operit.app 前台 Task，规避 iOS 退后台挂起（P0 死结）。
#![cfg(target_os = "ios")]

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream, IpAddr, Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LazyLock, Mutex};
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

use operit_host_ios_native::device_agent::{run_device_agent_loop, DeviceAgentConfig};
use operit_host_ios_native::device_automation::IosDeviceAutomationHost;

// All on-device paths are resolved at runtime from the active jailbreak root
// (see `operit_ios_env`): on rootless the data root is /var/jb/var/mobile/.operit,
// on roothide it is /var/mobile/.operit (real, writable data path).
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
/// On roothide the app and daemon resolve `data_root()` to DIFFERENT physical
/// directories (per-process /var remap), so a config.plist file written by the
/// app is invisible to the daemon. The only cross-view channel is loopback TCP,
/// hence the app pushes its LLM credentials here; `resolve_config` prefers this
/// cache and falls back to the on-disk plist (which still works on rootless).
struct CachedConfig {
    api_key: String,
    provider: String,
    base_url: String,
    model: String,
}
static CACHED_CONFIG: LazyLock<Mutex<Option<CachedConfig>>> =
    LazyLock::new(|| Mutex::new(None));

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

/// Read the app-written shared config.plist (XML). On roothide this file lives
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

/// Resolve the daemon config: prefer the app-pushed TCP cache (roothide-safe),
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
            // App pushes LLM credentials over TCP (roothide-safe). Payload:
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
        _ => "ERR|unknown".to_string(),
    }
}

fn handle_client(mut stream: TcpStream) {
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

const AGENT_PORT: u16 = 8890;

fn main() {
    let _ = fs::create_dir_all(operit_ios_env::data_root().join("logs"));
    log_line(&format!(
        "operit-agent daemon v{} 启动, tcp=127.0.0.1:{}",
        DAEMON_VERSION, AGENT_PORT
    ));
    let listener = bind_agent_sock();
    for conn in listener.incoming() {
        if let Ok(stream) = conn {
            thread::spawn(move || handle_client(stream));
        }
    }
}

/// Bind the agent control socket over loopback TCP (127.0.0.1:8890).
///
/// Liveness-first takeover: if a healthy daemon is already listening on this
/// port we exit quietly (exit 0). Combined with the LaunchDaemon's
/// `KeepAlive -> SuccessfulExit=false`, launchd will NOT respawn the secondary,
/// so no crash loop. Loopback TCP is shared across the roothide per-process
/// /var remap, so the app (jbroot view) and the daemon (real-root view) both
/// reach the same listener — which a unix-socket path could not guarantee.
fn bind_agent_sock() -> TcpListener {
    let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1)), AGENT_PORT);
    for _ in 0..12 {
        match TcpStream::connect(addr) {
            Ok(_) => {
                log_line("agent 端口已被其他实例占用，本实例退出复用");
                std::process::exit(0);
            }
            Err(_) => {}
        }
        match TcpListener::bind(addr) {
            Ok(l) => return l,
            Err(e) if e.kind() == std::io::ErrorKind::AddrInUse => {
                std::thread::sleep(std::time::Duration::from_millis(100));
                continue;
            }
            Err(e) => panic!("agent 端口绑定失败: addr={:?} err={}", addr, e),
        }
    }
    panic!("agent 端口绑定失败（重试耗尽）");
}
