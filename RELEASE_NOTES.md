# Preview 3

Preview 3 switches the project from a full source fork to a minimal port kit
based directly on upstream Codex.

## Provenance

- Upstream Codex: `dae21222149bcdcc31534b5a02fceae933081906`
- Rust target: `x86_64-unknown-illumos`
- Verified runtime: OmniOS r151058, amd64
- Verified date: August 4, 2026

## Changes

- builds the complete upstream `codex` CLI
- keeps only minimal illumos compile compatibility patches
- includes `codex app-server proxy` for Desktop SSH connections
- works around the ksh93 Desktop ready-marker incompatibility
- keeps web search and the normal upstream CLI command surface
- removes the duplicated upstream source tree from this repository

## Limitations

- dynamically linked against the target sysroot ABI
- native image clipboard access is unavailable
- native Codex sandboxing is unavailable
- not an official OpenAI release
