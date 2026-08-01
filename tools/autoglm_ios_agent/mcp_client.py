"""Minimal JSON-RPC client for the ios-mcp server (HTTP transport).

Endpoint: http://<device>:8090/mcp  (per official ios-mcp spec).
Only the tools we need for the AutoGLM loop are wrapped. Screenshot returns
base64 JPEG (point size) in result.content[0].data; everything else returns
text in result.content[0].text.

This is intentionally dependency-free (urllib only) so it runs on a bare Mac
and ports cleanly into operit2-ios later.
"""

import base64
import json
import os
import sys
import urllib.request


class IosMcpClient:
    def __init__(self, url: str = "http://192.168.1.21:8090/mcp", timeout: int = 30):
        self.url = url
        self.timeout = timeout
        self._id = 0
        self._init()

    # ---- low-level ----
    def _rpc(self, method, params=None, notify=False):
        self._id += 1
        body = json.dumps(
            {"jsonrpc": "2.0", "id": self._id, "method": method, "params": params or {}}
        ).encode()
        req = urllib.request.Request(
            self.url,
            data=body,
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
            },
        )
        with urllib.request.urlopen(req, timeout=self.timeout) as r:
            raw = r.read().decode()
        if notify:
            return None
        if "data:" in raw:  # SSE wrapper
            for line in raw.splitlines():
                if line.startswith("data:"):
                    raw = line[5:].strip()
        return json.loads(raw)

    def _init(self):
        self._rpc(
            "initialize",
            {
                "protocolVersion": "2025-11-25",
                "capabilities": {},
                "clientInfo": {"name": "autoglm-ios-agent", "version": "0.1"},
            },
        )
        self._rpc("notifications/initialized", {}, notify=True)

    def call_tool(self, name: str, arguments: dict | None = None) -> dict:
        """Call an MCP tool; return {'type':'image'|'text', 'data'|'text':..., 'raw': result}."""
        resp = self._rpc("tools/call", {"name": name, "arguments": arguments or {}})
        if "error" in resp:
            raise RuntimeError(f"MCP tool {name} error: {resp['error']}")
        content = resp.get("result", {}).get("content", [])
        if "AUTOGLM_DEBUG" in os.environ:
            for it in content:
                if it.get("type") == "image":
                    print(f"[MCP:{name}] <image {len(it.get('data',''))}B>", file=sys.stderr)
                else:
                    print(f"[MCP:{name}] {str(it.get('text',''))[:3000]}", file=sys.stderr)
        if not content:
            return {"type": "text", "text": "", "raw": resp.get("result", {})}
        item = content[0]
        if item.get("type") == "image":
            return {
                "type": "image",
                "data": item.get("data"),
                "mime": item.get("mimeType", "image/jpeg"),
                "raw": resp.get("result", {}),
            }
        return {"type": "text", "text": item.get("text", ""), "raw": resp.get("result", {})}

    # ---- high-level wrappers ----
    def get_screen_info(self) -> dict:
        # Returns dimensions/scale/orientation; we mostly need width/height.
        res = self.call_tool("get_screen_info")
        # ios-mcp get_screen_info returns structured text; parse width/height loosely.
        text = res.get("text", "")
        info = {}
        for line in text.splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                info[k.strip().lower()] = v.strip()
        # Fallback numeric scan
        import re

        w = re.search(r"width[\"'\s:]*(\d+)", text, re.I)
        h = re.search(r"height[\"'\s:]*(\d+)", text, re.I)
        if w and h:
            info["width"] = int(w.group(1))
            info["height"] = int(h.group(1))
        # Some servers return JSON in text
        try:
            j = json.loads(text)
            info.update(j)
        except Exception:
            pass
        # Normalize locked / screen_on to real booleans so the lock guard never
        # misfires on a stray "true" string elsewhere in the payload.
        if "locked" in info:
            v = info["locked"]
            if isinstance(v, str):
                info["locked"] = v.strip().lower() in ("true", "1", "yes")
        if "screen_on" in info and isinstance(info.get("screen_on"), str):
            info["screen_on"] = info["screen_on"].strip().lower() in ("true", "1", "yes")
        for alt in ("islocked", "is_locked", "lockstate", "isLocked"):
            if alt in info and "locked" not in info:
                v = info[alt]
                info["locked"] = (v is True) or (
                    isinstance(v, str) and v.strip().lower() in ("true", "1", "yes")
                )
        return info

    def screenshot_b64(self) -> str:
        res = self.call_tool("screenshot", {})
        if res.get("type") == "image" and res.get("data"):
            return res["data"]
        # Some servers embed base64 in text
        import re

        m = re.search(r"data:image/\w+;base64,([A-Za-z0-9+/=]+)", res.get("text", ""))
        if m:
            return m.group(1)
        raise RuntimeError("screenshot did not return image data")

    def get_frontmost_app(self) -> dict:
        res = self.call_tool("get_frontmost_app", {})
        text = res.get("text", "")
        info = {}
        import re

        b = re.search(r"bundle[^\n:]*:\s*([\w.\-]+)", text, re.I)
        n = re.search(r"name[^\n:]*:\s*([^\n]+)", text, re.I)
        if b:
            info["bundle_id"] = b.group(1).strip()
        if n:
            info["name"] = n.group(1).strip()
        try:
            j = json.loads(text)
            info.update(j)
        except Exception:
            pass
        return info

    def list_apps(self) -> list:
        """Return list of {'name':..., 'bundle_id':...} for installed apps."""
        res = self.call_tool("list_apps", {"type": "user"})
        text = res.get("text", "")
        apps = []
        import re

        # Try JSON first
        try:
            data = json.loads(text)
            if isinstance(data, list):
                for a in data:
                    apps.append(
                        {
                            "name": a.get("name") or a.get("localizedName") or "",
                            "bundle_id": a.get("bundleId") or a.get("bundle_id") or "",
                        }
                    )
                return apps
        except Exception:
            pass
        # Fallback: line scan "Name (bundleId)"
        for m in re.finditer(r"([^(]+)\s*\(([\w.\-]+)\)", text):
            apps.append({"name": m.group(1).strip(), "bundle_id": m.group(2).strip()})
        return apps

    def tap(self, x: int, y: int):
        return self.call_tool("tap_screen", {"x": int(x), "y": int(y)})

    def swipe(self, fx: int, fy: int, tx: int, ty: int, duration: float = 0.3):
        return self.call_tool(
            "swipe_screen",
            {
                "fromX": int(fx),
                "fromY": int(fy),
                "toX": int(tx),
                "toY": int(ty),
                "duration": duration,
            },
        )

    def input_text(self, text: str):
        return self.call_tool("input_text", {"text": text})

    def type_text(self, text: str):
        return self.call_tool("type_text", {"text": text})

    def launch_app(self, bundle_id: str):
        return self.call_tool("launch_app", {"bundle_id": bundle_id})

    def press_home(self):
        return self.call_tool("press_home", {})

    def wake_and_home(self):
        return self.call_tool("wake_and_home", {})

    def long_press(self, x: int, y: int, duration: float = 1.2):
        return self.call_tool("long_press", {"x": int(x), "y": int(y), "duration": duration})

    def double_tap(self, x: int, y: int):
        return self.call_tool("double_tap", {"x": int(x), "y": int(y)})

    # ---- semantic element support (for tap-by-element, the agent-device style) ----
    def describe_screen(self, include_screenshot=False, include_ocr=False) -> dict:
        """Front app + tappable elements (+ optional screenshot/ocr).
        Returns {'raw': text, 'elements': [...]}. Element format calibrated
        against real device output — see _parse_elements."""
        res = self.call_tool(
            "describe_screen",
            {"include_screenshot": bool(include_screenshot), "include_ocr": bool(include_ocr)},
        )
        text = res.get("text", "")
        return {"raw": text, "elements": _parse_elements(text)}

    def get_ui_elements(self, visible_only=True, limit=80, debug=False) -> list:
        """AX-tree elements. Returns list of {text,label,rect:[x,y,w,h],cx,cy}."""
        res = self.call_tool(
            "get_ui_elements",
            {"visible_only": bool(visible_only), "limit": int(limit), "debug": bool(debug)},
        )
        return _parse_elements(res.get("text", ""))

    def tap_element(self, text=None, label=None, index=0) -> dict:
        """Tap by semantic ref (text/label) instead of raw coordinates.
        Mirrors agent-device's `find \"Sign In\" click` / `press @e2`."""
        args = {"index": int(index)}
        if text:
            args["text"] = text
        if label:
            args["label"] = label
        return self.call_tool("tap_element", args)


