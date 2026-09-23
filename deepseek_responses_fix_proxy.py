#!/usr/bin/env python3
"""
Minimal sanitizing reverse proxy for Codex -> strict Responses upstreams.

Why this exists
---------------
When a side/delegated thread injects a message into another Codex thread
(create_thread, send_message_to_thread, heartbeat/cron automations), Codex
appends a standalone item:

    {"type": "function_call_output", "id": "fco_...", "name": "create_thread",
     "namespace": "codex_app", "output": "<codex_delegation>...</codex_delegation>"}

It has no ``call_id`` (Codex's protocol makes it optional and skips the field
when None), so strict Responses implementations reject the whole request body:

    HTTP 422 Unprocessable Entity: Failed to deserialize the JSON body into the
    target type: input: missing field `call_id`

The bad item stays in the rollout and is replayed on every later turn, which is
why the thread looks permanently dead.

What it repairs on the wire
---------------------------
1. ``function_call_output`` whose ``call_id`` is missing, empty, or does not
   match any ``function_call`` in the same request -> rewritten as a plain
   ``message`` item (role configurable, default ``user``) that keeps the exact
   output text. The injected instruction is preserved instead of dropped.
2. ``function_call`` with no matching output -> a synthetic
   ``function_call_output`` with ``output: "aborted"`` is appended, mirroring
   Codex's own history normalizer.
3. Runs of consecutive call/output items -> all calls first, then all outputs,
   which is the batch order strict upstreams expect.

Everything else is a transparent byte-for-byte relay: headers (including
Authorization), query strings, non-JSON bodies, errors, and SSE streaming.

Requirements
------------
Python 3.11+ (uses ``HTTPResponse.read1`` so SSE chunks are forwarded as they
arrive). No third-party packages.

Quick start
-----------
    python deepseek_responses_fix_proxy.py --listen 127.0.0.1:18787 \
        --upstream https://api.deepseek.com --verbose

Then point Codex at the proxy in ``~/.codex/config.toml``:

    [model_providers.deepseek]
    name = "deepseek"
    base_url = "http://127.0.0.1:18787/"
    wire_api = "responses"
    experimental_bearer_token = "..."   # unchanged: forwarded upstream

Self-check without network:

    python deepseek_responses_fix_proxy.py --selftest
"""

from __future__ import annotations

import argparse
import http.client
import http.server
import json
import shutil
import sys
import urllib.parse
from dataclasses import dataclass, field

__version__ = "1.0.1"

CALL_TYPES = {"function_call"}
OUTPUT_TYPES = {"function_call_output"}
CHAIN_TYPES = CALL_TYPES | OUTPUT_TYPES

# Hop-by-hop headers must not be forwarded (RFC 9110 7.6.1). Since we let
# http.client decode chunked bodies, we also rebuild Content-Length.
HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "proxy-connection",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
    "host",
    "content-length",
}


@dataclass
class RepairStats:
    rewritten_outputs: int = 0
    synthesized_outputs: int = 0
    rewritten_names: list[str] = field(default_factory=list)

    @property
    def changed(self) -> bool:
        return bool(self.rewritten_outputs or self.synthesized_outputs)

    def summary(self) -> str:
        parts = []
        if self.rewritten_outputs:
            names = ",".join(self.rewritten_names[:4]) or "unnamed"
            parts.append(f"rewrote {self.rewritten_outputs} orphan output(s) [{names}]")
        if self.synthesized_outputs:
            parts.append(f"synthesized {self.synthesized_outputs} missing output(s)")
        return "; ".join(parts) if parts else "clean"


def output_to_text(output: object) -> str:
    """Extract readable text from any function_call_output payload shape."""
    if output is None:
        return ""
    if isinstance(output, str):
        return output
    if isinstance(output, dict):
        for key in ("text", "output", "content", "value"):
            value = output.get(key)
            if isinstance(value, str):
                return value
        return json.dumps(output, ensure_ascii=False)
    if isinstance(output, list):
        return "\n".join(part for part in (output_to_text(item) for item in output) if part)
    return str(output)


def _call_id_of(item: object) -> str | None:
    if not isinstance(item, dict):
        return None
    call_id = item.get("call_id")
    return call_id if isinstance(call_id, str) and call_id else None


def _item_label(item: dict) -> str:
    namespace = item.get("namespace")
    name = item.get("name")
    label = ".".join(str(part) for part in (namespace, name) if part)
    return label or str(item.get("id") or "unnamed")


