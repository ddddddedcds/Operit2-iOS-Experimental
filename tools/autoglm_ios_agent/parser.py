"""Parse AutoGLM-Phone model output into an action dict.

Replicates Open-AutoGLM's phone_agent/actions/handler.parse_action:
- The model may wrap the action in <think:6124c78e>...</think> + <answer>...</answer>,
  but in practice it often emits free-form Chinese reasoning followed by a
  single `do(...)` / `finish(...)` call line. We must find that call ANYWHERE
  in the text, not require it at the start or wrapped in tags.
- The action is a Python-call-like string: do(action="Tap", element=[500,100]).
- We safely evaluate the kwargs with ast (no eval of arbitrary code).
- finish(message="...") ends the task.

Coordinates in element/start/end are 0-1000 NORMALIZED, not pixels.
"""

import ast
import re


def _extract_answer(raw: str) -> str:
    m = re.search(r"<answer>(.*?)</answer>", raw, re.S)
    if m:
        return m.group(1).strip()
    return raw.strip()


def _extract_call(response: str) -> str | None:
    """Find the first `do(...)` or `finish(...)` call anywhere in the text and
    return the balanced-parenthesis substring. Returns None if not found."""
    for name in ("do", "finish"):
        idx = response.find(name + "(")
        if idx == -1:
            continue
        paren = response.index("(", idx)
        depth = 0
        i = paren
        while i < len(response):
            ch = response[i]
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    return response[idx : i + 1]
            i += 1
    return None


def parse_action(response: str) -> dict:
    response = response.strip()
    call = _extract_call(response)
    if not call:
        raise ValueError(f"no action call found in: {response[:80]}")
    try:
        tree = ast.parse(call, mode="eval")
        if not isinstance(tree.body, ast.Call):
            raise ValueError("expected a function call")
        call_node = tree.body
        fname = call_node.func.id  # "do" or "finish"
        action = {"_metadata": fname}
        for kw in call_node.keywords:
            key = kw.arg
            value = ast.literal_eval(kw.value)
            action[key] = value
        return action
    except Exception as e:
        # Fallback for Type actions whose text may contain stray quotes/brackets:
        # extract the text= value heuristically.
        if call.startswith('do(action="Type') or call.startswith("do(action='Type"):
            text = call.split("text=", 1)[1]
            if text and text[0] in ('"', "'"):
                q = text[0]
                end = text.find(q, 1)
                if end != -1:
                    return {"_metadata": "do", "action": "Type", "text": text[1:end]}
        raise ValueError(f"failed to parse action: {e} | call={call[:80]}")


def split_think(raw: str) -> tuple[str, str]:
    """Return (thinking, answer_text) from raw model content."""
    think = ""
    m = re.search(r"<think>(.*?)</think>", raw, re.S)
    if m:
        think = m.group(1).strip()
    answer = _extract_answer(raw)
    return think, answer
