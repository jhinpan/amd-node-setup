#!/usr/bin/env python3
"""AMD LLM Gateway Proxy for Claude Code.

Translates Anthropic Messages API requests into AMD corporate gateway format
and returns responses in Anthropic format, including simulated SSE streaming.

Usage:
    export AMD_LLM_API_KEY="your-subscription-key"
    python3 amd_proxy.py

Then point Claude Code at it:
    export ANTHROPIC_BASE_URL=http://localhost:8082
    export ANTHROPIC_API_KEY=not-used
    claude
"""

import json
import os
import sys
import uuid
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

import requests

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
AMD_LLM_API_KEY = os.environ.get("AMD_LLM_API_KEY", "")
AMD_LLM_BASE_URL = os.environ.get("AMD_LLM_BASE_URL", "https://llm-api.amd.com")
PROXY_HOST = os.environ.get("PROXY_HOST", "127.0.0.1")
PROXY_PORT = int(os.environ.get("PROXY_PORT", "8082"))
AMD_TIMEOUT = int(os.environ.get("AMD_TIMEOUT", "120"))

CLAUDE_ENDPOINT = "/claude3/{model}/chat/completions"


# ---------------------------------------------------------------------------
# Translation helpers
# ---------------------------------------------------------------------------

def translate_request(body: dict) -> tuple[str, dict, dict]:
    """Translate an Anthropic Messages API request body into AMD gateway format.

    Returns (url, headers, amd_body).
    """
    model = body.get("model", "claude-sonnet-4-6")
    url = f"{AMD_LLM_BASE_URL}{CLAUDE_ENDPOINT.format(model=model)}"

    headers = {
        "Content-Type": "application/json",
        "Ocp-Apim-Subscription-Key": AMD_LLM_API_KEY,
    }

    messages = []

    # Handle system prompt — string or list of content blocks
    system = body.get("system")
    if system:
        if isinstance(system, str):
            messages.append({"role": "system", "content": system})
        elif isinstance(system, list):
            text_parts = []
            for block in system:
                if isinstance(block, dict) and block.get("type") == "text":
                    text_parts.append(block["text"])
                elif isinstance(block, str):
                    text_parts.append(block)
            if text_parts:
                messages.append({"role": "system", "content": "\n".join(text_parts)})

    # Flatten message content to plain strings for the AMD gateway
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

    # Pass through supported fields
    if "max_tokens" in body:
        amd_body["max_tokens"] = body["max_tokens"]
    if "temperature" in body:
        amd_body["temperature"] = body["temperature"]

    return url, headers, amd_body


