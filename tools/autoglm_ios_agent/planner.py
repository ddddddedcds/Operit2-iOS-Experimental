"""OpenAI-compatible client for the AutoGLM-Phone model.

Endpoint: POST {base_url}/chat/completions
Auth: Bearer <api_key>
Model: autoglm-phone (or autoglm-phone-9b)

We send each step as a user message containing BOTH text (task / step info)
and the current screenshot as a base64 JPEG image_url. The model returns
text of the form:  <think>...</think>\n<answer>do(...)</answer>
The parser module splits/parses that.
"""

import json
import os
import ssl
import urllib.request


def _make_ssl_context() -> ssl.SSLContext:
    """Build an SSL context with a usable CA bundle.

    macOS ships Python without trusted CAs by default, so urllib's default
    context fails with CERTIFICATE_VERIFY_FAILED. We load certifi's bundle
    when present, then fall back to common system CA files so the script
    works regardless of which `python3` the user happens to invoke.
    """
    ctx = ssl.create_default_context()
    candidates = []
    try:
        import certifi

        candidates.append(certifi.where())
    except Exception:
        pass
    candidates += [
        "/private/etc/ssl/cert.pem",
        "/usr/local/etc/openssl@3/cert.pem",
        "/etc/ssl/certs/ca-certificates.crt",
    ]
    for c in candidates:
        if c and os.path.exists(c):
            try:
                ctx.load_verify_locations(cafile=c)
                return ctx
            except Exception:
                continue
    return ctx


_SSL_CONTEXT = _make_ssl_context()


class AutoGlmClient:
    def __init__(
        self,
        api_key: str,
        base_url: str = "https://open.bigmodel.cn/api/paas/v4",
        model: str = "autoglm-phone",
        timeout: int = 120,
    ):
        if not api_key:
            raise ValueError("AutoGLM API key is required (set AUTOGLM_API_KEY)")
        self.api_key = api_key
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.timeout = timeout

    def _post(self, payload: dict) -> dict:
        body = json.dumps(payload).encode()
        req = urllib.request.Request(
            self.base_url + "/chat/completions",
            data=body,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {self.api_key}",
                "Accept": "application/json",
            },
        )
        with urllib.request.urlopen(req, timeout=self.timeout, context=_SSL_CONTEXT) as r:
            return json.loads(r.read().decode())

    def complete(self, messages: list) -> str:
        """Return raw assistant content string."""
        resp = self._post(
            {
                "model": self.model,
                "messages": messages,
                "temperature": 0.0,
                "max_tokens": 2048,
                "stream": False,
            }
        )
        return resp["choices"][0]["message"]["content"]

    # ---- message builders ----
    @staticmethod
    def system_msg(text: str) -> dict:
        return {"role": "system", "content": text}

    @staticmethod
    def user_msg_text(text: str) -> dict:
        return {"role": "user", "content": text}

    @staticmethod
    def user_msg_with_image(text: str, b64_jpeg: str) -> dict:
        return {
            "role": "user",
            "content": [
                {"type": "text", "text": text},
                {
                    "type": "image_url",
                    "image_url": {"url": f"data:image/jpeg;base64,{b64_jpeg}"},
                },
            ],
        }

    @staticmethod
    def assistant_msg(text: str) -> dict:
        return {"role": "assistant", "content": text}