def _normalize_batches(items: list, synth_missing: bool) -> tuple[list, int]:
    """Keep call/output runs in the order strict upstreams accept.

    ``callA, outA, callB, outB`` becomes ``callA, callB, outA, outB`` and any
    call without an output gets an ``aborted`` placeholder, which is also what
    Codex's own ``ensure_call_outputs_present`` does when rebuilding history.
    Only maximal runs made solely of call/output items are touched.
    """
    result: list = []
    synthesized = 0
    index = 0
    total = len(items)
    while index < total:
        item = items[index]
        if not isinstance(item, dict) or item.get("type") not in CHAIN_TYPES:
            result.append(item)
            index += 1
            continue

        calls: list[dict] = []
        outputs: list[dict] = []
        while index < total:
            current = items[index]
            if not isinstance(current, dict) or current.get("type") not in CHAIN_TYPES:
                break
            if current.get("type") in CALL_TYPES:
                calls.append(current)
            else:
                outputs.append(current)
            index += 1

        result.extend(calls)
        result.extend(outputs)
        if synth_missing:
            answered = {_call_id_of(output) for output in outputs}
            for call in calls:
                call_id = _call_id_of(call)
                if call_id and call_id not in answered:
                    result.append(
                        {"type": "function_call_output", "call_id": call_id, "output": "aborted"}
                    )
                    synthesized += 1
    return result, synthesized


def repair_payload(
    payload: dict,
    role: str = "user",
    synth_missing: bool = True,
    normalize_batches: bool = True,
) -> RepairStats:
    """Repair ``payload["input"]`` in place. Returns what was changed."""
    stats = RepairStats()
    items = payload.get("input")
    if not isinstance(items, list):
        return stats

    known_calls: set[str] = set()
    for item in items:
        if isinstance(item, dict) and item.get("type") in CALL_TYPES:
            call_id = _call_id_of(item)
            if call_id:
                known_calls.add(call_id)

    rewritten: list = []
    for item in items:
        if isinstance(item, dict) and item.get("type") in OUTPUT_TYPES:
            call_id = _call_id_of(item)
            if not call_id or call_id not in known_calls:
                text = output_to_text(item.get("output")) or json.dumps(item, ensure_ascii=False)
                rewritten.append(
                    {
                        "type": "message",
                        "role": role,
                        "content": [{"type": "input_text", "text": text}],
                    }
                )
                stats.rewritten_outputs += 1
                stats.rewritten_names.append(_item_label(item))
                continue
        rewritten.append(item)

    if normalize_batches or synth_missing:
        rewritten, stats.synthesized_outputs = _normalize_batches(rewritten, synth_missing)

    payload["input"] = rewritten
    return stats


class ProxyServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(
        self,
        server_address: tuple[str, int],
        upstream: urllib.parse.SplitResult,
        *,
        role: str = "user",
        synth_missing: bool = True,
        normalize_batches: bool = True,
        timeout: float = 300.0,
        verbose: bool = False,
    ) -> None:
        super().__init__(server_address, ProxyHandler)
        self.upstream = upstream
        self.role = role
        self.synth_missing = synth_missing
        self.normalize_batches = normalize_batches
        self.timeout = timeout
        self.verbose = verbose

    def connect(self) -> http.client.HTTPConnection:
        host = self.upstream.hostname or "127.0.0.1"
        if self.upstream.scheme == "https":
            return http.client.HTTPSConnection(host, self.upstream.port or 443, timeout=self.timeout)
        return http.client.HTTPConnection(host, self.upstream.port or 80, timeout=self.timeout)

    def upstream_path(self, incoming_path: str) -> str:
        prefix = self.upstream.path.rstrip("/")
        return f"{prefix}{incoming_path}" or "/"


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = f"codex-responses-fix/{__version__}"

    def log_message(self, fmt: str, *args: object) -> None:
        if self.server.verbose:  # type: ignore[attr-defined]
            super().log_message(fmt, *args)

    def log_error(self, fmt: str, *args: object) -> None:
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def do_GET(self) -> None:  # noqa: N802
        self._forward("GET")

    def do_POST(self) -> None:  # noqa: N802
        self._forward("POST")

    def do_PUT(self) -> None:  # noqa: N802
        self._forward("PUT")

    def do_PATCH(self) -> None:  # noqa: N802
        self._forward("PATCH")

    def do_DELETE(self) -> None:  # noqa: N802
        self._forward("DELETE")

    def do_OPTIONS(self) -> None:  # noqa: N802
        self._forward("OPTIONS")

    def do_HEAD(self) -> None:  # noqa: N802
        self._forward("HEAD")

    def _read_body(self) -> bytes:
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            chunks: list[bytes] = []
            while True:
                line = self.rfile.readline().strip()
                size = int(line.split(b";", 1)[0] or b"0", 16)
                if size == 0:
                    self.rfile.readline()
                    break
                chunks.append(self.rfile.read(size))
                self.rfile.read(2)
            return b"".join(chunks)
        raw_length = self.headers.get("Content-Length")
        if not raw_length:
            return b""
        return self.rfile.read(int(raw_length))

    def _repair(self, body: bytes) -> tuple[bytes, RepairStats | None]:
        content_type = (self.headers.get("Content-Type") or "").lower()
        if "json" not in content_type or not body:
            return body, None
        try:
            payload = json.loads(body)
        except (json.JSONDecodeError, UnicodeDecodeError):
            return body, None
        if not isinstance(payload, dict) or not isinstance(payload.get("input"), list):
            return body, None

        server: ProxyServer = self.server  # type: ignore[assignment]
        stats = repair_payload(
            payload,
            role=server.role,
            synth_missing=server.synth_missing,
            normalize_batches=server.normalize_batches,
        )
        if not stats.changed:
            return body, stats
        repaired = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        return repaired, stats

    def _forward(self, method: str) -> None:
        server: ProxyServer = self.server  # type: ignore[assignment]
        self._headers_sent = False
        try:
            body = self._read_body() if method in {"POST", "PUT", "PATCH"} else b""
            body, stats = self._repair(body)

            headers: dict[str, str] = {}
            for key, value in self.headers.items():
                if key.lower() not in HOP_BY_HOP:
                    headers[key] = value
            headers["Connection"] = "close"
            if method in {"POST", "PUT", "PATCH"}:
                headers["Content-Length"] = str(len(body))

            connection = server.connect()
            try:
                target = server.upstream_path(self.path)
                payload = body if method in {"POST", "PUT", "PATCH"} else None
                connection.request(method, target, body=payload, headers=headers)
                response = connection.getresponse()

                bodyless = self.command == "HEAD" or response.status in (204, 304)
                self.send_response(response.status, response.reason)
                for key, value in response.getheaders():
                    if key.lower() in HOP_BY_HOP:
                        continue
                    self.send_header(key, value)
                # http.client already decoded the upstream framing, so we
                # re-frame the downstream body ourselves. Chunked transfer
                # keeps SSE flowing event-by-event for clients that dislike
                # close-delimited responses.
                if not bodyless:
                    self.send_header("Transfer-Encoding", "chunked")
                self.send_header("Connection", "close")
                self.end_headers()
                self._headers_sent = True
                streamed = self._relay(response, bodyless=bodyless)
            finally:
                connection.close()
                self.close_connection = True

            if server.verbose:
                note = stats.summary() if stats is not None else "passthrough"
                sys.stderr.write(
                    f"{method} {self.path} -> {response.status} ({streamed} bytes, {note})\n"
                )
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            # The client went away (cancelled turn, closed tab, short-lived
            # probe). This is normal and must not be logged as a proxy error.
            self.close_connection = True
        except Exception as exc:  # noqa: BLE001 - keep the proxy alive
            if self._headers_sent:
                # Status/headers are already on the wire; a 502 here would be
                # appended to the existing response and corrupt the stream.
                if server.verbose:
                    sys.stderr.write(
                        f"stream aborted after headers for {method} {self.path}: {exc!r}\n"
                    )
            else:
                self.log_error("proxy error for %s %s: %r", method, self.path, exc)
                if not self.wfile.closed:
                    try:
                        self.send_error(502, "proxy error", str(exc))
                    except Exception:  # noqa: BLE001
                        pass
            self.close_connection = True

    def _relay(self, response: http.client.HTTPResponse, *, bodyless: bool = False) -> int:
        total = 0
        reader = getattr(response, "read1", None)
        try:
            while True:
                if reader is not None:
                    try:
                        chunk = reader(65536)
                    except (NotImplementedError, ValueError):
                        reader = None
                        continue
                else:
                    chunk = response.read(65536)
                if not chunk:
                    break
                if bodyless:
                    total += len(chunk)
                    continue
                self.wfile.write(f"{len(chunk):X}\r\n".encode("ascii"))
                self.wfile.write(chunk)
                self.wfile.write(b"\r\n")
                self.wfile.flush()
                total += len(chunk)
            if not bodyless:
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            # Client disconnected while we were streaming; nothing to repair.
            return total
        return total


