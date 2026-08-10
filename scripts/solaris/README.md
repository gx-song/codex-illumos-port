# Codex for illumos/Solaris

This directory contains an experimental cross-build path for running the Codex
CLI or standalone terminal UI on a 64-bit x86 illumos or Solaris host over SSH.

统一的中文使用流程见 [USAGE.zh-CN.md](USAGE.zh-CN.md)。

By default, `build-tui.sh` builds the standalone `codex-tui` binary. Set
`CODEX_BUILD_FULL_CLI=1` to build the multipurpose `codex` CLI required by
desktop SSH remote connections. Neither mode builds the V8-backed
`codex-code-mode-host` executable.

The TUI still uses Codex core, exec-server, app-server client/protocol, and
other internal crates. The goal is a working SSH TUI, not a new minimal Codex
architecture.

## Status

The following combination was verified on August 10, 2026:

| Component | Tested value |
| --- | --- |
| Upstream Codex commit | `8cabf5a6cf` |
| Local merge commit | `f074778bd6` |
| Codex version | `0.148.0-alpha.5+illumos.8cabf5a6cf` |
| Rust target | `x86_64-unknown-illumos` |
| Rust | `1.95.0`, pinned by `codex-rs/rust-toolchain.toml` |
| LLVM and LLD | `22.1.8` from Homebrew |
| `pkgconf` | `3.0.4` from Homebrew |
| Runtime OS | OmniOS r151058, amd64 |
| Stripped full CLI | approximately 92 MiB |

Oracle Solaris can use Rust's `x86_64-pc-solaris` target, but that path has not
been validated by this work.

## Included files

| File | Purpose |
| --- | --- |
| `build-tui.sh` | Builds and strips the standalone TUI or full CLI |
| `fetch-sysroot.sh` | Copies headers, libraries, and GCC runtime files from the target |
| `cross/` | Reusable C/C++ environment, compiler wrappers, and CMake toolchain |
| `clang-solaris.sh` | Compatibility entry for the reusable C compiler wrapper |
| `clangxx-solaris.sh` | Compatibility entry for the reusable C++ compiler wrapper |
| `ld.lld` | Compatibility entry for the reusable LLD argument translator |
| `clangd/` | Standalone LLVM/clangd cross-build environment |
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

Building `clangd` additionally requires:

```sh
brew install cmake ninja
```

See [clangd/README.md](clangd/README.md) for the standalone CMake/Ninja build.

For ordinary C and C++ projects, configure the reusable environment:

```sh
export SOLARIS_SYSROOT="$HOME/.cache/codex/solaris-sysroot"
scripts/solaris/cross/install.sh
eval "$(solaris-cross-env)"
```

This installs the tools under `$HOME/.local` and exports `CC`, `CXX`, Cargo
linker variables, LLVM binutils, pkg-config sysroot variables, and
`SOLARIS_CMAKE_TOOLCHAIN_FILE`. See [cross/README.md](cross/README.md) for
direct compiler, CMake, Rust, and remote validation examples.

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

Build the full CLI used by the deployment steps below:

```sh
export SOLARIS_SYSROOT="$HOME/.cache/codex/solaris-sysroot"
CODEX_BUILD_FULL_CLI=1 \
  scripts/solaris/build-tui.sh x86_64-unknown-illumos
```

```text
codex-rs/target/x86_64-unknown-illumos/release/codex
```

Build only the standalone TUI:

```sh
scripts/solaris/build-tui.sh x86_64-unknown-illumos
```

```text
codex-rs/target/x86_64-unknown-illumos/release/codex-tui
```

The build script uses:

- the detected online CPU count for Cargo jobs and codegen units
- `opt-level=z`
- thin LTO
- `panic=abort`
- no release debug information
- final target-only `llvm-strip --strip-all`

These settings keep the build parallel while retaining size optimization.
`panic=abort` also disables Rust panic unwinding and normal panic backtraces.
Set `CARGO_PROFILE_RELEASE_LTO=fat` when minimum artifact size is more important
than build parallelism.

For a diagnostic build with symbols and line tables:

```sh
NO_STRIP=1 scripts/solaris/build-tui.sh x86_64-unknown-illumos
```

Override parallelism with `CARGO_BUILD_JOBS` and
`CARGO_PROFILE_RELEASE_CODEGEN_UNITS`. Other release settings can be overridden
through Cargo profile environment variables such as
`CARGO_PROFILE_RELEASE_LTO`.

## Cross-linker design

Rust invokes the reusable Clang wrapper under `cross/bin` for C dependencies
and the final link.
For the illumos Rust target, the wrapper uses Clang's
`x86_64-pc-solaris2.11` frontend ABI because the Darwin-hosted illumos driver
otherwise emits macOS linker options.

The reusable `cross/bin/ld.lld` wrapper translates the Solaris driver arguments
used by this build, selects the amd64 startup objects from the sysroot, adds
the target GCC runtime, and sets:

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

Record the expected version and checksum, then copy the binary:

```sh
artifact=codex-rs/target/x86_64-unknown-illumos/release/codex
export CODEX_EXPECTED_VERSION='codex-cli 0.148.0-alpha.5+illumos.8cabf5a6cf'
export CODEX_EXPECTED_SHA256="$(shasum -a 256 "$artifact" | awk '{print $1}')"

scp -o "ProxyJump=$SOLARIS_SSH_PROXY_JUMP" \
  "$artifact" \
  "$TARGET_SSH:.local/bin/codex.new"

ssh -J "$SOLARIS_SSH_PROXY_JUMP" "$TARGET_SSH" \
  'chmod 755 "$HOME/.local/bin/codex.new"'
```

Verify the temporary upload before replacing the installed binary. This checks
the exact version, SHA-256, dynamic libraries, and the full CLI-only
`app-server` command:

```sh
CODEX_REMOTE_BIN=.local/bin/codex.new \
CODEX_EXPECT_FULL_CLI=1 \
SOLARIS_SSH_PROXY_JUMP="$SOLARIS_SSH_PROXY_JUMP" \
  scripts/solaris/remote-smoke-test.sh "$TARGET_SSH"

ssh -J "$SOLARIS_SSH_PROXY_JUMP" "$TARGET_SSH" \
  'mv "$HOME/.local/bin/codex.new" "$HOME/.local/bin/codex"'
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

## Configure Amazon Bedrock

The illumos build includes the Amazon Bedrock provider. Select it in
`config.toml`:

```toml
model_provider = "amazon-bedrock"

[model_providers.amazon-bedrock.aws]
profile = "codex-bedrock"
region = "us-east-1"
```

The provider also accepts the AWS SDK default credential and region chains.
For a non-EC2 illumos host, set a usable home directory and disable IMDS
probing so missing credentials fail promptly:

```sh
export HOME="/export/home/$USER"
export AWS_PROFILE="codex-bedrock"
export AWS_REGION="us-east-1"
export AWS_EC2_METADATA_DISABLED=true
```

Bedrock support is experimental on this port. Validate the selected profile,
region, session token handling, TLS trust, and one real signed request on the
target host before publishing a binary.

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