def _parse_elements(text: str) -> list:
    """Best-effort parse of ios-mcp describe_screen/get_ui_elements text into a
    list of {text,label,rect:[x,y,w,h],cx,cy}. Server output format varies, so
    we try JSON first, then a few common line shapes. Calibrate on real device.
    """
    import re

    if not text:
        return []
    # 1) JSON: array of element objects, or {"elements":[...]}
    try:
        data = json.loads(text)
        if isinstance(data, dict):
            data = data.get("elements") or data.get("ui_elements") or data.get("items") or []
        if isinstance(data, list):
            out = []
            for e in data:
                if not isinstance(e, dict):
                    continue
                rect = e.get("rect") or e.get("frame") or {}
                x = rect.get("x", 0) or 0
                y = rect.get("y", 0) or 0
                w = rect.get("width", 0) or 0
                h = rect.get("height", 0) or 0
                txt = e.get("text") or e.get("label") or e.get("name") or ""
                out.append(
                    {
                        "text": txt,
                        "label": e.get("label") or txt,
                        "rect": [x, y, w, h],
                        "cx": x + w / 2,
                        "cy": y + h / 2,
                    }
                )
            return out
    except Exception:
        pass
    # 2) line-based: [type] "text" (x, y, w, h)  or  "text" at x,y
    out = []
    for line in text.splitlines():
        m = re.search(r"\(?\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*(\d+)\s*,\s*(\d+)\s*)?\)?", line)
        if not m:
            continue
        x, y = int(m.group(1)), int(m.group(2))
        w = int(m.group(3)) if m.group(3) else 0
        h = int(m.group(4)) if m.group(4) else 0
        quotes = re.findall(r'"([^"]+)"', line)
        if quotes:
            # last quoted span is usually the element text (role comes first)
            txt = quotes[-1]
        else:
            sq = re.findall(r"'([^']+)'", line)
            txt = sq[-1] if sq else line.strip()
        out.append(
            {"text": txt, "label": txt, "rect": [x, y, w, h], "cx": x + w / 2, "cy": y + h / 2}
        )
    return out
