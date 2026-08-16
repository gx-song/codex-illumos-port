# illumos/Solaris Porting Notes

These notes describe the source changes required by the illumos/Solaris port.
They are intended for code review and rebasing onto newer Codex revisions.

The build script executes Cargo from `codex-rs` so the repository's
`rust-toolchain.toml` controls the compiler and installed target.

## Build scope

The default build command selects:

```text
-p codex-tui --bin codex-tui
```

Setting `CODEX_BUILD_FULL_CLI=1` instead selects:

```text
-p codex-cli --bin codex
```

Neither mode builds `codex-code-mode-host` by default: the host embeds V8 (the
`rusty_v8` crate), which has no upstream illumos/Solaris support. The standalone
build does not remove the TUI's normal internal dependencies. In particular,
`codex-app-server-client`, `codex-app-server-protocol`, `codex-exec-server`,
and `codex-core` remain part of the dependency graph.

### Code-mode host and V8

The `v8` crate (rusty_v8) has no illumos support and publishes no prebuilt
archives for it. This port **now produces** an illumos `codex-code-mode-host`
by cross-building the V8 static library for `x86_64-unknown-illumos` **once**,
vendoring the archive in this repository, and pointing the `v8` crate build
script at it via the official `RUSTY_V8_ARCHIVE` override (plus
`RUSTY_V8_SRC_BINDING_PATH` for the generated `src/string.rs` binding). The
cross build uses the Linux-host toolchain wrappers under `scripts/solaris/cross`
and a patched illumos sysroot.

The one-time V8 cross build requires a Linux host with the LLVM/Clang 22
toolchain and the illumos sysroot. Once `librusty_v8.a` is vendored, rebuilding
`codex-code-mode-host` for illumos only needs Cargo and the archive — no Linux
host is required at rebuild time.

On Linux/macOS build hosts, `cargo build --release -p codex-code-mode-host`
uses the published non-sandboxed `rusty_v8` release archives; upstream builds
its sandbox-enabled V8 archives with Bazel and does not publish them. The
port's `codex-code-mode-runtime` therefore makes `v8_enable_sandbox` an
opt-in `v8-sandbox` feature.

Source changes required for the V8 cross build (kept in the vendored V8 source
tree, not in this repository):

- `iso/math_iso.h`, `iso/stdlib_iso.h`, `math.h`, `stdlib.h`: under Clang,
  skip the Solaris `namespace std` block so libc++ owns `std` (libc++ sources
  stay pristine).
- `v8/src/base/platform/platform-linux.cc`: guard `<sys/prctl.h>` and `mremap`
  behind `!defined(__sun__)`; `RemapShared` returns `nullptr` on illumos.
- `v8/src/base/platform/platform-posix.cc`: avoid the duplicate `madvise`
  declaration under `V8_OS_SOLARIS && !defined(__sun__)`; provide
  `Stack::ObtainCurrentThreadStackStart()` via `pthread_attr_get_np`.
- `v8/src/base/platform/platform-posix-time.cc`: implement `LocalTimezone` /
  `LocalTimeOffset` with `tzset()` / `tzname[]` / `timezone` (illumos `struct
  tm` lacks `tm_zone` / `tm_gmtoff`).
- `v8/src/trap-handler/handler-inside-posix.h`: accept `V8_OS_SOLARIS` for the
  signal selection (runtime stub is empty).

Further dependency removal was stopped once the executable built and passed
runtime checks. Smaller dependency graphs are not useful if they create a
separate product architecture that is difficult to rebase.

## Dependency portability

### HTTP and TLS

The workspace `reqwest` dependency disables default features and enables the
non-TLS common features explicitly. Crates that perform HTTPS requests already
enable a Rustls feature, notably `codex-http-client`.

This prevents the default native-TLS/OpenSSL path from being selected for the
illumos target.

### Syntax highlighting

On illumos/Solaris, `codex-tui` selects Syntect's `default-fancy` backend and
Two Face's `syntect-default-fancy` feature. This replaces the Oniguruma C
dependency with the Rust `fancy-regex` backend. Other targets keep the existing
Oniguruma configuration.

### Target-specific desktop dependencies

The following dependencies are excluded on illumos/Solaris:

- `arboard`, because native clipboard backends are unavailable
- `webbrowser`, because automatic desktop browser launch is unavailable
- Sentry upload dependencies

The corresponding clipboard, browser, and feedback APIs remain present and
return explicit unsupported errors where callers require a stable interface.

## Platform adaptations

### Canonical hostname lookup

`codex-config` defines the Solaris value of `AI_CANONNAME` because the Rust
`libc` target does not expose it. The value `0x0010` matches the target
`/usr/include/netdb.h`.

### Browser operations

Login and history UI browser-launch calls are compiled out on illumos/Solaris.
The SSH TUI can still display URLs for manual use where the surrounding flow
supports that behavior.

### Clipboard

