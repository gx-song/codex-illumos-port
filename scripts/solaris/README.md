# Standalone Codex TUI for illumos/Solaris

This directory contains an experimental cross-build path for running the Codex
terminal UI on a 64-bit x86 illumos or Solaris host over SSH.

It builds the standalone `codex-tui` binary, deployed under the shorter
`codex` name. It does not build the multipurpose `codex` CLI or the V8-backed
`codex-code-mode-host` executable. The standalone entry point also exposes the
compatible `resume`, `exec`, `exec review`, and `completion` commands.

The TUI still uses Codex core, exec-server, app-server client/protocol, and
other internal crates. The goal is a working SSH TUI, not a new minimal Codex
architecture.

## Status

The following combination was verified on August 3, 2026:

| Component | Tested value |
| --- | --- |
| Codex base commit | `4642370542739d5dd080b0c87a9de06a6435d3db` |
| Rust target | `x86_64-unknown-illumos` |
| Rust | `1.95.0`, pinned by `codex-rs/rust-toolchain.toml` |
| LLVM and LLD | `22.1.8` from Homebrew |
| `pkgconf` | `3.0.4` from Homebrew |
| Runtime OS | OmniOS r151058, amd64 |
| Stripped binary | approximately 54 MiB |

Oracle Solaris can use Rust's `x86_64-pc-solaris` target, but that path has not
been validated by this work.

## Included files

| File | Purpose |
| --- | --- |
| `build-tui.sh` | Builds and strips the standalone TUI |
| `fetch-sysroot.sh` | Copies headers, libraries, and GCC runtime files from the target |
| `clang-solaris.sh` | C compiler and linker driver wrapper |
| `clangxx-solaris.sh` | C++ compiler and linker driver wrapper |
| `ld.lld` | Translates Solaris linker arguments for LLD |
| `config.toml` | Redacted self-hosted Responses gateway example |
| `remote-smoke-test.sh` | Non-destructive remote deployment checks |
| `CORE_FEATURE_TEST.md` | Interactive SSH TUI test matrix |
| `PORTING_NOTES.md` | Source changes, dependency choices, and limitations |
| `PUBLISHING.md` | Public-release and secret-removal checklist |
| `RELEASE_NOTES.md` | Preview release provenance, installation, and limitations |

## Prerequisites

The build host needs:

- macOS with Homebrew
- the Rust toolchain selected by this repository
- SSH access to an ABI-compatible illumos/Solaris target
- enough local memory and disk space for a release build with fat LTO

Install the local cross-build tools:

```sh
brew install llvm lld pkgconf
(cd codex-rs && rustup target add x86_64-unknown-illumos)
```

`build-tui.sh` runs Cargo from `codex-rs`, so rustup automatically selects the
repository-pinned toolchain. Verify it before publishing a binary:

```sh
(cd codex-rs && rustc --version)
```

The target host must provide:

- SunOS 5.11 on 64-bit x86
- `/usr/include`
- `/usr/lib/amd64` and `/lib/amd64`
- 64-bit GCC startup objects and `libgcc_s.so.1` under `/usr/gcc` or
  `/opt/local/gcc*`

The scripts validate these files before compiling.

The tested OmniOS binary also resolves `liblzma.so.5` and embeds a RUNPATH to
the GCC runtime copied from the target sysroot. On the verified host this was
GCC 13.4.0 under `/opt/local/gcc13/lib/amd64`. Run `ldd` after every deployment
instead of assuming another illumos distribution has the same package layout.

## Obtain the sysroot

Set an SSH target. A jump host is optional:

```sh
export TARGET_SSH="user@illumos-host"
export SOLARIS_SSH_PROXY_JUMP="user@jump-host"
```

Copy the target userspace into a local cache:

```sh
scripts/solaris/fetch-sysroot.sh "$TARGET_SSH"
```

The default destination is:

```text
$HOME/.cache/codex/solaris-sysroot
```

Specify a different destination as the second argument when needed:

```sh
scripts/solaris/fetch-sysroot.sh \
  "$TARGET_SSH" \
  "$HOME/.cache/codex/omnios-r151058-sysroot"
```

The sysroot must match the target release and architecture. Do not commit or
redistribute it: it contains operating-system headers and libraries whose
licenses are separate from the Codex source license.

The tested sysroot occupies approximately 1.2 GiB. When replacing an existing
destination, `fetch-sysroot.sh` retains the old directory with a `.previous`
suffix, so allow roughly twice that space until the backup is reviewed and
removed.

## Build

```sh
export SOLARIS_SYSROOT="$HOME/.cache/codex/solaris-sysroot"
scripts/solaris/build-tui.sh x86_64-unknown-illumos
```

Output:

```text
codex-rs/target/x86_64-unknown-illumos/release/codex-tui
```

The build script uses:

- `opt-level=z`
- fat LTO
- one codegen unit
- `panic=abort`
- no release debug information
- final target-only `llvm-strip --strip-all`

