#![cfg(target_os = "ios")]

//! iOS device-automation host.
//!
//! This module turns high-level automation intents (screenshot / tap / swipe /
//! long-press / type / launch / home / back) into concrete device actions. It
//! talks to the device through TWO independent channels, chosen per-call with an
//! "ios-mcp first, unix-socket fallback" strategy:
//!
//! 1. **Primary — `ios-mcp` jailbreak tweak over HTTP**
//!    (`127.0.0.1:8090/mcp`, JSON-RPC 2.0). The tweak exposes screenshot / tap /
//!    swipe / OCR / app control as MCP tools. This is the modern path and works
//!    whenever ios-mcp is installed. All entry points in the
//!    `DeviceAutomationHost` impl call `self.mcp.*` first and only fall through
//!    to the socket on error.
//!
//! 2. **Fallback — `operit-sb` SpringBoard control socket (Unix domain socket)**
//!    at `data_root()/operit.sock`. Used only when ios-mcp is unavailable, so
//!    Operit2 still works if only the old SpringBoard tweak is loaded. The only
//!    code that touches this socket is [`IosDeviceAutomationHost::send_cmd`].
//!
//! **IMPORTANT — this is a DIFFERENT channel from the `127.0.0.1:8890` agent
//! control TCP.** The 8890 socket is the daemon control plane used to (a) push
//! LLM credentials from the App to the agent daemon
//! (`operit_flutter_bridge::push_config_over_tcp` → `operit_agent_daemon`'s
//! `config` command) and (b) send agent run commands (`start`/`stop`/`goal`/
//! `status`) from `ToolRegistration` / `AppleRuntimeChannel`. This file NEVER
//! opens 8890 — do not confuse the two subsystems.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;

use operit_host_api::{
    DeviceAutomationHost, DeviceScreenshot, HostError, HostResult, NormalizedPoint,
};

use crate::ios_mcp::IosMcpClient;

/// Path to the SpringBoard tweak's control socket. Used only as a fallback when
/// ios-mcp is unavailable. Resolved at runtime from the active jailbreak root
/// (see `operit_ios_env`).


pub struct IosDeviceAutomationHost {
    mcp: IosMcpClient,
}

impl IosDeviceAutomationHost {
    pub fn new() -> Self {
        Self {
            mcp: IosMcpClient::new(),
        }
    }

    /// Sends one line-command to `operit-sb` and returns the full reply (read to EOF).
    fn send_cmd(&self, cmd: &str) -> HostResult<String> {
        // Non-jailbreak: the operit-sb tweak is not injected, so its control
        // socket can never exist. ios-mcp remains the primary automation path;
        // if that is also unavailable the caller already surfaces a clear error.
        // Skipping the connect here avoids a misleading "cannot connect" message.
        if !operit_ios_env::provider().can_inject_tweaks() {
            return Err(HostError::new(
                "device bridge: tweak injection unavailable (non-jailbreak); only ios-mcp is possible"
                    .to_string(),
            ));
        }
        // NOTE: this is the *legacy* `operit-sb` unix socket (operit.sock), NOT
        // the 8890 TCP agent-control channel. It is only reachable on jailbroken
        // devices where a SpringBoard tweak injected the socket; on non-jb builds
        // can_inject_tweaks() is false and we returned early above.
        let mut stream = UnixStream::connect(operit_ios_env::data_root().join("operit.sock")).map_err(|e| {
            HostError::new(format!(
                "device bridge: cannot connect to {} (is the SpringBoard tweak loaded?)",
                e
            ))
        })?;
        stream
            .write_all(cmd.as_bytes())
            .and_then(|_| stream.write_all(b"\n"))
            .map_err(|e| HostError::new(format!("device bridge: send failed: {}", e)))?;
        let mut resp = String::new();
        stream
            .read_to_string(&mut resp)
            .map_err(|e| HostError::new(format!("device bridge: read failed: {}", e)))?;
        Ok(resp)
    }

    /// Sends a command and treats any `OK|...` reply as success.
    fn send_expect_ok(&self, cmd: &str) -> HostResult<()> {
        let resp = self.send_cmd(cmd)?;
        let resp = resp.trim();
        if resp.starts_with("OK|") {
            Ok(())
        } else {
            Err(HostError::new(format!("device bridge: {}", resp)))
        }
    }
}

