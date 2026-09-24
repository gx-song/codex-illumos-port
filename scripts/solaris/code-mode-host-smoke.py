#!/usr/bin/env python3
"""Drive the illumos codex-code-mode-host over its stdio framed IPC protocol.

Read-only crash-regression check for the V8 brk/mmap heap-conflict fix
(commit "illumos: 通过 libumem mmap 后端修复 code-mode host 的 brk 堆冲突崩溃").

It spawns the host exactly as Codex does (LD_PRELOAD_64=libumem.so with
UMEM_OPTIONS=backend=mmap), completes the handshake, opens a session, executes
a JavaScript cell, and waits for the result. A clean Result response proves the
V8 Isolate initialized and ran without the prior std::bad_alloc abort.

Usage:
  python3 scripts/solaris/code-mode-host-smoke.py [HOST_BINARY]
"""

from __future__ import annotations

import json
import os
import select
import struct
import subprocess
import sys
import time

MAX_FRAME_BYTES = 64 * 1024 * 1024


def log(msg: str) -> None:
    print(msg, flush=True)


def encode_frame(obj: dict) -> bytes:
    payload = json.dumps(obj).encode("utf-8")
    if len(payload) > MAX_FRAME_BYTES:
        raise ValueError("frame too large")
    return struct.pack("<I", len(payload)) + payload


def read_one(proc: "subprocess.Popen[bytes]") -> dict | None:
    """Read exactly one length-prefixed JSON frame from the host stdout."""
    r, _, _ = select.select([proc.stdout], [], [], 25)
    if not r:
        return None
    header = proc.stdout.read(4)
    if len(header) != 4:
        return None
    (length,) = struct.unpack_from("<I", header, 0)
    if length > MAX_FRAME_BYTES:
        raise ValueError("frame too large")
    payload = b""
    while len(payload) < length:
        piece = proc.stdout.read(length - len(payload))
        if not piece:
            return None
        payload += piece
    return json.loads(payload)


def main() -> int:
    host_binary = (
        sys.argv[1] if len(sys.argv) > 1 else ".local/bin/codex-code-mode-host"
    )
    env = dict(os.environ)
    # Mirror the fix in code-mode/src/remote_session/connection.rs.
    env["LD_PRELOAD_64"] = "libumem.so"
    env["UMEM_OPTIONS"] = "backend=mmap"

    proc = subprocess.Popen(  # noqa: S603
        [host_binary, "--listen", "stdio"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )

    def send(obj: dict) -> None:
        proc.stdin.write(encode_frame(obj))  # type: ignore[union-attr]
        proc.stdin.flush()  # type: ignore[union-attr]

    try:
        # 1. Handshake: client hello -> host ready.
        send(
            {
                "type": "connection/hello",
                "supportedVersions": [1],
                "requiredCapabilities": [],
                "optionalCapabilities": ["session-cell-execution-resource-limits"],
            }
        )
        hello = read_one(proc)
        log(f"DEBUG handshake: {json.dumps(hello)}")
        if hello is None or hello.get("type") != "connection/ready":
            log(f"FAIL: unexpected handshake response: {hello}")
            return 1
        log("PASS: handshake completed, host is alive")

        session_id = "smoke-session-1"
        # 2. Open session.
        send(
            {
                "type": "operation/request",
                "id": 1,
                "request": {
                    "method": "session/open",
                    "sessionId": session_id,
                    "cellExecutionLimits": {
                        "maxYieldTimeMs": 5000,
                        "maxHeapSizeBytes": 64 * 1024 * 1024,
                    },
                },
            }
        )
        open_resp = read_one(proc)
        log(f"DEBUG open: {json.dumps(open_resp)}")
        if open_resp is None or open_resp.get("type") != "operation/response":
            log(f"FAIL: unexpected open response: {open_resp}")
            return 1
        log("PASS: session opened")

        # 3. Execute a JavaScript cell and verify its actual output.
        js_source = 'text("illumos-v8-ok");'
        send(
            {
                "type": "operation/request",
                "id": 2,
                "request": {
                    "method": "session/execute",
                    "sessionId": session_id,
                    "request": {
                        "tool_call_id": "call-1",
                        "enabled_tools": [],
                        "source": js_source,
                        "yield_time_ms": 5000,
                        "max_output_tokens": 4096,
                    },
                },
            }
        )

        started = read_one(proc)
        log(f"DEBUG exec ack: {json.dumps(started)}")
        if (
            started is None
            or started.get("type") != "operation/response"
            or started.get("id") != 2
            or (started.get("result") or {}).get("status") != "ok"
        ):
            log(f"FAIL: unexpected execute ack: {started}")
            return 1
        log("PASS: execution started (V8 Isolate initialized without crash)")

        # 4. The initial response contains the result of this short cell.
        deadline = time.time() + 30
        while time.time() < deadline:
            msg = read_one(proc)
            if msg is None:
                log("FAIL: timed out waiting for JavaScript output")
                return 1
            log(f"DEBUG msg: {json.dumps(msg)[:2000]}")
            if msg.get("type") != "execute/initialResponse" or msg.get("id") != 2:
                continue
            result = msg.get("result") or {}
            response = (result.get("value") or {}).get("Result") or {}
            content = response.get("content_items") or []
            output = "".join(
                item.get("text", "")
                for item in content
                if item.get("type") == "input_text"
            )
            if (
                result.get("status") != "ok"
                or response.get("error_text") is not None
                or output != "illumos-v8-ok"
            ):
                log(f"FAIL: unexpected JavaScript result: {result}")
                return 1
            log(f"PASS: code-mode host executed JavaScript: {output}")
            return 0
        log("FAIL: timed out waiting for JavaScript output")
        return 1
    except (EOFError, ValueError) as exc:
        stderr = proc.stderr.read().decode("utf-8", "replace") if proc.stderr else ""
        log(f"FAIL: host died during V8 execution: {exc}")
        log(f"HOST STDERR:\n{stderr}")
        return 2
    finally:
        log("DEBUG: cleaning up host process")
        proc.kill()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass


if __name__ == "__main__":
    sys.exit(main())
