# Codex illumos Core Feature Test

This test distinguishes host-platform limitations from self-hosted Responses
gateway limitations. Run it through a real SSH terminal; redirected stdin does
not exercise the TUI.

## Automated preflight

From the build host:

```sh
export TARGET_SSH="user@illumos-host"
export SOLARIS_SSH_PROXY_JUMP="user@jump-host"

scripts/solaris/remote-smoke-test.sh \
  "$TARGET_SSH" \
  "example/model-a" \
  "example/model-b"
```

The model arguments are optional. Supplying them verifies the exact remote
catalog; omitting them only verifies valid non-empty catalog JSON.

The script checks the OS, architecture, ELF dependencies, CLI and `resume`
surface, SSH PTY allocation, configuration permissions, model catalog, and
basic shell/filesystem operation. It does not print `config.toml`.

## Isolated workspace

On the illumos host:

```sh
test_root="$HOME/codex-illumos-core-test-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$test_root/fixture"
printf 'ILLUMOS_READ_SENTINEL_7f3c\n' >"$test_root/fixture/read-me.txt"
printf 'alpha\ncharlie\n' >"$test_root/fixture/patch-me.txt"
cd "$test_root"
printf 'Test workspace: %s\n' "$test_root"

CODEX="$HOME/.local/bin/codex"
```

Use this directory for all write tests.

## Main TUI session

Use external isolation such as an illumos zone. Native Codex sandboxing is not
available on this platform:

```sh
TERM=xterm-256color "$CODEX" \
  --no-alt-screen \
  -C "$test_root" \
  -s danger-full-access \
  -a on-request
```

Record PASS or FAIL for each test.

| ID | Function | Test prompt or action | PASS condition |
| --- | --- | --- | --- |
| T01 | Terminal UI | Resize the terminal, enter Unicode and ASCII text, open `/status`, then close it. | No corrupt layout, lost input, stuck raw mode, or crash. |
| T02 | Model catalog | Run `/model` and select each configured model. | The intended models appear and selection changes the active model. |
| T03 | Responses streaming | `Reply with exactly ILLUMOS_STREAM_OK and do not call tools.` | The response completes and the TUI remains responsive. A fully buffered response usually indicates gateway behavior. |
| T04 | File read | `Read fixture/read-me.txt and report its exact contents.` | The answer contains `ILLUMOS_READ_SENTINEL_7f3c` after a successful local tool call. |
| T05 | Shell | `Run uname -s; uname -r; pwd and report the raw output.` | Output contains `SunOS`, `5.11`, and the test workspace. |
| T06 | File creation | `Use apply_patch to create result.txt containing ILLUMOS_PATCH_CREATE_OK followed by a newline.` | The file has exactly the requested content. |
| T07 | File modification | `Use apply_patch to insert bravo between alpha and charlie in fixture/patch-me.txt.` | The file contains `alpha`, `bravo`, `charlie` on separate lines. |
| T08 | Process stdin | `Start sh -c 'read value; printf "STDIN:%s\\n" "$value"', keep the session open, then send ping with write_stdin.` | The same process session returns `STDIN:ping`. |
| T09 | Interrupt | Ask Codex to run `sleep 30`, press Ctrl+C once, then send `Reply with exactly STILL_ALIVE.` | The command stops and the next turn succeeds. |
| T10 | Web search | Restart with `--search`. Ask Codex to search an official OS project site for its current stable release and cite the official source. | A web-search event occurs and the response contains an authoritative citation. |
| T11 | Resume by ID | Record the session ID from `/status`, run `/quit`, then run `"$CODEX" resume SESSION_ID`. | The transcript and workspace are restored. |
| T12 | Resume last | Quit and run `"$CODEX" resume --last -C "$test_root"`. | The latest interactive session returns without a picker. |
| T13 | Terminal restore | Exit with `/quit`, run `stty -a`, then type a shell command. | Echo, line editing, and Enter work normally. |

Verify the patch tests outside Codex:

```sh
printf '%s\n' '--- result.txt ---'
cat "$test_root/result.txt"
printf '%s\n' '--- patch-me.txt ---'
cat "$test_root/fixture/patch-me.txt"
```

## Approval behavior

Start a separate session:

```sh
rm -f "/tmp/codex-approval-probe-$USER"
"$CODEX" \
  --no-alt-screen \
  -C "$test_root" \
  -s workspace-write \
  -a untrusted
```

Prompt:

```text
Run sh -c 'printf "APPROVED\n" > /tmp/codex-approval-probe-$USER' exactly as written.
```

Reject the first approval and verify that the file does not exist. Repeat,
approve the command, and verify:

```sh
cat "/tmp/codex-approval-probe-$USER"
rm -f "/tmp/codex-approval-probe-$USER"
```

PASS requires rejection and approval to be honored. Writing outside the
workspace without approval is a Codex security failure.

`workspace-write` does not create an OS-enforced sandbox on illumos. After
approval, the command runs with the Unix permissions of the Codex process.

## Failure classification

| Symptom | Classification |
| --- | --- |
| `ld.so.1`, missing library, illegal instruction, or crash before TUI startup | Build, sysroot, or deployment |
| Garbled display, missing keys, or raw mode left enabled | SSH terminal, `TERM`, locale, or TUI |
| DNS, connect, TLS, or timeout before an HTTP response | Host network or gateway availability |
| HTTP 400/404 for `/responses`, unsupported event, or rejected tool schema | Gateway Responses compatibility |
| Text works but tool calls are never emitted | Model behavior or gateway tool-call support |
| Tool call is emitted but the local handler fails | Codex illumos port or missing host utility |
| Web search is absent | Configuration, model metadata, or gateway capability |
| Web search is emitted but rejected by the API | Gateway hosted-tool incompatibility |
| Picker works but a stored session cannot load | Rollout compatibility or damaged session data |
| Native isolation is not enforced | Expected illumos platform limitation |

Repeat model-backed failures with another configured model. A single-model
failure is not sufficient evidence of an illumos problem.

## Expected unsupported features

The current port intentionally reports these as unsupported:

- native filesystem/process sandboxing
- image paste from the system clipboard
- automatic browser launch and browser-based OpenAI login
- silent MCP OAuth browser login
- Sentry feedback upload
- Amazon Bedrock provider
- IDE IPC integration

Text copy through OSC52/tmux, local shell execution, file operations,
`apply_patch`, approvals, Responses streaming, web search, and session resume
remain in scope.

## Diagnostics

The default TUI log is normally:

```sh
tail -n 300 "$HOME/.codex/log/codex-tui.log"
```

Record the failed turn time, session ID, model name, HTTP status, gateway
request ID, and smallest reproducing prompt. Logs may contain prompts and model
output. Redact private source text before sharing them, and never publish a
configuration file containing credentials.
