#![cfg(target_os = "ios")]
//! MCP client for the `ios-mcp` jailbreak tweak.
//!
//! `ios-mcp` runs as a SpringBoard tweak and exposes on-device UI automation
//! (screenshot / tap / swipe / OCR / app control / screen info) as MCP tools over
//! HTTP at `127.0.0.1:8090/mcp`. Operit2 delegates its daemon device layer to it,
//! replacing the old `operit-sb` Unix-socket bridge.
//!
//! Protocol facts verified against ios-mcp `MCPServer.m` (witchan/ios-mcp):
//! - `POST {url}` with JSON-RPC 2.0; `initialize` then `tools/call`.
//! - `tools/call` result: `result.content` (array) and/or `result.structuredContent`
//!   (object). Image tools return `content[0] = {type:"image", data:<base64>, mimeType}`.
//! - `structuredContent` tools (screen_info / frontmost_app / ocr_screen) also echo the
//!   dict as `content[0].text` (a JSON string), so we parse either.
//! - Coordinates for tap/swipe/long_press are **screen points**, not normalized; we
//!   convert from Operit2's `NormalizedPoint` using `get_screen_info` width/height.
//! - `screenshot` returns a base64 **JPEG**; Operit2 needs PNG, so we re-encode.

use std::sync::Mutex;
use std::time::Duration;

use base64::Engine;
use operit_host_api::{HostError, HostResult, NormalizedPoint};
use serde_json::{json, Value};

const DEFAULT_URL: &str = "http://127.0.0.1:8090/mcp";
const PROTOCOL_VERSION: &str = "2025-11-25";

pub struct IosMcpClient {
    url: String,
    client: reqwest::blocking::Client,
    initialized: Mutex<bool>,
    screen_size: Mutex<Option<(f64, f64)>>,
}

