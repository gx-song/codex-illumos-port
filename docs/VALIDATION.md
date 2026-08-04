# Validation

## Static checks

On the target:

```sh
file "$HOME/.local/bin/codex"
ldd "$HOME/.local/bin/codex"
"$HOME/.local/bin/codex" --version
"$HOME/.local/bin/codex" --help
"$HOME/.local/bin/codex" app-server proxy --help
"$HOME/.local/bin/codex" resume --help
"$HOME/.local/bin/codex" exec --help
```

Expected:

- Solaris ELF64 AMD64
- interpreter `/lib/amd64/ld.so.1`
- no unresolved shared libraries
- complete CLI command surface

## TUI

Run through a real SSH PTY:

```sh
TERM=xterm-256color "$HOME/.local/bin/codex" --no-alt-screen
```

Verify:

1. TUI startup, resize, Unicode input, and clean exit.
2. Responses streaming through the configured gateway.
3. Shell commands, file reads/writes, and `apply_patch`.
4. Interruption with Ctrl-C.
5. `codex resume SESSION_ID` and `codex resume --last`.
6. `codex exec`, `codex exec review`, and completion generation.
7. Web search when the gateway implements the Responses hosted tool.

## Desktop SSH

The Desktop connection requires the complete CLI because it launches:

```sh
codex app-server proxy
```

After connecting, the Desktop log should contain:

```text
initialized=true
next=connected
```

The marker compatibility patch is specific to current Desktop bootstrap
scripts using:

```sh
printf '%b' '\ddd...'
```

The formal Desktop-side fix is to emit POSIX `\0ddd` escapes, or preferably
use an ASCII random marker with `printf '%s'`. Once Desktop ships that fix,
`patches/0002-*` can be removed.

## Known platform limitations

- no native Codex filesystem/process sandbox
- no native image clipboard integration
- browser-launch behavior depends on the headless host environment

Use an illumos zone or another external isolation boundary for untrusted
workloads.
