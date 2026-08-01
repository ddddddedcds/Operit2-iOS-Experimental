"""Translate a parsed AutoGLM action dict into ios-mcp tool calls.

Key detail: AutoGLM emits coordinates in 0-1000 NORMALIZED space. ios-mcp
tools expect SCREEN POINTS (pixels). We convert using the current screen
size before every call.

Action set (from prompts_zh.py):
  Launch(app=)  Tap(element=, message=?)  Type(text=)  Type_Name(text=)
  Swipe(start=, end=)  Back  Home  Long Press(element=)  Double Tap(element=)
  Wait(duration="x seconds")  Take_over(message=)  Note / Call_API / Interact
  finish(message=)
"""

import os
import time

# iOS bundle_id fallbacks (Android package names in Open-AutoGLM's apps.py
# do NOT match iOS). Used only when the app is not found in list_apps output.
STATIC_IOS_BUNDLES = {
    "微信": "com.tencent.xin",
    "支付宝": "com.alipay.iphoneclient",
    "抖音": "com.ss.iphone.ugc.Aweme",
    "淘宝": "com.taobao.taobao4iphone",
    "京东": "com.jingdong.app.imall",
    "小红书": "com.xingin.xhs",
    "美团": "com.meituan.imeituan",
    "微博": "com.sina.weibo",
    "钉钉": "com.laiwang.DingTalk",
    "高德地图": "com.autonavi.minimap",
    "百度地图": "com.baidu.map",
    "bilibili": "tv.danmaku.bili",
    "网易云音乐": "com.netease.cloudmusic",
    "qq": "com.tencent.mqq",
    "qq音乐": "com.tencent.qqmusic",
    "今日头条": "com.ss.iphone.topic.news",
    "快手": "com.smile.iphone",
    "知乎": "com.zhihu.ios",
}

# iOS built-in system apps (Android package names in Open-AutoGLM's apps.py
# do NOT exist for these; iOS uses com.apple.* bundle ids). Covers both the
# Chinese display name and the common English name the model may emit.
STATIC_SYSTEM_BUNDLES = {
    "设置": "com.apple.Preferences",
    "通用": "com.apple.Preferences",  # General is a Settings sub-page; open Settings
    "照片": "com.apple.mobileslideshow",
    "相机": "com.apple.camera",
    "safari": "com.apple.mobilesafari",
    "safari浏览器": "com.apple.mobilesafari",
    "备忘录": "com.apple.mobilenotes",
    "提醒事项": "com.apple.reminders",
    "信息": "com.apple.MobileSMS",
    "短信": "com.apple.MobileSMS",
    "电话": "com.apple.mobilephone",
    "日历": "com.apple.mobilecal",
    "地图": "com.apple.Maps",
    "指南针": "com.apple.compass",
    "天气": "com.apple.weather",
    "时钟": "com.apple.mobiletimer",
    "计算器": "com.apple.calculator",
    "文件": "com.apple.files",
    "音乐": "com.apple.Music",
    "播客": "com.apple.podcasts",
    "钱包": "com.apple.Passbook",
    "健康": "com.apple.Health",
    "健身记录": "com.apple.Activity",
    "家庭": "com.apple.Home",
    "新闻": "com.apple.news",
    "股市": "com.apple.stocks",
    "图书": "com.apple.iBooks",
    "facetime": "com.apple.facetime",
    "通讯录": "com.apple.MobileAddressBook",
    "邮件": "com.apple.Mail",
    "翻译": "com.apple.Translate",
    "快捷指令": "com.apple.shortcuts",
    "查找": "com.apple.FindMy",
    "测距仪": "com.apple.measure",
    "提示": "com.apple.tips",
    "app store": "com.apple.AppStore",
    "books": "com.apple.iBooks",
    "notes": "com.apple.mobilenotes",
    "reminders": "com.apple.reminders",
    "messages": "com.apple.MobileSMS",
    "phone": "com.apple.mobilephone",
    "calendar": "com.apple.mobilecal",
    "camera": "com.apple.camera",
    "photos": "com.apple.mobileslideshow",
    "maps": "com.apple.Maps",
    "weather": "com.apple.weather",
    "clock": "com.apple.mobiletimer",
    "calculator": "com.apple.calculator",
    "files": "com.apple.files",
    "music": "com.apple.Music",
    "podcasts": "com.apple.podcasts",
    "wallet": "com.apple.Passbook",
    "health": "com.apple.Health",
    "mail": "com.apple.Mail",
    "news": "com.apple.news",
    "stocks": "com.apple.stocks",
    "translate": "com.apple.Translate",
    "shortcuts": "com.apple.shortcuts",
    "find my": "com.apple.FindMy",
    "measure": "com.apple.measure",
    "tips": "com.apple.tips",
    "appstore": "com.apple.AppStore",
    "settings": "com.apple.Preferences",
    "contacts": "com.apple.MobileAddressBook",
}