impl IosMcpClient {
    pub fn new() -> Self {
        let url = std::env::var("IOS_MCP_URL").unwrap_or_else(|_| DEFAULT_URL.to_string());
        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(60))
            .build()
            .expect("ios-mcp: failed to build HTTP client");
        Self {
            url,
            client,
            initialized: Mutex::new(false),
            screen_size: Mutex::new(None),
        }
    }

    fn ensure_initialized(&self) {
        let mut init = self.initialized.lock().unwrap();
        if *init {
            return;
        }
        // Best-effort handshake; the server stores the negotiated version globally.
        let _ = self.raw_call(
            "initialize",
            json!({
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "operit2", "version": "0.3.47"}
            }),
        );
        *init = true;
    }

    fn raw_call(&self, method: &str, params: Value) -> HostResult<Value> {
        let body = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params
        });
        let resp = self
            .client
            .post(self.url.as_str())
            .header("Content-Type", "application/json")
            .json(&body)
            .send()
            .map_err(|e| HostError::new(format!("ios-mcp: http request failed: {}", e)))?;
        let status = resp.status();
        let val: Value = resp
            .json()
            .map_err(|e| HostError::new(format!("ios-mcp: invalid JSON response: {}", e)))?;
        if !status.is_success() {
            return Err(HostError::new(format!("ios-mcp: http status {}", status)));
        }
        if let Some(err) = val.get("error") {
            return Err(HostError::new(format!("ios-mcp: rpc error: {}", err)));
        }
        val.get("result")
            .cloned()
            .ok_or_else(|| HostError::new("ios-mcp: response missing `result`".to_string()))
    }

    /// Calls an MCP tool and returns its `result` object.
    pub fn call_tool(&self, name: &str, args: Value) -> HostResult<Value> {
        self.ensure_initialized();
        let result = self.raw_call(
            "tools/call",
            json!({ "name": name, "arguments": args }),
        )?;
        if result
            .get("isError")
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
        {
            let msg = result_structured_text(&result)
                .unwrap_or_else(|| "tool reported isError".to_string());
            return Err(HostError::new(format!("ios-mcp: `{}` failed: {}", name, msg)));
        }
        Ok(result)
    }

    fn screen_size(&self) -> HostResult<(f64, f64)> {
        if let Some(s) = *self.screen_size.lock().unwrap() {
            return Ok(s);
        }
        let info = result_structured(&self.call_tool("get_screen_info", json!({}))?)?;
        let w = info
            .get("width")
            .and_then(|v| v.as_f64())
            .ok_or_else(|| HostError::new("ios-mcp: screen_info.width missing".to_string()))?;
        let h = info
            .get("height")
            .and_then(|v| v.as_f64())
            .ok_or_else(|| HostError::new("ios-mcp: screen_info.height missing".to_string()))?;
        *self.screen_size.lock().unwrap() = Some((w, h));
        Ok((w, h))
    }

    fn to_points(&self, p: NormalizedPoint) -> HostResult<(f64, f64)> {
        let (w, h) = self.screen_size()?;
        Ok((p.x * w, p.y * h))
    }

    /// Captures the screen and returns PNG bytes + pixel dimensions
    /// (ios-mcp hands back a base64 JPEG, which we re-encode to PNG).
    pub fn screenshot_png(&self) -> HostResult<(Vec<u8>, u32, u32)> {
        let r = self.call_tool("screenshot", json!({}))?;
        let content = r
            .get("content")
            .and_then(|c| c.as_array())
            .ok_or_else(|| HostError::new("ios-mcp: screenshot returned no content".to_string()))?;
        let img = content
            .iter()
            .find(|c| c.get("type").and_then(|t| t.as_str()) == Some("image"))
            .ok_or_else(|| HostError::new("ios-mcp: screenshot content has no image".to_string()))?;
        let data_b64 = img
            .get("data")
            .and_then(|d| d.as_str())
            .ok_or_else(|| HostError::new("ios-mcp: screenshot image missing `data`".to_string()))?;
        let jpeg = base64::engine::general_purpose::STANDARD
            .decode(data_b64)
            .map_err(|e| HostError::new(format!("ios-mcp: decode base64 JPEG: {}", e)))?;
        let dyn_img = image::load_from_memory(&jpeg)
            .map_err(|e| HostError::new(format!("ios-mcp: decode JPEG: {}", e)))?;
        let mut png: Vec<u8> = Vec::new();
        {
            let mut cursor = std::io::Cursor::new(&mut png);
            dyn_img
                .write_to(&mut cursor, image::ImageOutputFormat::Png)
                .map_err(|e| HostError::new(format!("ios-mcp: encode PNG: {}", e)))?;
        }
        Ok((png, dyn_img.width(), dyn_img.height()))
    }

    pub fn tap(&self, p: NormalizedPoint) -> HostResult<()> {
        let (x, y) = self.to_points(p)?;
        self.call_tool("tap_screen", json!({ "x": x, "y": y }))
            .map(|_| ())
    }

    pub fn swipe(
        &self,
        start: NormalizedPoint,
        end: NormalizedPoint,
        duration_ms: u64,
    ) -> HostResult<()> {
        let (w, h) = self.screen_size()?;
        self.call_tool(
            "swipe_screen",
            json!({
                "fromX": start.x * w,
                "fromY": start.y * h,
                "toX": end.x * w,
                "toY": end.y * h,
                "duration": duration_ms
            }),
        )
        .map(|_| ())
    }

    pub fn long_press(&self, p: NormalizedPoint, duration_ms: u64) -> HostResult<()> {
        let (x, y) = self.to_points(p)?;
        self.call_tool(
            "long_press",
            json!({ "x": x, "y": y, "duration": duration_ms }),
        )
        .map(|_| ())
    }

    pub fn input_text(&self, text: &str) -> HostResult<()> {
        match self.call_tool("input_text", json!({ "text": text })) {
            Ok(_) => Ok(()),
            Err(first_err) => {
                // ios-mcp advises retrying with type_text on failure.
                self.call_tool("type_text", json!({ "text": text }))
                    .map(|_| ())
                    .map_err(|_| first_err)
            }
        }
    }

    pub fn launch_app(&self, bundle_id: &str) -> HostResult<()> {
        self.call_tool("launch_app", json!({ "bundle_id": bundle_id }))
            .map(|_| ())
    }

    pub fn press_home(&self) -> HostResult<()> {
        self.call_tool("press_home", json!({})).map(|_| ())
    }

    pub fn frontmost_app(&self) -> HostResult<String> {
        let info = result_structured(&self.call_tool("get_frontmost_app", json!({}))?)?;
        let bundle = info.get("bundleId").and_then(|v| v.as_str());
        let name = info.get("name").and_then(|v| v.as_str());
        match (bundle, name) {
            (Some(b), Some(n)) => Ok(format!("{}|{}", b, n)),
            (Some(b), None) => Ok(b.to_string()),
            (None, Some(n)) => Ok(n.to_string()),
            (None, None) => Err(HostError::new(
                "ios-mcp: get_frontmost_app returned empty info".to_string(),
            )),
        }
    }

    /// Runs on-device OCR on the current screen and returns the concatenated text.
    /// `ocr_screen` does not accept an image; it always OCRs the live screen.
    pub fn ocr_screen(&self, languages: &[&str]) -> HostResult<String> {
        let args = json!({ "languages": languages });
        let r = self.call_tool("ocr_screen", args)?;
        // Prefer structuredContent, else parse content[0].text as JSON or plain text.
        if let Some(sc) = r.get("structuredContent").and_then(|v| v.as_object()) {
            if let Some(text) = sc.get("text").and_then(|v| v.as_str()) {
                return Ok(text.to_string());
            }
            if let Some(texts) = sc.get("texts").and_then(|v| v.as_array()) {
                return Ok(join_texts(texts));
            }
        }
        if let Some(arr) = r.get("content").and_then(|c| c.as_array()) {
            let mut out = String::new();
            for item in arr {
                if let Some(txt) = item.get("text").and_then(|t| t.as_str()) {
                    if let Ok(v) = serde_json::from_str::<Value>(txt) {
                        if let Some(text) = v.get("text").and_then(|x| x.as_str()) {
                            return Ok(text.to_string());
                        }
                        if let Some(texts) = v.get("texts").and_then(|x| x.as_array()) {
                            return Ok(join_texts(texts));
                        }
                    }
                    if !out.is_empty() {
                        out.push('\n');
                    }
                    out.push_str(txt);
                }
            }
            if !out.is_empty() {
                return Ok(out);
            }
        }
        Err(HostError::new(
            "ios-mcp: ocr_screen returned no recognizable text".to_string(),
        ))
    }
}