def translate_response(amd_data: dict, model: str) -> dict:
    """Wrap an AMD gateway response into Anthropic Messages API format."""
    # AMD returns: {"content": [{"text": "..."}]}
    amd_content = amd_data.get("content", [])
    text = ""
    if amd_content and isinstance(amd_content, list):
        text = amd_content[0].get("text", "")

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
    """Generate a complete SSE event stream string for a buffered response."""
    msg_id = response_dict["id"]
    model = response_dict["model"]
    text = response_dict["content"][0]["text"]

    events = []

    # message_start
    msg_start = {
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
    events.append(f"event: message_start\ndata: {json.dumps(msg_start)}\n")

    # content_block_start
    cb_start = {
        "type": "content_block_start",
        "index": 0,
        "content_block": {"type": "text", "text": ""},
    }
    events.append(f"event: content_block_start\ndata: {json.dumps(cb_start)}\n")

    # ping
    events.append(f"event: ping\ndata: {{\"type\": \"ping\"}}\n")

    # content_block_delta — deliver the full text in one delta
    cb_delta = {
        "type": "content_block_delta",
        "index": 0,
        "delta": {"type": "text_delta", "text": text},
    }
    events.append(f"event: content_block_delta\ndata: {json.dumps(cb_delta)}\n")

    # content_block_stop
    cb_stop = {"type": "content_block_stop", "index": 0}
    events.append(f"event: content_block_stop\ndata: {json.dumps(cb_stop)}\n")

    # message_delta
    msg_delta = {
        "type": "message_delta",
        "delta": {"stop_reason": "end_turn", "stop_sequence": None},
        "usage": {"output_tokens": 0},
    }
    events.append(f"event: message_delta\ndata: {json.dumps(msg_delta)}\n")

    # message_stop
    events.append(f"event: message_stop\ndata: {{\"type\": \"message_stop\"}}\n")

    return "\n".join(events)


# ---------------------------------------------------------------------------
# HTTP Handler
# ---------------------------------------------------------------------------

class ProxyHandler(BaseHTTPRequestHandler):
    """Handle incoming Anthropic-format requests and proxy to AMD gateway."""

    def log_message(self, format, *args):
        """Prefix log lines with [proxy]."""
        sys.stderr.write(f"[proxy] {args[0]}\n")

    def _send_json(self, code: int, obj: dict):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_error(self, code: int, message: str):
        self._send_json(code, {
            "type": "error",
            "error": {"type": "api_error", "message": message},
        })

    def do_POST(self):
        path = urlparse(self.path).path
        if path != "/v1/messages":
            self._send_error(404, f"Not found: {self.path}")
            return

        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw)
        except json.JSONDecodeError:
            self._send_error(400, "Invalid JSON in request body")
            return

        is_streaming = body.get("stream", False)
        model = body.get("model", "claude-sonnet-4-6")

        url, headers, amd_body = translate_request(body)
        sys.stderr.write(f"[proxy] -> {url}  model={model}  stream={is_streaming}\n")

        try:
            r = requests.post(url, json=amd_body, headers=headers, timeout=AMD_TIMEOUT)
        except requests.exceptions.Timeout:
            self._send_error(502, "AMD gateway timed out")
            return
        except requests.exceptions.ConnectionError as exc:
            self._send_error(502, f"Cannot reach AMD gateway: {exc}")
            return

        if r.status_code != 200:
            try:
                detail = r.json().get("message", r.text[:500])
            except Exception:
                detail = r.text[:500]
            sys.stderr.write(f"[proxy] AMD error {r.status_code}: {detail}\n")
            self._send_error(r.status_code, f"AMD gateway error: {detail}")
            return

        try:
            amd_data = r.json()
        except Exception:
            self._send_error(502, f"AMD returned non-JSON: {r.text[:500]}")
            return

        sys.stderr.write(f"[proxy] AMD response OK for model={model}\n")
        response_dict = translate_response(amd_data, model)

        if is_streaming:
            sse_body = build_sse_events(response_dict).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(sse_body)
        else:
            self._send_json(200, response_dict)

    def do_GET(self):
        path = urlparse(self.path).path

        if path == "/health":
            self._send_json(200, {"ok": True, "upstream": AMD_LLM_BASE_URL})
            return

        if path == "/v1/models":
            models = os.environ.get(
                "AMD_PROXY_MODELS",
                "claude-opus-4-6,claude-sonnet-4-6,claude-opus-4-5,claude-sonnet-4-5",
            )
            self._send_json(200, {
                "object": "list",
                "data": [
                    {"id": model.strip(), "object": "model"}
                    for model in models.split(",")
                    if model.strip()
                ],
            })
            return

        self._send_error(404, f"Not found: {self.path}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    if not AMD_LLM_API_KEY:
        print("Error: AMD_LLM_API_KEY environment variable is required.", file=sys.stderr)
        print("  export AMD_LLM_API_KEY='your-subscription-key'", file=sys.stderr)
        sys.exit(1)

    server = HTTPServer((PROXY_HOST, PROXY_PORT), ProxyHandler)
    print(f"AMD LLM Gateway Proxy listening on http://{PROXY_HOST}:{PROXY_PORT}")
    print(f"  Gateway: {AMD_LLM_BASE_URL}/claude3/...")
    print("  API key: loaded from AMD_LLM_API_KEY")
    print()
    print("Point Claude Code at this proxy:")
    print(f"  export ANTHROPIC_BASE_URL=http://localhost:{PROXY_PORT}")
    print("  export ANTHROPIC_API_KEY=not-used")
    print("  claude")
    print()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.server_close()


if __name__ == "__main__":
    main()
