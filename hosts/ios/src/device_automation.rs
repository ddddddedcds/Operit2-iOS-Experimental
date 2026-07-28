#![cfg(target_os = "ios")]

//! iOS device-automation host backed by the Operit jailbreak SpringBoard tweak.
//!
//! The (sandboxed) Flutter app cannot touch the screen directly; every UI action
//! is forwarded over a local Unix socket to `operit-sb`, which performs the
//! privileged work inside SpringBoard. Coordinates use the normalized `[0,1]`
//! protocol so callers never deal with @2x/@3x pixel math.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;

use operit_host_api::{
    DeviceAutomationHost, DeviceScreenshot, HostError, HostResult, NormalizedPoint,
};

/// Path to the SpringBoard tweak's control socket (rootless jailbreak layout).
const SOCK_PATH: &str = "/var/jb/var/mobile/.operit/operit.sock";

/// Talks to `operit-sb` over its Unix socket. The tweak protocol is line-based:
/// `<cmd> [args...]\n`, the server replies once, then closes the socket (read to EOF).
pub struct IosDeviceAutomationHost;

impl IosDeviceAutomationHost {
    /// Creates the iOS device-automation host.
    pub fn new() -> Self {
        Self
    }

    /// Sends one line-command and returns the full reply text (read until EOF).
    fn send_cmd(&self, cmd: &str) -> HostResult<String> {
        let mut stream = UnixStream::connect(SOCK_PATH).map_err(|e| {
            HostError::new(format!(
                "device bridge: cannot connect to {} (is the SpringBoard tweak loaded / device resprung?)",
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
        let resp = self.send_cmd("screenshot")?;
        let resp = resp.trim();
        if !resp.starts_with("OK|screenshot") {
            return Err(HostError::new(format!("screenshot failed: {}", resp)));
        }
        // tweak replies: "OK|screenshot <bytes> -> <path>"
        let path = resp
            .split("->")
            .nth(1)
            .map(str::trim)
            .ok_or_else(|| HostError::new("screenshot: no path in response"))?;
        let png = std::fs::read(path)
            .map_err(|e| HostError::new(format!("screenshot: read {} failed: {}", path, e)))?;
        let (width, height) = png_size(&png);
        Ok(DeviceScreenshot {
            imagePng: png,
            width,
            height,
        })
    }

    fn tap(&self, point: NormalizedPoint) -> HostResult<()> {
        self.send_expect_ok(&format!("tap {} {}", point.x, point.y))
    }

    fn swipe(
        &self,
        start: NormalizedPoint,
        end: NormalizedPoint,
        durationMs: u64,
    ) -> HostResult<()> {
        self.send_expect_ok(&format!(
            "swipe {} {} {} {} {}",
            start.x, start.y, end.x, end.y, durationMs
        ))
    }

    fn longPress(&self, point: NormalizedPoint, _durationMs: u64) -> HostResult<()> {
        // operit-sb's longpress uses a fixed internal duration; the caller's value is ignored
        // for now (extending the tweak protocol to accept it is a later task).
        self.send_expect_ok(&format!("longpress {} {}", point.x, point.y))
    }

    fn typeText(&self, text: &str) -> HostResult<()> {
        self.send_expect_ok(&format!("type {}", text))
    }

    fn launchApp(&self, bundleId: &str) -> HostResult<()> {
        self.send_expect_ok(&format!("launch {}", bundleId))
    }

    fn pressHome(&self) -> HostResult<()> {
        self.send_expect_ok("home")
    }

    fn pressBack(&self) -> HostResult<()> {
        // iOS has no system back key; emulate the in-app left-edge swipe (normalized).
        self.send_expect_ok("swipe 0.01 0.5 0.4 0.5 300")
    }

    fn frontmost_app(&self) -> HostResult<String> {
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
