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
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LazyLock, Mutex};
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};
use std::path::Path;

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

/// 读 App 写的共享 config.plist（XML），解析出 autoglm-phone 的端点 + 模型。
/// 与 Obj-C operit-agent.m 的 chatCompletion 逻辑 1:1 一致。
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

    let (endpoint, model) = if provider == "custom" {
        let b = base_url.trim_end_matches('/');
        let ep = if b.is_empty() {
            AUTOGLM_ENDPOINT.to_string()
        } else {
            format!("{}/chat/completions", b)
        };
        (ep, model)
    } else {
        (
            AUTOGLM_ENDPOINT.to_string(),
            if model.is_empty() {
                "autoglm-phone".to_string()
            } else {
                model
            },
        )
    };
    if api_key.is_empty() {
        return None;
    }
    Some(DeviceAgentConfig {
        api_key,
        api_base: endpoint,
        model,
    })
}

fn run_task(goal: String, stop: Arc<AtomicBool>) {
    let _ = fs::remove_file(operit_ios_env::data_root().join("logs/agent.log"));
    log_line(&format!("任务开始: {}", goal));

    let cfg = match load_config() {
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
        _ => "ERR|unknown".to_string(),
    }
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

fn main() {
    let _ = fs::create_dir_all(operit_ios_env::data_root().join("logs"));
    let sock = operit_ios_env::data_root().join("agent.sock");
    log_line(&format!(
        "operit-agent daemon v{} 启动, sock={:?}",
        DAEMON_VERSION, sock
    ));
    let listener = bind_agent_sock(&sock);
    // Best-effort: drop the socket file when the process exits (graceful or via
    // unwind from a panic), so a restart does not trip on a stale file.
    let _guard = SockGuard { path: &sock };
    let _ = fs::set_permissions(&sock, fs::Permissions::from_mode(0o666));

    for conn in listener.incoming() {
        if let Ok(stream) = conn {
            thread::spawn(move || handle_client(stream));
        }
    }
}

/// Bind the agent control socket, tolerating a stale/leftover socket file or a
/// second launchd-spawned instance racing on the same path.
///
/// - If the socket file exists but no live daemon is listening, we unlink and
///   retry (covers crashes that left a dead file behind).
/// - If a live daemon is already serving, we exit quietly so launchd's
///   KeepAlive does not spin a crash loop.
fn bind_agent_sock(sock: &Path) -> UnixListener {
    for attempt in 0..4 {
        let _ = fs::remove_file(sock);
        match UnixListener::bind(sock) {
            Ok(l) => return l,
            Err(e) if e.kind() == std::io::ErrorKind::AddrInUse && attempt < 3 => {
                match UnixStream::connect(sock) {
                    Ok(_) => {
                        log_line("agent.sock 已被其他实例占用，本实例退出复用");
                        std::process::exit(0);
                    }
                    Err(_) => {
                        let _ = fs::remove_file(sock);
                        std::thread::sleep(std::time::Duration::from_millis(150));
                        continue;
                    }
                }
            }
            Err(e) => panic!("agent.sock 绑定失败: {}", e),
        }
    }
    panic!("agent.sock 绑定失败（重试耗尽）");
}

struct SockGuard<'a> {
    path: &'a Path,
}
impl<'a> Drop for SockGuard<'a> {
    fn drop(&mut self) {
        let _ = fs::remove_file(self.path);
    }
}
