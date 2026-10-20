#!/usr/bin/env python3
"""Test a CLI turn against a local Responses fixture without model credentials.

Usage: python3 scripts/solaris/exec-smoke.py /path/to/codex
All configuration, shell writes, and session data live in a temporary directory.
The fixture explicitly bypasses the Codex sandbox to test the target OS exec path.
"""

import argparse
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("binary", help="Path to the CLI binary to test")
parser.add_argument(
    "--shell-snapshot",
    action="store_true",
    help="Enable both shell snapshot implementations",
)
options = parser.parse_args()
requests = []


def event(kind, **fields):
    return {"type": kind, **fields}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        requests.append(body)
        response_id = "smoke-" + str(len(requests))
        events = [event("response.created", response={"id": response_id})]
        if len(requests) == 1:
            events.append(
                event(
                    "response.output_item.done",
                    item={
                        "type": "function_call",
                        "call_id": "smoke-shell",
                        "name": "exec_command",
                        "arguments": json.dumps(
                            {
                                "cmd": "printf illumos-exec-ok > smoke.txt && cat smoke.txt",
                                "shell": "/bin/sh",
                                "login": False,
                                "yield_time_ms": 1000,
                            }
                        ),
                    },
                )
            )
        else:
            events.append(
                event(
                    "response.output_item.done",
                    item={
                        "type": "message",
                        "id": "smoke-message",
                        "role": "assistant",
                        "content": [{"type": "output_text", "text": "smoke-complete"}],
                    },
                )
            )
        events.append(
            event(
                "response.completed",
                response={
                    "id": response_id,
                    "usage": {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0},
                },
            )
        )
        payload = "".join("data: " + json.dumps(e) + "\n\n" for e in events).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


with tempfile.TemporaryDirectory(prefix="codex-upgrade-exec-") as scratch:
    root = Path(scratch)
    codex_config = root / "home"
    codex_config.mkdir()
    (codex_config / "config.toml").write_text(f"""model = "gpt-5.3-codex"
model_provider = "smoke"
[features]
code_mode = false
shell_snapshot = {str(options.shell_snapshot).lower()}
shell_snapshot_v2 = {str(options.shell_snapshot).lower()}
connectors = false
apps = false
[model_providers.smoke]
name = "Local smoke fixture"
base_url = "http://127.0.0.1:PORT/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
""")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    config = codex_config / "config.toml"
    config.write_text(config.read_text().replace("PORT", str(server.server_port)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    environment = dict(os.environ)
    environment["CODEX_HOME"] = str(codex_config)
    for key in [
        "CODEX_API_KEY",
        "OPENAI_API_KEY",
        "OPENAI_BASE_URL",
        "CODEX_INTERNAL_ORIGINATOR_OVERRIDE",
    ]:
        environment.pop(key, None)
    try:
        completed = subprocess.run(
            [
                options.binary,
                "exec",
                "--skip-git-repo-check",
                "--dangerously-bypass-approvals-and-sandbox",
                "--json",
                "Run the shell fixture and report completion.",
            ],
            cwd=root,
            env=environment,
            capture_output=True,
            text=True,
            timeout=120,
        )
        if completed.returncode:
            raise RuntimeError(completed.stderr[-5000:] + completed.stdout[-5000:])
        assert (root / "smoke.txt").read_text() == "illumos-exec-ok", completed.stdout
        assert len(requests) == 2, len(requests)
        outputs = [
            item
            for item in requests[1]["input"]
            if item.get("type") == "function_call_output"
        ]
        assert any("illumos-exec-ok" in str(item.get("output")) for item in outputs), (
            outputs
        )
        assert "smoke-complete" in completed.stdout, completed.stdout
        print(
            "PASS: CLI Responses round trip, shell execution, file write/read and tool output"
        )
    finally:
        server.shutdown()
        server.server_close()
