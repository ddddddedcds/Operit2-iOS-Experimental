"""The agent loop: screenshot -> AutoGLM -> parse -> execute -> repeat.

Mirrors Open-AutoGLM's IOSPhoneAgent._execute_step, but the "hands" are
ios-mcp instead of WebDriverAgent, and it runs on a Mac driving the real
jailbroken iPhone over the LAN.

Context management (solves the 20K window): each step we send the screenshot
image, but after the model replies we strip the image from the stored user
message, keeping only the text. So history is text-only and cheap.
"""

import time

from mcp_client import IosMcpClient
from planner import AutoGlmClient
from parser import parse_action, split_think
from executor import Executor
from prompt_zh import build_system_prompt


class AutoGlmIosAgent:
    def __init__(
        self,
        api_key: str,
        mcp_url: str = "http://192.168.1.21:8090/mcp",
        base_url: str = "https://open.bigmodel.cn/api/paas/v4",
        model: str = "autoglm-phone",
        max_steps: int = 30,
    ):
        self.mcp = IosMcpClient(mcp_url)
        self.planner = AutoGlmClient(api_key, base_url, model)
        self.max_steps = max_steps
        self.system_prompt = build_system_prompt()
        self._last_sig = None
        self._dup = 0

        # screen size (for 0-1000 -> px conversion)
        info = self.mcp.get_screen_info()
        self.w = int(info.get("width") or 1170)
        self.h = int(info.get("height") or 2532)
        if not info.get("width"):
            print(f"[warn] get_screen_info did not return size; using default {self.w}x{self.h}")

        # build dynamic name->bundle_id map from installed apps
        self.bundle_map = self._build_bundle_map()
        print(f"[init] screen {self.w}x{self.h}, {len(self.bundle_map)} apps mapped")

    def _build_bundle_map(self) -> dict:
        out = {}
        try:
            for a in self.mcp.list_apps():
                name = (a.get("name") or "").strip().lower()
                bid = a.get("bundle_id") or ""
                if name and bid:
                    out[name] = bid
        except Exception as e:
            print(f"[warn] list_apps failed: {e}")
        return out

    def _ensure_unlocked(self):
        """If the device is locked, wake it once; if it stays locked (a passcode
        is needed), pause for the human to unlock manually. Critically: we do
        NOT force the device back to home on every step — wake_and_home == wake
        + go-home, and doing that each step destroys agent progress (the model
        would never see the app it just launched)."""
        try:
            info = self.mcp.get_screen_info()
            if info.get("locked") is not True:
                return
            print("[lock] device appears locked -> wake_and_home")
            self.mcp.wake_and_home()
            time.sleep(2)
            if self.mcp.get_screen_info().get("locked") is True:
                print("[lock] still locked after wake_and_home.")
                print("       请手动解锁设备（密码/面容），解锁后回车继续；或 Ctrl-C 结束。")
                try:
                    input("       (unlocked? press Enter) ")
                except (EOFError, KeyboardInterrupt):
                    pass
        except Exception as e:
            print(f"[warn] _ensure_unlocked error: {e}")

    def run(self, task: str) -> str:
        context = [self.planner.system_msg(self.system_prompt)]
        step = 0
        while step < self.max_steps:
            step += 1
            self._ensure_unlocked()

            # capture screen
            b64 = self.mcp.screenshot_b64()
            front = self.mcp.get_frontmost_app()
            screen_info = f"** Screen Info **\n当前前台应用: {front.get('name','?')} ({front.get('bundle_id','?')})"

            if step == 1:
                text = f"{task}\n\n{screen_info}"
            else:
                text = screen_info

            user_msg = self.planner.user_msg_with_image(text, b64)
            context.append(user_msg)

            # model
            try:
                raw = self.planner.complete(context)
            except Exception as e:
                print(f"[error] model call failed: {e}")
                return f"model error: {e}"

            think, answer = split_think(raw)
            try:
                action = parse_action(raw)
            except ValueError:
                action = {"_metadata": "finish", "message": raw}

            # strip image from stored history (keep text only)
            context[-1] = self.planner.user_msg_text(text)
            context.append(self.planner.assistant_msg(f"<think>{think}</think><answer>{answer}</answer>"))

            print(f"\n{'='*50}\n💭 step {step}:\n{think}\n{'='*50}\n🎯 action:\n{action}")

            if action.get("_metadata") == "finish":
                msg = action.get("message", "")
                print(f"\n🎉 finished: {msg}")
                return msg

            # loop guard: same non-finish action 3x in a row => bail (cheap
            # protection against the model flailing on a screen it can't read)
            import json as _json

            sig = _json.dumps(action, sort_keys=True, ensure_ascii=False)
            if sig == self._last_sig:
                self._dup += 1
            else:
                self._dup = 0
                self._last_sig = sig
            if self._dup >= 3:
                print("\n[guard] 连续 3 次相同动作，疑似卡死，停止。请检查设备或换个说法。")
                return "stuck: repeated identical action"

            executor = Executor(self.mcp, self.w, self.h, self.bundle_map)
            res = executor.execute(action)
            print(f"   -> {res}")
            if res.get("should_finish"):
                return res.get("message", "stopped")
            # give the UI a moment to settle
            time.sleep(1.5)
        return "max steps reached"
