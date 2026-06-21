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
import uuid
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


def json_dumps(obj: object) -> bytes:
    return json.dumps(obj, separators=(",", ":")).encode("utf-8")


def join_upstream_url(base_url: str, request_path: str) -> str:
    path = "/" + request_path.lstrip("/")
    if base_url.endswith("/v1") and path.startswith("/v1/"):
        path = path[len("/v1") :]
    return f"{base_url}{path}"


def translate_claude_request(body: dict) -> tuple[str, dict, dict]:
    """Translate an Anthropic Messages request into AMD Claude gateway format."""
    model = body.get("model") or CLAUDE_DEFAULT_MODEL
    url = f"{AMD_LLM_BASE_URL}{CLAUDE_ENDPOINT.format(model=model)}"
    headers = {
        "Content-Type": "application/json",
        "Ocp-Apim-Subscription-Key": AMD_LLM_API_KEY,
    }

    messages = []
    system = body.get("system")
    if system:
        if isinstance(system, str):
            messages.append({"role": "system", "content": system})
        elif isinstance(system, list):
            text_parts = []
            for block in system:
                if isinstance(block, dict) and block.get("type") == "text":
                    text_parts.append(block.get("text", ""))
                elif isinstance(block, str):
                    text_parts.append(block)
            if text_parts:
                messages.append({"role": "system", "content": "\n".join(text_parts)})

    for msg in body.get("messages", []):
        content = msg.get("content", "")
        if isinstance(content, list):
            text_parts = []
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text":
                    text_parts.append(block.get("text", ""))
                elif isinstance(block, str):
                    text_parts.append(block)
            content = "\n".join(text_parts)
        messages.append({"role": msg["role"], "content": content})

    amd_body: dict = {"messages": messages}
    for key in ("max_tokens", "temperature", "top_p", "stop"):
        if key in body:
            amd_body[key] = body[key]

    return url, headers, amd_body


def translate_claude_response(amd_data: dict, model: str) -> dict:
    """Wrap common AMD gateway response shapes into Anthropic Messages format."""
    text = ""

    amd_content = amd_data.get("content", [])
    if amd_content and isinstance(amd_content, list):
        first = amd_content[0]
        if isinstance(first, dict):
            text = first.get("text", "")
        elif isinstance(first, str):
            text = first

    if not text and amd_data.get("choices"):
        choice = amd_data["choices"][0]
        message = choice.get("message", {})
        content = message.get("content", "")
        text = content if isinstance(content, str) else json.dumps(content)

    return {
        "id": f"msg_{uuid.uuid4().hex[:24]}",
        "type": "message",
        "role": "assistant",
        "content": [{"type": "text", "text": text}],
        "model": model,
        "stop_reason": "end_turn",
        "stop_sequence": None,
        "usage": {"input_tokens": 0, "output_tokens": 0},
    }


def build_sse_events(response_dict: dict) -> str:
    msg_id = response_dict["id"]
    model = response_dict["model"]
    text = response_dict["content"][0]["text"]
    events = []

    events.append(
        "event: message_start\ndata: "
        + json.dumps(
            {
                "type": "message_start",
                "message": {
                    "id": msg_id,
                    "type": "message",
                    "role": "assistant",
                    "content": [],
                    "model": model,
                    "stop_reason": None,
                    "stop_sequence": None,
                    "usage": {"input_tokens": 0, "output_tokens": 0},
                },
            }
        )
        + "\n"
    )
    events.append(
        "event: content_block_start\ndata: "
        + json.dumps(
            {
                "type": "content_block_start",
                "index": 0,
                "content_block": {"type": "text", "text": ""},
            }
        )
        + "\n"
    )
    events.append('event: ping\ndata: {"type":"ping"}\n')
    events.append(
        "event: content_block_delta\ndata: "
        + json.dumps(
            {
                "type": "content_block_delta",
                "index": 0,
                "delta": {"type": "text_delta", "text": text},
            }
        )
        + "\n"
    )
    events.append('event: content_block_stop\ndata: {"type":"content_block_stop","index":0}\n')
    events.append(
        "event: message_delta\ndata: "
        + json.dumps(
            {
                "type": "message_delta",
                "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                "usage": {"output_tokens": 0},
            }
        )
        + "\n"
    )
    events.append('event: message_stop\ndata: {"type":"message_stop"}\n')

    return "\n".join(events)


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

        self.send_response(response.status_code)
        for key, value in response.headers.items():
            if key.lower() not in HOP_BY_HOP_HEADERS:
                self.send_header(key, value)
        self.end_headers()

        for chunk in response.iter_content(chunk_size=65536):
            if chunk:
                self.wfile.write(chunk)
                self.wfile.flush()

    def _proxy_claude(self):
        path = urlparse(self.path).path
        if path != "/v1/messages":
            self._send_error(404, f"Not found in claude mode: {self.path}")
            return

        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw)
        except json.JSONDecodeError:
            self._send_error(400, "Invalid JSON in request body")
            return

        is_streaming = body.get("stream", False)
        model = body.get("model") or CLAUDE_DEFAULT_MODEL
        url, headers, amd_body = translate_claude_request(body)
        sys.stderr.write(f"[claude:{PROXY_PORT}] -> {url} model={model} stream={is_streaming}\n")

        try:
            response = requests.post(url, json=amd_body, headers=headers, timeout=AMD_TIMEOUT)
        except requests.exceptions.Timeout:
            self._send_error(502, "AMD Claude gateway timed out")
            return
        except requests.exceptions.ConnectionError as exc:
            self._send_error(502, f"Cannot reach AMD Claude gateway: {exc}")
            return

        if response.status_code != 200:
            try:
                detail = response.json().get("message", response.text[:500])
            except Exception:
                detail = response.text[:500]
            sys.stderr.write(f"[claude:{PROXY_PORT}] AMD error {response.status_code}: {detail}\n")
            self._send_error(response.status_code, f"AMD Claude gateway error: {detail}")
            return

        try:
            amd_data = response.json()
        except Exception:
            self._send_error(502, f"AMD returned non-JSON: {response.text[:500]}")
            return

        response_dict = translate_claude_response(amd_data, model)
        if is_streaming:
            sse_body = build_sse_events(response_dict).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(sse_body)
        else:
            self._send_json(200, response_dict)

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