class Executor:
    def __init__(self, mcp, screen_w: int, screen_h: int, bundle_map: dict | None = None,
                 takeover_callback=None, confirm_callback=None):
        self.mcp = mcp
        self.w = screen_w
        self.h = screen_h
        self.bundle_map = {k.lower(): v for k, v in (bundle_map or {}).items()}
        self._installed_apps = None  # lazy cache for list_apps results
        self.takeover_callback = takeover_callback or self._default_takeover
        self.confirm_callback = confirm_callback or self._default_confirm

    def _to_px(self, el):
        x = int(round(el[0] / 1000.0 * self.w))
        y = int(round(el[1] / 1000.0 * self.h))
        return x, y

    def resolve_bundle(self, app_name: str) -> str | None:
        if not app_name:
            return None
        name = app_name.strip()
        key = name.lower()

        # 1) exact user-supplied map
        if key in self.bundle_map:
            return self.bundle_map[key]

        # 2) already a bundle id (e.g. model returned the id directly)
        if self._looks_like_bundle_id(name):
            return name

        # 3) exact static table (third-party + system), case-insensitive
        for table in (STATIC_IOS_BUNDLES, STATIC_SYSTEM_BUNDLES):
            for k, v in table.items():
                if k.lower() == key:
                    return v

        # 4) fuzzy over static keys (substring both directions, most specific wins)
        fuzzy = self._fuzzy_match(name, list(STATIC_IOS_BUNDLES.items()) + list(STATIC_SYSTEM_BUNDLES.items()))
        if fuzzy:
            return fuzzy

        # 5) fuzzy over the device's installed apps (queried lazily, once)
        installed = self._installed_apps_map()
        if key in installed:
            return installed[key]
        fuzzy_i = self._fuzzy_match(name, list(installed.items()))
        if fuzzy_i:
            return fuzzy_i

        return None

    @staticmethod
    def _looks_like_bundle_id(s: str) -> bool:
        if not s or " " in s:
            return False
        # bundle ids look like com.foo.bar: must contain a dot and be ASCII
        return ("." in s) and all(ord(c) < 128 for c in s)

    @staticmethod
    def _fuzzy_match(name: str, mapping) -> str | None:
        """Substring match both directions; most specific key wins.

        mapping: iterable of (key, value). Returns the best value or None.
        Direction A (key is a substring of input) prefers the LONGEST key so
        e.g. "Safari浏览器" -> "Safari" not a shorter junk key. Direction B
        (input is a substring of key) prefers the SHORTEST key to avoid
        matching a long unrelated name.
        """
        low = name.lower()
        fwd, rev = [], []
        for k, v in mapping:
            kl = (k or "").lower()
            if not kl:
                continue
            if kl in low:
                fwd.append((len(kl), v))
            elif low in kl:
                rev.append((len(kl), v))
        if fwd:
            fwd.sort(reverse=True)
            return fwd[0][1]
        if rev:
            rev.sort()
            return rev[0][1]
        return None

    def _installed_apps_map(self) -> dict:
        if self._installed_apps is None:
            self._installed_apps = {}
            try:
                for a in self.mcp.list_apps():
                    nm = (a.get("name") or "").strip().lower()
                    bid = a.get("bundle_id") or ""
                    if nm and bid:
                        # first occurrence wins (most specific already installed)
                        self._installed_apps.setdefault(nm, bid)
            except Exception:
                # ios-mcp may not support list_apps or be offline; degrade silently
                pass
        return self._installed_apps

    def execute(self, action: dict) -> dict:
        meta = action.get("_metadata")
        if meta == "finish":
            return {"success": True, "should_finish": True, "message": action.get("message", "")}
        if meta != "do":
            return {"success": False, "should_finish": True, "message": f"unknown meta: {meta}"}

        name = action.get("action")
        try:
            if name == "Launch":
                bid = self.resolve_bundle(action.get("app"))
                if not bid:
                    return {"success": False, "should_finish": False,
                            "message": f"app not found: {action.get('app')}"}
                self.mcp.launch_app(bid)
                return {"success": True, "should_finish": False}
            if name in ("Tap", "Double Tap", "Long Press"):
                el = action.get("element")
                if not el:
                    return {"success": False, "should_finish": False, "message": "no element"}
                x, y = self._to_px(el)
                if "message" in action:
                    if not self.confirm_callback(action["message"]):
                        return {"success": False, "should_finish": True,
                                "message": "user cancelled sensitive op"}
                if name == "Tap":
                    # Semantic-first: resolve (x,y) to an AX-tree element and tap
                    # by text/label when possible; fall back to raw coords for
                    # games/Flutter/Canvas where the AX tree is blind.
                    self._tap_semantic(x, y)
                elif name == "Double Tap":
                    self.mcp.double_tap(x, y)
                else:  # Long Press
                    dur = action.get("duration")
                    if dur is not None:
                        try:
                            dur = float(str(dur).replace("seconds", "").strip())
                        except ValueError:
                            dur = 1.2
                    else:
                        dur = 1.2
                    self.mcp.long_press(x, y, duration=dur)
                return {"success": True, "should_finish": False}
            if name in ("Type", "Type_Name"):
                text = action.get("text", "")
                try:
                    self.mcp.input_text(text)
                except Exception:
                    self.mcp.type_text(text)  # fallback per ios-mcp spec
                return {"success": True, "should_finish": False}
            if name == "Swipe":
                start = action.get("start")
                end = action.get("end")
                if not start or not end:
                    return {"success": False, "should_finish": False, "message": "missing swipe coords"}
                sx, sy = self._to_px(start)
                ex, ey = self._to_px(end)
                self.mcp.swipe(sx, sy, ex, ey, duration=0.3)
                return {"success": True, "should_finish": False}
            if name == "Back":
                # iOS has no universal back; mimic left-edge swipe gesture.
                self.mcp.swipe(0, self.h // 2, int(self.w * 0.4), self.h // 2, duration=0.25)
                return {"success": True, "should_finish": False}
            if name == "Home":
                self.mcp.press_home()
                return {"success": True, "should_finish": False}
            if name == "Wait":
                dur = action.get("duration", "1 seconds")
                try:
                    dur = float(str(dur).replace("seconds", "").strip())
                except ValueError:
                    dur = 1.0
                time.sleep(dur)
                return {"success": True, "should_finish": False}
            if name == "Take_over":
                self.takeover_callback(action.get("message", "user intervention required"))
                return {"success": True, "should_finish": False}
            if name in ("Note", "Call_API", "Interact"):
                return {"success": True, "should_finish": False,
                        "message": f"[no-op action] {name}"}
            return {"success": False, "should_finish": False, "message": f"unknown action: {name}"}
        except Exception as e:
            return {"success": False, "should_finish": False, "message": f"action failed: {e}"}

    @staticmethod
    def _default_takeover(message: str):
        input(f"[Take_over] {message}\nPress Enter after you finish the manual step... ")

    @staticmethod
    def _default_confirm(message: str) -> bool:
        print(f"[SENSITIVE] {message}")
        return True  # prototype: auto-allow; wire a real prompt later

    # ---- semantic tap (agent-device style: tap by element, not raw coord) ----
    def _tap_semantic(self, x: int, y: int):
        """Tap by AX-tree element text when the tree covers (x,y); else coords.

        Mirrors agent-device's `find \"Sign In\" click` / `press @e2`: the agent
        (or the executor, here) refers to elements semantically. Falls back to
        raw tap_screen for surfaces the AX tree can't see (games, Flutter/RN
        Canvas, pictures-with-text).
        """
        try:
            elements = self.mcp.get_ui_elements(visible_only=True, limit=120)
        except Exception:
            elements = []
        hit = self._element_at(elements, x, y)
        if hit:
            text = (hit.get("text") or hit.get("label") or "").strip()
            if text:
                if "AUTOGLM_DEBUG" in os.environ:
                    print(f"[semantic] tap_element('{text}') @ ({x},{y})", file=sys.stderr)
                try:
                    self.mcp.tap_element(text=text)
                    return
                except Exception:
                    pass
        if "AUTOGLM_DEBUG" in os.environ:
            print(f"[semantic] fallback tap({x},{y}) no AX element", file=sys.stderr)
        self.mcp.tap(x, y)  # fallback: raw coordinates

    @staticmethod
    def _element_at(elements, x, y):
        """Smallest element whose rect contains (x,y), or None."""
        best, best_area = None, None
        for e in elements:
            r = e.get("rect") or [0, 0, 0, 0]
            try:
                ex, ey, ew, eh = int(r[0]), int(r[1]), int(r[2]), int(r[3])
            except (TypeError, ValueError, IndexError):
                continue
            if ex <= x <= ex + ew and ey <= y <= ey + eh:
                area = ew * eh
                if best_area is None or area < best_area:
                    best, best_area = e, area
        return best