These settings reduce deployment size but make the final local link slower and
more memory-intensive. `panic=abort` also disables Rust panic unwinding and
normal panic backtraces.

For a diagnostic build with symbols and line tables:

```sh
NO_STRIP=1 scripts/solaris/build-tui.sh x86_64-unknown-illumos
```

The release profile can be overridden through Cargo profile environment
variables such as `CARGO_PROFILE_RELEASE_LTO`.

## Cross-linker design

Rust invokes the included Clang wrapper for C dependencies and the final link.
For the illumos Rust target, the wrapper uses Clang's
`x86_64-pc-solaris2.11` frontend ABI because the Darwin-hosted illumos driver
otherwise emits macOS linker options.

The `ld.lld` wrapper translates the Solaris driver arguments used by this
build, selects the amd64 startup objects from the sysroot, adds the target GCC
runtime, and sets:

```text
/lib/amd64/ld.so.1
```

Before Cargo starts, `build-tui.sh` compiles and links a small C probe and
checks that its ELF interpreter is correct.

`AWS_LC_SYS_CMAKE_BUILDER=0` selects the `aws-lc-sys` crate's `cc` build path,
avoiding CMake host-target inference for SunOS.

## Deploy

Create the destination:

```sh
ssh -J "$SOLARIS_SSH_PROXY_JUMP" "$TARGET_SSH" \
  'mkdir -p "$HOME/.local/bin"'
```

Copy the binary:

```sh
scp -o "ProxyJump=$SOLARIS_SSH_PROXY_JUMP" \
  codex-rs/target/x86_64-unknown-illumos/release/codex-tui \
  "$TARGET_SSH:.local/bin/codex"
```

Set its mode:

```sh
ssh -J "$SOLARIS_SSH_PROXY_JUMP" "$TARGET_SSH" \
  'chmod 755 "$HOME/.local/bin/codex"'
```

When no jump host is required, omit `-J` and the `ProxyJump` option.

## Configure a self-hosted gateway

Copy `config.toml` to `$CODEX_HOME/config.toml`, then replace the example model
and gateway URL. Keep credentials in an environment variable:

```sh
export LOCAL_GATEWAY_API_KEY="replace-at-runtime"
```

Uncomment this line in the configuration:

```toml
env_key = "LOCAL_GATEWAY_API_KEY"
```

Do not put the token value in a Git-tracked TOML file.

The loopback HTTP URL in the sample is only appropriate when the gateway runs
on the same host or is reached through an SSH tunnel. Use HTTPS for a remote
gateway because bearer credentials sent over plain HTTP are visible on the
network.

For a private CA bundle, set one of:

```sh
export CODEX_CA_CERTIFICATE="/path/to/ca-bundle.pem"
export SSL_CERT_FILE="/path/to/ca-bundle.pem"
```

The gateway must implement the OpenAI Responses protocol at
`POST <base_url>/responses`, including streaming events and the function/tool
call forms used by Codex. A Chat Completions-only endpoint is insufficient.

Live web search is a Responses hosted tool. If the gateway does not implement
it, set `web_search = "disabled"` and omit `--search`.

## Validate

Run the automated deployment checks from the build host:

```sh
SOLARIS_SSH_PROXY_JUMP="$SOLARIS_SSH_PROXY_JUMP" \
  scripts/solaris/remote-smoke-test.sh \
  "$TARGET_SSH" \
  "example/model-a" \
  "example/model-b"
```

The static `model-catalog.json` file is optional. Model arguments require that
file and verify its exact model set. Without model arguments, a missing static
catalog produces a warning because the gateway may provide models through
another configured mechanism.

Then follow [CORE_FEATURE_TEST.md](CORE_FEATURE_TEST.md) for Responses
streaming, shell execution, file operations, `apply_patch`, approvals, web
search, interruption, and session resume.

Use `REDACT_OUTPUT=1` when capturing preflight output for a public issue:

```sh
REDACT_OUTPUT=1 \
SOLARIS_SSH_PROXY_JUMP="$SOLARIS_SSH_PROXY_JUMP" \
  scripts/solaris/remote-smoke-test.sh "$TARGET_SSH"
```

## Security boundary

Codex has no native Seatbelt, Landlock/seccomp, or Windows sandbox backend on
illumos/Solaris. `read-only` and `workspace-write` can influence policy and
approval decisions, but they do not create an OS-enforced process sandbox.

Run the binary in an illumos zone or another external isolation boundary, use a
dedicated Unix account, and review approval settings before allowing
model-generated commands.

## Publishing

Read [PUBLISHING.md](PUBLISHING.md) before pushing a branch or attaching a
binary to a GitHub release. In particular, do not publish:

- copied sysroot files
- gateway tokens or private model catalogs
- SSH hostnames, addresses, or usernames
- session rollout files or TUI logs
- locally generated binaries unless release provenance and system-library
  requirements are documented
