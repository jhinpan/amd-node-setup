#!/usr/bin/env python3
"""Container-local AMD LLM Gateway proxy.

The same script runs in two modes:

* ``PROXY_MODE=claude`` translates Anthropic Messages API requests from
  Claude Code into AMD's Claude gateway route.
* ``PROXY_MODE=openai`` forwards OpenAI-compatible requests from Codex to an
  OpenAI-compatible gateway base URL.
"""

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

import requests


AMD_LLM_API_KEY = os.environ.get("AMD_LLM_API_KEY", "")
AMD_LLM_BASE_URL = os.environ.get("AMD_LLM_BASE_URL", "https://llm-api.amd.com").rstrip("/")
PROXY_HOST = os.environ.get("PROXY_HOST", "127.0.0.1")
PROXY_PORT = int(os.environ.get("PROXY_PORT", "8082"))
PROXY_MODE = os.environ.get("PROXY_MODE", "claude").lower()
AMD_TIMEOUT = int(os.environ.get("AMD_TIMEOUT", "120"))

CLAUDE_DEFAULT_MODEL = os.environ.get("CLAUDE_DEFAULT_MODEL", "claude-opus-4-8")
CLAUDE_ENDPOINT = os.environ.get(
    "AMD_CLAUDE_ENDPOINT_TEMPLATE",
    "/claude3/{model}/chat/completions",
)
ALLOWED_CLAUDE_MODELS = {
    m.strip()
    for m in os.environ.get("AMD_PROXY_MODELS", CLAUDE_DEFAULT_MODEL).split(",")
    if m.strip()
}

CODEX_DEFAULT_MODEL = os.environ.get("CODEX_DEFAULT_MODEL", "gpt-5.5")
CODEX_REASONING_EFFORT = os.environ.get("CODEX_REASONING_EFFORT", "xhigh")
OPENAI_UPSTREAM_BASE_URL = os.environ.get(
    "OPENAI_UPSTREAM_BASE_URL",
    os.environ.get("LLM_GATEWAY_OPENAI_BASE_URL", f"{AMD_LLM_BASE_URL}/v1"),
).rstrip("/")


HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
}

# requests' iter_content(decode_content=True) transparently decompresses the
# upstream body, so the upstream Content-Encoding/Content-Length headers no
# longer describe the bytes we relay. Forwarding Content-Encoding makes the
# client try to gunzip/inflate already-decompressed plaintext, which surfaces
# as a ZlibError/decompression error; forwarding the stale Content-Length can
# truncate or hang the response. Drop both and let the framing be implicit.
SKIP_RESPONSE_HEADERS = {"content-length", "content-encoding"}


def json_dumps(obj: object) -> bytes:
    return json.dumps(obj, separators=(",", ":")).encode("utf-8")


def join_upstream_url(base_url: str, request_path: str) -> str:
    path = "/" + request_path.lstrip("/")
    if base_url.endswith(("/v1", "/openai")) and path.startswith("/v1/"):
        path = path[len("/v1") :]
    return f"{base_url}{path}"


def patch_openai_request(path: str, raw_body: bytes) -> tuple[bytes, str]:
    """Set default Codex model/effort when the client omits them."""
    if not raw_body:
        return raw_body, CODEX_DEFAULT_MODEL

    try:
        body = json.loads(raw_body)
    except json.JSONDecodeError:
        return raw_body, CODEX_DEFAULT_MODEL

    if not isinstance(body, dict):
        return raw_body, CODEX_DEFAULT_MODEL

    model = body.get("model") or CODEX_DEFAULT_MODEL
    body["model"] = model

    if path.endswith("/responses"):
        reasoning = body.get("reasoning")
        if not isinstance(reasoning, dict):
            reasoning = {}
        reasoning.setdefault("effort", CODEX_REASONING_EFFORT)
        body["reasoning"] = reasoning

    return json_dumps(body), model


