#!/usr/bin/env bash
#
# Build the illumos-native `codex-code-mode-host` against the vendored V8
# static archive. This avoids rebuilding V8 from source: the archive under
# `scripts/solaris/vendor/librusty_v8.a` is consumed through the official
# `RUSTY_V8_ARCHIVE` override, and the matching generated binding is supplied
# through `RUSTY_V8_SRC_BINDING_PATH`.
#
# Prerequisites (same as the rest of the illumos cross build):
#   - LLVM/Clang + lld (set LLVM_PREFIX, or let env.sh discover it)
#   - an illumos sysroot (set SOLARIS_SYSROOT, or use the default cache path)
#   - the rust toolchain from codex-rs/rust-toolchain.toml with the
#     x86_64-unknown-illumos target installed
#
# Usage:
#   scripts/solaris/build-code-mode-host.sh [--release]
#
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
vendor_dir="${script_dir}/vendor"
archive="${vendor_dir}/librusty_v8.a"
binding="${vendor_dir}/src_binding_prefixed.rs"

if [[ ! -f "${archive}" ]]; then
  echo "Vendored V8 archive not found: ${archive}" >&2
  echo "Run the one-time V8 cross build, then place the archive here." >&2
  exit 2
fi
if [[ ! -f "${binding}" ]]; then
  echo "Vendored V8 binding not found: ${binding}" >&2
  exit 2
fi

profile=""
if [[ "${1:-}" == "--release" ]]; then
  profile="--release"
fi

cd "${repo_root}/codex-rs"

# Reuse the cross-compilation environment (CC/CXX, linker, sysroot, LLVM tools).
cross_env="$(bash "${script_dir}/cross/env.sh")"
eval "${cross_env}"

export RUSTY_V8_ARCHIVE="${archive}"
export RUSTY_V8_SRC_BINDING_PATH="${binding}"

exec cargo build -p codex-code-mode-host \
  --target x86_64-unknown-illumos \
  ${profile} \
  --locked
