# illumos/Solaris Porting Notes

These notes describe the source changes required by the standalone TUI port.
They are intended for code review and rebasing onto newer Codex revisions.

The build script executes Cargo from `codex-rs` so the repository's
`rust-toolchain.toml` controls the compiler and installed target.

## Build scope

The build command selects:

```text
-p codex-tui --bin codex-tui
```

This avoids building the multipurpose CLI and `codex-code-mode-host`, but it
does not remove the TUI's normal internal dependencies. In particular,
`codex-app-server-client`, `codex-app-server-protocol`, `codex-exec-server`,
and `codex-core` remain part of the dependency graph.

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
- Amazon Bedrock authentication dependencies

The corresponding Rust APIs remain present and return explicit unsupported
errors where callers require a stable interface.

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

The Bedrock provider is replaced by a small unsupported provider
implementation so the common provider API remains exhaustive without compiling
the unsupported AWS authentication stack.

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
subcommands. Because this port ships `codex-tui` directly, its binary entry
point adds the compatible subset:

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

`clang-solaris.sh` and `clangxx-solaris.sh`:

- select the Solaris 2.11 ABI
- apply the copied sysroot
- define `__illumos__` for the illumos Rust target
- point Clang at the local LLD wrapper
- add target system and GCC runtime search paths
- embed the target GCC runtime path

`ld.lld` translates the Solaris options emitted by Clang into LLD equivalents,
including `-64`, `-G`, `-h`, `-R`, selected `-z` values, and startup object
names.

## Runtime limitations

The following are platform limitations, not gateway failures:

- no native Codex process/filesystem sandbox
- no native clipboard image integration
- no automatic browser launch
- no silent browser-based MCP OAuth
- no Sentry upload
- no Amazon Bedrock provider
- no IDE IPC integration

The self-hosted gateway independently determines whether Responses streaming,
tool calls, model catalogs, and hosted web search work.

## Rebase checklist

When rebasing onto a newer Codex commit:

1. Re-run `cargo tree -p codex-tui --target x86_64-unknown-illumos`.
2. Check whether upstream dependencies have gained native illumos support.
3. Keep target-specific `cfg` blocks narrow and preserve other platforms'
   dependency features.
4. Re-run `just bazel-lock-update` after dependency changes.
5. Run `just test -p codex-tui`, the cross-build, remote preflight, and the
   interactive feature matrix.
6. Reconfirm that `get_platform_sandbox()` still returns no backend for
   illumos/Solaris before documenting sandbox behavior.