/// Concatenates the `text` field of each OCR text block.
fn join_texts(texts: &[Value]) -> String {
    let mut out = String::new();
    for t in texts {
        if let Some(s) = t.get("text").and_then(|x| x.as_str()) {
            if !out.is_empty() {
                out.push('\n');
            }
            out.push_str(s);
        }
    }
    out
}

/// Extracts the structured object from a tool result: prefer `structuredContent`,
/// else parse `content[0].text` as JSON.
fn result_structured(result: &Value) -> HostResult<Value> {
    if let Some(sc) = result.get("structuredContent") {
        if sc.is_object() {
            return Ok(sc.clone());
        }
    }
    if let Some(arr) = result.get("content").and_then(|c| c.as_array()) {
        for item in arr {
            if let Some(txt) = item.get("text").and_then(|t| t.as_str()) {
                if let Ok(v) = serde_json::from_str::<Value>(txt) {
                    return Ok(v);
                }
            }
        }
    }
    Err(HostError::new(
        "ios-mcp: result has no structured content".to_string(),
    ))
}

/// Best-effort: pull a human-readable message out of a (possibly errored) result.
fn result_structured_text(result: &Value) -> Option<String> {
    if let Some(arr) = result.get("content").and_then(|c| c.as_array()) {
        let mut out = String::new();
        for item in arr {
            if let Some(txt) = item.get("text").and_then(|t| t.as_str()) {
                if !out.is_empty() {
                    out.push(' ');
                }
                out.push_str(txt);
            }
        }
        if !out.is_empty() {
            return Some(out);
        }
    }
    result
        .get("structuredContent")
        .and_then(|sc| serde_json::to_string(sc).ok())
}