def build_server(
    listen: str,
    upstream_url: str,
    *,
    role: str = "user",
    synth_missing: bool = True,
    normalize_batches: bool = True,
    timeout: float = 300.0,
    verbose: bool = False,
) -> ProxyServer:
    host, _, port_text = listen.rpartition(":")
    if not host or not port_text.isdigit():
        raise SystemExit(f"--listen must look like 127.0.0.1:18787, got {listen!r}")
    upstream = urllib.parse.urlsplit(upstream_url)
    if upstream.scheme not in {"http", "https"} or not upstream.hostname:
        raise SystemExit(f"--upstream must be an http(s) URL, got {upstream_url!r}")
    return ProxyServer(
        (host, int(port_text)),
        upstream,
        role=role,
        synth_missing=synth_missing,
        normalize_batches=normalize_batches,
        timeout=timeout,
        verbose=verbose,
    )


def selftest() -> int:
    delegation = "<codex_delegation>\n  <input>run the tweet workflow</input>\n</codex_delegation>"
    payload = {
        "model": "deepseek-flash",
        "stream": True,
        "input": [
            {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "hi"}]},
            {
                "type": "function_call",
                "call_id": "call_ok",
                "name": "exec_command",
                "arguments": "{}",
            },
            {
                "type": "function_call_output",
                "call_id": "call_ok",
                "output": "ok",
            },
            {
                "type": "function_call",
                "call_id": "call_missing",
                "name": "read_file",
                "arguments": "{}",
            },
            {
                "type": "function_call_output",
                "id": "fco_1",
                "name": "create_thread",
                "namespace": "codex_app",
                "output": delegation,
            },
        ],
    }
    stats = repair_payload(payload)
    items = payload["input"]
    types = [item.get("type") for item in items]

    assert stats.rewritten_outputs == 1, stats
    assert stats.synthesized_outputs == 1, stats
    assert "function_call_output" not in {
        item.get("type")
        for item in items
        if isinstance(item, dict) and item.get("call_id") is None
    }, "orphan output survived"
    rewritten = next(item for item in items if item.get("type") == "message" and item["role"] == "user"
                     and item["content"][0]["text"] == delegation)
    assert rewritten["content"][0]["type"] == "input_text"
    assert items.index(rewritten) > 0
    assert types == [
        "message",
        "function_call",
        "function_call",
        "function_call_output",
        "function_call_output",
        "message",
    ], types
    assert items[4]["call_id"] == "call_missing" and items[4]["output"] == "aborted"
    print("selftest OK:", stats.summary())
    return 0


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Repair Codex standalone function_call_output items before a strict /responses upstream."
    )
    parser.add_argument("--listen", default="127.0.0.1:18787", help="local address (default: %(default)s)")
    parser.add_argument(
        "--upstream",
        default="https://api.deepseek.com",
        help="upstream base URL; incoming path/query is appended (default: %(default)s)",
    )
    parser.add_argument(
        "--role",
        default="user",
        choices=("user", "developer"),
        help="role used when rewriting an orphan output into a message (default: %(default)s)",
    )
    parser.add_argument(
        "--no-synth-missing",
        dest="synth_missing",
        action="store_false",
        help="do not append aborted outputs for function_calls that have none",
    )
    parser.add_argument(
        "--no-normalize-batches",
        dest="normalize_batches",
        action="store_false",
        help="do not reorder runs so calls precede their outputs",
    )
    parser.add_argument("--timeout", type=float, default=300.0, help="upstream socket timeout in seconds")
    parser.add_argument("--verbose", action="store_true", help="log every request and repair summary")
    parser.add_argument(
        "--log-file",
        help="append logs to this file instead of stderr (used by the auto-start entry point)",
    )
    parser.add_argument("--selftest", action="store_true", help="run offline repair assertions and exit")
    parser.add_argument("--version", action="version", version=__version__)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.selftest:
        return selftest()

    log_stream = None
    if args.log_file:
        log_stream = open(args.log_file, "a", encoding="utf-8", buffering=1)
        sys.stderr = log_stream
    banner = log_stream or sys.stdout

    server = build_server(
        args.listen,
        args.upstream,
        role=args.role,
        synth_missing=args.synth_missing,
        normalize_batches=args.normalize_batches,
        timeout=args.timeout,
        verbose=args.verbose,
    )
    host, port = server.server_address[:2]
    print(f"listening on http://{host}:{port}  ->  {args.upstream}", file=banner, flush=True)
    print(f"set base_url = \"http://{host}:{port}/\" in ~/.codex/config.toml", file=banner, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