Native image paste and native clipboard copy return clear unsupported errors.
Terminal text-copy mechanisms such as OSC52/tmux remain available.

### Feedback

Feedback data can still be assembled locally, but Sentry upload returns an
unsupported error on illumos/Solaris.

### Amazon Bedrock

The full Amazon Bedrock provider and `codex-aws-auth` dependency compile on
illumos/Solaris. The provider supports managed Bedrock bearer credentials,
`AWS_BEARER_TOKEN_BEDROCK`, and the AWS SDK default credential chain. SigV4
requests use the `bedrock-mantle` service name.

Set `HOME` and a supported region explicitly on SSH hosts. Outside EC2, use
`AWS_EC2_METADATA_DISABLED=true` to avoid waiting for IMDS when credentials are
missing. The AWS credential chain and one real signed request must be validated
on the target host because cross-compilation alone cannot verify runtime
credential providers or TLS trust.

### MCP OAuth

Silent OAuth login requires opening a browser and is rejected explicitly.
Non-silent flows can still present an authorization URL, subject to the
configured MCP server and client behavior.

### Remote announcements

The TUI only prewarms announcement data when tooltips are enabled. A
headless/self-hosted configuration can therefore disable that startup network
request with:

```toml
[tui]
show_tooltips = false
```

## Standalone command subset

The normal multipurpose CLI owns the non-interactive and session-management
subcommands. When this port ships `codex-tui` directly, its binary entry point
adds the compatible subset:

```text
codex resume [SESSION_ID]
codex resume
codex resume --last
codex exec [OPTIONS] [PROMPT]
codex exec review [OPTIONS]
codex completion [SHELL]
```

The merge code forwards scoped TUI options, configuration overrides, model
selection, web search, approval policy, and resume-picker flags. Parser tests
use synthetic session IDs and model names so no local rollout metadata appears
in the public source.

`codex exec` reuses the existing `codex-exec` crate, including JSONL output,
output schemas, output-last-message files, non-interactive resume, and review.
It does not add a native illumos sandbox; headless commands run with the Unix
permissions of the Codex process.

Completion scripts are generated from the standalone command tree, so they
only expose the commands shipped by this port.

## Cross-compilation wrappers

`build-tui.sh` configures Cargo target variables for Clang, Clang++, LLVM AR,
LLVM ranlib, and the linker wrapper.

The reusable environment under `scripts/solaris/cross` discovers the sysroot,
host LLVM tools, LLD, and a complete target GCC installation. It exports
standard C/C++ build variables and a generic CMake toolchain. The top-level
`clang-solaris.sh`, `clangxx-solaris.sh`, and `ld.lld` files remain as
compatibility entries.

The compiler wrappers:

- select the Solaris 2.11 ABI
- apply the copied sysroot
- define `__illumos__` for the illumos Rust target
- point Clang at the local LLD wrapper
- add target system and GCC runtime search paths
- embed the target GCC runtime path
- pass through untouched any invocation that requests a non-Solaris
  `--target`, because Cargo build scripts and proc-macros compile for the
  build host even during a cross build and newer upstream revisions build
  host-side C code (for example `libsqlite3-sys` for the state crate's
  build script) through the globally exported `CC`

`cross/bin/ld.lld` translates the Solaris options emitted by Clang into LLD
equivalents, including `-64`, `-G`, `-h`, `-R`, selected `-z` values, and
startup object names.

The generic CMake toolchain enables PIC before feature checks. Without early
PIC, LLD rejects address-taking probes against protected Solaris libc symbols
and projects such as LLVM incorrectly configure functions including
`getpagesize` and `posix_spawn` as unavailable. The standalone `clangd` build
under `scripts/solaris/clangd` consumes this same toolchain.

## Runtime limitations

The following are platform limitations, not gateway failures:

- no native Codex process/filesystem sandbox
- no native clipboard image integration
- no automatic browser launch
- no silent browser-based MCP OAuth
- no Sentry upload

Amazon Bedrock and IDE IPC are compiled for illumos/Solaris but require native
target validation. IDE IPC uses `getpeerucred` to reject peers owned by a
different user.

The self-hosted gateway independently determines whether Responses streaming,
tool calls, model catalogs, and hosted web search work.

## Rebase checklist

When rebasing onto a newer Codex commit:

1. Re-run `cargo tree -p codex-tui --target x86_64-unknown-illumos` and, when
   shipping the full CLI, `cargo tree -p codex-cli --target
   x86_64-unknown-illumos`.
2. Check whether upstream dependencies have gained native illumos support.
3. Keep target-specific `cfg` blocks narrow and preserve other platforms'
   dependency features.
4. Re-run `just bazel-lock-update` after dependency changes.
5. Run `just test -p codex-tui`, the cross-build, remote preflight, and the
   interactive feature matrix.
6. Reconfirm that `get_platform_sandbox()` still returns no backend for
   illumos/Solaris before documenting sandbox behavior.
