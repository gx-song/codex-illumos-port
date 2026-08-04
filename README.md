# Codex illumos port

Unofficial build kit for compiling the complete upstream Codex CLI for
64-bit x86 illumos systems.

This repository intentionally does not contain a fork of the Codex source
tree. It contains only:

- a pinned upstream commit
- two reviewable compatibility patches
- the cross-compilation toolchain wrappers
- validation and release documentation

The release binary is published through GitHub Releases, not committed to Git.

## Status

Verified on August 4, 2026:

| Component | Value |
| --- | --- |
| Upstream | `openai/codex@dae21222149bcdcc31534b5a02fceae933081906` |
| Rust target | `x86_64-unknown-illumos` |
| Runtime | OmniOS r151058, amd64 |
| Build host | macOS with Homebrew |
| CLI scope | Complete `codex` CLI, including TUI, `exec`, MCP, app-server, and web search |

No Codex feature was intentionally removed to reduce the binary. Native image
clipboard access is disabled because `arboard` has no illumos backend. Text
copy through terminal mechanisms such as OSC52 and tmux remains available.

The second patch works around a Codex Desktop SSH bootstrap incompatibility:
ksh93 requires `\0ddd` octal escapes for `printf %b`, while current Desktop
builds send `\ddd`. The CLI probes `/bin/sh` and emits the ready marker only
when the shell failed to do so correctly, avoiding duplicate marker bytes.

## Files

| Path | Purpose |
| --- | --- |
| `UPSTREAM_COMMIT` | Exact upstream source revision |
| `patches/0001-*.patch` | Minimal illumos compile compatibility |
| `patches/0002-*.patch` | Desktop SSH ready-marker compatibility |
| `tools/apply-patches.sh` | Verify and apply the patch set |
| `tools/fetch-sysroot.sh` | Copy headers and runtime libraries from the target |
| `tools/build.sh` | Build and strip the complete CLI |
| `tools/clang*-solaris.sh` | Clang compiler drivers |
| `tools/ld.lld` | Solaris-to-LLD linker argument translation |
| `tools/remote-smoke-test.sh` | Read-only remote deployment checks |
| `examples/config.toml` | Redacted self-hosted Responses gateway example |
| `docs/VALIDATION.md` | Runtime and Desktop SSH validation |

## Prerequisites

```sh
brew install llvm lld pkgconf
rustup target add x86_64-unknown-illumos
```

The target must be a 64-bit x86 SunOS 5.11 system with development headers,
64-bit system libraries, and a GCC runtime under `/usr/gcc` or
`/opt/local/gcc*`.

## Prepare upstream source

```sh
git clone https://github.com/openai/codex.git codex-upstream
git -C codex-upstream checkout "$(cat UPSTREAM_COMMIT)"
tools/apply-patches.sh codex-upstream
```

The script refuses a different upstream revision or a dirty checkout. When
rebasing, update the pinned commit and regenerate both patch files.

## Fetch the sysroot

```sh
export TARGET_SSH="user@illumos-host"
export SOLARIS_SSH_PROXY_JUMP="user@jump-host"  # optional

tools/fetch-sysroot.sh "$TARGET_SSH"
```

Default destination:

```text
$HOME/.cache/codex/solaris-sysroot
```

Do not commit or redistribute the sysroot.

## Build

```sh
export SOLARIS_SYSROOT="$HOME/.cache/codex/solaris-sysroot"
tools/build.sh codex-upstream x86_64-unknown-illumos
```

Output:

```text
codex-upstream/codex-rs/target/x86_64-unknown-illumos/release/codex
```

The default release profile uses size optimization, fat LTO, one codegen unit,
`panic=abort`, and final target-only stripping. Set `NO_STRIP=1` for a
diagnostic build. Set `CARGO_TARGET_DIR` to reuse a shared build cache.

## Deploy

```sh
scp codex-upstream/codex-rs/target/x86_64-unknown-illumos/release/codex \
  "$TARGET_SSH:.local/bin/codex"
ssh "$TARGET_SSH" 'chmod 755 "$HOME/.local/bin/codex"'
```

For a jump host, add `-J "$SOLARIS_SSH_PROXY_JUMP"` to SSH and
`-o "ProxyJump=$SOLARIS_SSH_PROXY_JUMP"` to SCP.

Run:

```sh
tools/remote-smoke-test.sh "$TARGET_SSH"
```

Then follow `docs/VALIDATION.md`.

## Runtime notes

- The binary is dynamically linked to the userspace represented by the
  sysroot.
- The verified build uses `/lib/amd64/ld.so.1`.
- The GCC runtime RUNPATH is derived from the target sysroot.
- Native Codex sandboxing is unavailable on illumos. Use a zone or another
  external isolation boundary where required.
- A self-hosted gateway must implement the OpenAI Responses protocol,
  including streaming and tool calls. Hosted web search works only when the
  gateway implements that tool.

## License

The patches and tools are distributed under the same license included in
`LICENSE`. Codex remains an OpenAI project; this repository is an unofficial
port and is not an OpenAI-supported release.