/// Extracts `width`/`height` from a PNG IHDR block (bytes 16..24 after the 8-byte sig).
fn png_size(data: &[u8]) -> (u32, u32) {
    if data.len() >= 24 && &data[1..4] == b"PNG" {
        let w = u32::from_be_bytes([data[16], data[17], data[18], data[19]]);
        let h = u32::from_be_bytes([data[20], data[21], data[22], data[23]]);
        (w, h)
    } else {
        (0, 0)
    }
}

impl DeviceAutomationHost for IosDeviceAutomationHost {
    fn captureScreenshot(&self) -> HostResult<DeviceScreenshot> {
        match self.mcp.screenshot_png() {
            Ok((png, width, height)) => Ok(DeviceScreenshot {
                imagePng: png,
                width,
                height,
            }),
            Err(mcp_err) => {
                // Fallback: operit-sb socket returns a PNG path.
                let resp = self.send_cmd("screenshot").map_err(|e| {
                    HostError::new(format!("{}; ios-mcp also failed: {}", e, mcp_err))
                })?;
                let resp = resp.trim();
                if !resp.starts_with("OK|screenshot") {
                    return Err(HostError::new(format!("screenshot failed: {}", resp)));
                }
                let path = resp
                    .split("->")
                    .nth(1)
                    .map(str::trim)
                    .ok_or_else(|| HostError::new("screenshot: no path in response".to_string()))?;
                let png = std::fs::read(path).map_err(|e| {
                    HostError::new(format!("screenshot: read {} failed: {}", path, e))
                })?;
                let (width, height) = png_size(&png);
                Ok(DeviceScreenshot {
                    imagePng: png,
                    width,
                    height,
                })
            }
        }
    }

    fn tap(&self, point: NormalizedPoint) -> HostResult<()> {
        self.mcp
            .tap(point)
            .or_else(|_| self.send_expect_ok(&format!("tap {} {}", point.x, point.y)))
    }

    fn swipe(
        &self,
        start: NormalizedPoint,
        end: NormalizedPoint,
        durationMs: u64,
    ) -> HostResult<()> {
        self.mcp
            .swipe(start, end, durationMs)
            .or_else(|_| {
                self.send_expect_ok(&format!(
                    "swipe {} {} {} {} {}",
                    start.x, start.y, end.x, end.y, durationMs
                ))
            })
    }

    fn longPress(&self, point: NormalizedPoint, durationMs: u64) -> HostResult<()> {
        self.mcp
            .long_press(point, durationMs)
            .or_else(|_| self.send_expect_ok(&format!("longpress {} {}", point.x, point.y)))
    }

    fn typeText(&self, text: &str) -> HostResult<()> {
        self.mcp
            .input_text(text)
            .or_else(|_| self.send_expect_ok(&format!("type {}", text)))
    }

    fn launchApp(&self, bundleId: &str) -> HostResult<()> {
        self.mcp
            .launch_app(bundleId)
            .or_else(|_| self.send_expect_ok(&format!("launch {}", bundleId)))
    }

    fn pressHome(&self) -> HostResult<()> {
        self.mcp
            .press_home()
            .or_else(|_| self.send_expect_ok("home"))
    }

    fn pressBack(&self) -> HostResult<()> {
        // iOS has no system back key; emulate the in-app left-edge swipe.
        // Prefer ios-mcp swipe; fall back to the socket.
        let start = NormalizedPoint { x: 0.01, y: 0.5 };
        let end = NormalizedPoint { x: 0.4, y: 0.5 };
        self.mcp
            .swipe(start, end, 300)
            .or_else(|_| self.send_expect_ok("swipe 0.01 0.5 0.4 0.5 300"))
    }

    fn frontmost_app(&self) -> HostResult<String> {
        match self.mcp.frontmost_app() {
            Ok(s) => Ok(s),
            Err(_) => {
                let resp = self.send_cmd("front")?;
                let resp = resp.trim();
                if let Some(rest) = resp.strip_prefix("OK|front ") {
                    Ok(rest.to_string())
                } else if let Some(err) = resp.strip_prefix("ERR|") {
                    Err(HostError::new(format!("front: {}", err)))
                } else {
                    Err(HostError::new(format!("front: 意外返回 {}", resp)))
                }
            }
        }
    }
}
