# Codex TUI for illumos - Preview 1

This is an unofficial, experimental build of the standalone Codex terminal UI
for 64-bit x86 illumos systems. It is not an OpenAI-supported illumos or
Solaris release.

## Build provenance

- Release tag: `illumos-preview-1`
- Upstream Codex base: `4642370542739d5dd080b0c87a9de06a6435d3db`
- Rust target: `x86_64-unknown-illumos`
- Rust: `1.95.0`
- LLVM and LLD: `22.1.8`
- Build host: macOS with Homebrew
- Verified runtime: OmniOS r151058, amd64

Compatibility with Oracle Solaris or other illumos distributions has not been
verified.

## Included functionality

- interactive SSH terminal UI
- self-hosted OpenAI Responses-compatible gateways
- streaming model responses
- shell and filesystem tools
- `apply_patch`
- approvals and interruption
- session history and `codex resume`
- gateway-provided web search
- text copy through terminal mechanisms such as OSC52 or tmux

## Known limitations

- no native Codex process or filesystem sandbox
- no automatic desktop browser launch
- no browser-based OpenAI login
- no native image clipboard integration
- no silent browser-based MCP OAuth
- no Sentry feedback upload
- no Amazon Bedrock provider
- no IDE IPC integration

Run Codex inside an illumos zone or another externally isolated account when
OS-enforced isolation is required.

## Runtime dependencies

The binary is dynamically linked and was verified with:

- `liblzma.so.5`
- `libsocket.so.1`
- `librt.so.1`
- `libpthread.so.1`
- `libnsl.so.1`
- `libumem.so.1`
- `libgcc_s.so.1`
- `libm.so.2`
- `libc.so.1`

The tested build uses the RUNPATH `/opt/local/gcc13/lib/amd64`. Run `ldd` on
the target before starting Codex.

## Install

Extract the release archive and install the executable:

```sh
tar -xzf codex-x86_64-unknown-illumos-omnios-r151058.tar.gz
mkdir -p "$HOME/.local/bin"
cp codex-x86_64-unknown-illumos-omnios-r151058/codex \
  "$HOME/.local/bin/codex"
chmod 755 "$HOME/.local/bin/codex"
```

Verify the downloaded archive before extracting:

```sh
digest -a sha256 codex-x86_64-unknown-illumos-omnios-r151058.tar.gz
cat SHA256SUMS
```

Configure a self-hosted gateway using the redacted example in
`scripts/solaris/config.toml`. The gateway must implement the OpenAI Responses
protocol, including streaming and the tool-call forms used by Codex.

See `scripts/solaris/README.md` for build and deployment details and
`scripts/solaris/CORE_FEATURE_TEST.md` for the validation matrix.