class ProxyHandler(BaseHTTPRequestHandler):
    server_version = "amd-node-setup-proxy/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write(f"[{PROXY_MODE}:{PROXY_PORT}] {fmt % args}\n")

    def _send_json(self, code: int, obj: dict):
        body = json_dumps(obj)
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_error(self, code: int, message: str):
        self._send_json(
            code,
            {"type": "error", "error": {"type": "api_error", "message": message}},
        )

    def _relay_response(self, response):
        """Stream an upstream response to the client.

        ``response.iter_content`` already decodes the upstream content-encoding,
        so Content-Encoding/Content-Length are dropped to avoid client-side
        decompression errors and stale framing.
        """
        self.send_response(response.status_code)
        for key, value in response.headers.items():
            lower_key = key.lower()
            if lower_key in HOP_BY_HOP_HEADERS or lower_key in SKIP_RESPONSE_HEADERS:
                continue
            self.send_header(key, value)
        self.end_headers()

        for chunk in response.iter_content(chunk_size=65536):
            if chunk:
                self.wfile.write(chunk)
                self.wfile.flush()

    def _send_openai_models(self):
        models = os.environ.get("AMD_PROXY_MODELS", CODEX_DEFAULT_MODEL)
        self._send_json(
            200,
            {
                "object": "list",
                "data": [
                    {"id": model.strip(), "object": "model"}
                    for model in models.split(",")
                    if model.strip()
                ],
            },
        )

    def _proxy_openai(self):
        path = urlparse(self.path).path
        if path in {"/v1/models", "/models"} and self.command == "GET":
            self._send_openai_models()
            return

        allowed_paths = (
            "/v1/responses",
            "/responses",
            "/v1/chat/completions",
            "/chat/completions",
        )
        if not path.endswith(allowed_paths):
            self._send_error(404, f"Not found in openai mode: {self.path}")
            return

        length = int(self.headers.get("Content-Length", 0))
        raw_body = self.rfile.read(length) if length else b""
        upstream_body, model = patch_openai_request(path, raw_body)
        upstream_url = join_upstream_url(OPENAI_UPSTREAM_BASE_URL, path)

        headers = {
            "Authorization": f"Bearer {AMD_LLM_API_KEY}",
            "Ocp-Apim-Subscription-Key": AMD_LLM_API_KEY,
            "Content-Type": self.headers.get("Content-Type", "application/json"),
            "Accept": self.headers.get("Accept", "application/json"),
        }

        sys.stderr.write(f"[openai:{PROXY_PORT}] -> {upstream_url} model={model}\n")
        try:
            response = requests.request(
                self.command,
                upstream_url,
                data=upstream_body,
                headers=headers,
                timeout=AMD_TIMEOUT,
                stream=True,
            )
        except requests.exceptions.Timeout:
            self._send_error(502, "OpenAI-compatible upstream timed out")
            return
        except requests.exceptions.ConnectionError as exc:
            self._send_error(502, f"Cannot reach OpenAI-compatible upstream: {exc}")
            return

        self._relay_response(response)

    def _proxy_claude(self):
        path = urlparse(self.path).path
        if path != "/v1/messages":
            self._send_error(404, f"Not found in claude mode: {self.path}")
            return

        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            self._send_error(400, "Invalid JSON in request body")
            return

        # The AMD gateway route speaks the native Anthropic Messages protocol
        # (tools, tool_use/tool_result, thinking and SSE streaming all work), so
        # the request is forwarded verbatim rather than down-converted to an
        # OpenAI shape. The only mutation is pinning the model to one the
        # gateway actually serves; anything else (e.g. Claude Code's background
        # haiku model) would 404 upstream.
        requested_model = body.get("model") or CLAUDE_DEFAULT_MODEL
        model = requested_model if requested_model in ALLOWED_CLAUDE_MODELS else CLAUDE_DEFAULT_MODEL
        body["model"] = model
        upstream_body = json_dumps(body)

        is_streaming = bool(body.get("stream", False))
        url = f"{AMD_LLM_BASE_URL}{CLAUDE_ENDPOINT.format(model=model)}"
        headers = {
            "Content-Type": "application/json",
            "Accept": self.headers.get("Accept", "application/json"),
            "Ocp-Apim-Subscription-Key": AMD_LLM_API_KEY,
        }
        for fwd in ("anthropic-version", "anthropic-beta"):
            value = self.headers.get(fwd)
            if value:
                headers[fwd] = value

        sys.stderr.write(
            f"[claude:{PROXY_PORT}] -> {url} model={model} "
            f"(requested={requested_model}) stream={is_streaming}\n"
        )

        try:
            response = requests.post(
                url,
                data=upstream_body,
                headers=headers,
                timeout=AMD_TIMEOUT,
                stream=True,
            )
        except requests.exceptions.Timeout:
            self._send_error(502, "AMD Claude gateway timed out")
            return
        except requests.exceptions.ConnectionError as exc:
            self._send_error(502, f"Cannot reach AMD Claude gateway: {exc}")
            return

        # Relay the upstream response (SSE stream or JSON) through unchanged.
        self._relay_response(response)

    def do_POST(self):
        if PROXY_MODE == "openai":
            self._proxy_openai()
        elif PROXY_MODE == "claude":
            self._proxy_claude()
        else:
            self._send_error(500, f"Unsupported PROXY_MODE={PROXY_MODE}")

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/health":
            payload = {
                "ok": True,
                "mode": PROXY_MODE,
                "port": PROXY_PORT,
                "gateway": AMD_LLM_BASE_URL,
            }
            if PROXY_MODE == "openai":
                payload["openai_upstream"] = OPENAI_UPSTREAM_BASE_URL
            self._send_json(200, payload)
            return

        if PROXY_MODE == "openai":
            self._proxy_openai()
            return

        if path == "/v1/models":
            models = os.environ.get("AMD_PROXY_MODELS", CLAUDE_DEFAULT_MODEL)
            self._send_json(
                200,
                {
                    "object": "list",
                    "data": [
                        {"id": model.strip(), "object": "model"}
                        for model in models.split(",")
                        if model.strip()
                    ],
                },
            )
            return

        self._send_error(404, f"Not found: {self.path}")


def main():
    if not AMD_LLM_API_KEY:
        print("Error: AMD_LLM_API_KEY environment variable is required.", file=sys.stderr)
        sys.exit(1)

    if PROXY_MODE not in {"claude", "openai"}:
        print("Error: PROXY_MODE must be 'claude' or 'openai'.", file=sys.stderr)
        sys.exit(1)

    server = HTTPServer((PROXY_HOST, PROXY_PORT), ProxyHandler)
    print(f"AMD proxy listening on http://{PROXY_HOST}:{PROXY_PORT}")
    print(f"  mode   : {PROXY_MODE}")
    print(f"  gateway: {AMD_LLM_BASE_URL}")
    if PROXY_MODE == "claude":
        print(f"  model  : {CLAUDE_DEFAULT_MODEL}")
    else:
        print(f"  upstream: {OPENAI_UPSTREAM_BASE_URL}")
        print(f"  model   : {CODEX_DEFAULT_MODEL}")
        print(f"  effort  : {CODEX_REASONING_EFFORT}")
    print()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.server_close()


if __name__ == "__main__":
    main()
