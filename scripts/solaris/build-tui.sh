#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/solaris/build-tui.sh [RUST_TARGET]

Without RUST_TARGET, builds natively for the current system.
For x86_64-unknown-illumos or x86_64-pc-solaris cross builds, SOLARIS_SYSROOT
must point to a matching sysroot containing /usr/include, /usr/lib, and /lib.
The release profile is overridden for a parallel size-optimized build:
opt-level=z, thin LTO, parallel codegen, panic=abort, no debug info, and
stripped symbols.
Set NO_STRIP=1 to retain symbols and line tables for diagnostics.
Set CODEX_BUILD_FULL_CLI=1 to build the multipurpose `codex` binary required
by desktop SSH remote connections instead of the standalone TUI.
Set CARGO_BUILD_JOBS or CARGO_PROFILE_RELEASE_CODEGEN_UNITS to override the
detected online CPU count.

Example:
  export SOLARIS_SYSROOT="$HOME/.cache/codex/solaris-sysroot"
  scripts/solaris/build-tui.sh x86_64-unknown-illumos
  CODEX_BUILD_FULL_CLI=1 scripts/solaris/build-tui.sh x86_64-unknown-illumos
EOF
}

detect_parallel_jobs() {
  local jobs=""
  if command -v getconf >/dev/null 2>&1; then
    jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  fi
  if [[ ! "${jobs}" =~ ^[1-9][0-9]*$ ]] && command -v sysctl >/dev/null 2>&1; then
    jobs="$(sysctl -n hw.logicalcpu 2>/dev/null || true)"
  fi
  if [[ ! "${jobs}" =~ ^[1-9][0-9]*$ ]] && command -v nproc >/dev/null 2>&1; then
    jobs="$(nproc 2>/dev/null || true)"
  fi
  if [[ ! "${jobs}" =~ ^[1-9][0-9]*$ ]]; then
    jobs=1
  fi
  printf '%s\n' "${jobs}"
}

if [[ "$#" -gt 1 ]]; then
  usage
  exit 2
fi

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

case "${NO_STRIP:-0}" in
  0|1) ;;
  *)
    echo "NO_STRIP must be 0 or 1." >&2
    exit 2
    ;;
esac

case "${CODEX_BUILD_FULL_CLI:-0}" in
  0|1) ;;
  *)
    echo "CODEX_BUILD_FULL_CLI must be 0 or 1." >&2
    exit 2
    ;;
esac

target="${1:-}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script_dir="${repo_root}/scripts/solaris"
strip_tool=()
cd "${repo_root}/codex-rs"

# Override the workspace release profile without changing Cargo.toml. These
# defaults favor deployment size while keeping optimization parallel.
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$(detect_parallel_jobs)}"
if [[ ! "${CARGO_BUILD_JOBS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "CARGO_BUILD_JOBS must be a positive integer." >&2
  exit 2
fi
export CARGO_PROFILE_RELEASE_OPT_LEVEL="${CARGO_PROFILE_RELEASE_OPT_LEVEL:-z}"
export CARGO_PROFILE_RELEASE_LTO="${CARGO_PROFILE_RELEASE_LTO:-thin}"
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS="${CARGO_PROFILE_RELEASE_CODEGEN_UNITS:-${CARGO_BUILD_JOBS}}"
if [[ ! "${CARGO_PROFILE_RELEASE_CODEGEN_UNITS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "CARGO_PROFILE_RELEASE_CODEGEN_UNITS must be a positive integer." >&2
  exit 2
fi
export CARGO_PROFILE_RELEASE_PANIC="abort"
export CARGO_PROFILE_RELEASE_SPLIT_DEBUGINFO="off"
if [[ "${NO_STRIP:-0}" == "1" ]]; then
  export CARGO_PROFILE_RELEASE_DEBUG="line-tables-only"
  export CARGO_PROFILE_RELEASE_STRIP="none"
else
  export CARGO_PROFILE_RELEASE_DEBUG="none"
  # Cargo also applies profile stripping to host proc-macro dylibs. On macOS
  # that can corrupt cross-build host artifacts, so strip only the final target
  # executable with llvm-strip below.
  export CARGO_PROFILE_RELEASE_STRIP="none"
fi

if [[ "${CODEX_BUILD_FULL_CLI:-0}" == "1" ]]; then
  package="codex-cli"
  binary="codex"
else
  package="codex-tui"
  binary="codex-tui"
fi

build_args=(
  --manifest-path Cargo.toml
  -p "${package}"
  --bin "${binary}"
  --release
  --locked
)

if [[ -n "${target}" ]]; then
  rustup target add "${target}"
  host_target="$(rustc -vV | sed -n 's/^host: //p')"
  if [[ "${target}" =~ ^x86_64-(pc-solaris|unknown-illumos)$ && "${target}" != "${host_target}" ]]; then
    export SOLARIS_RUST_TARGET="${target}"
    cross_env="$("${script_dir}/cross/env.sh")"
    eval "${cross_env}"
    unset cross_env
    sysroot="${SOLARIS_SYSROOT}"

    openssl_include_dir="${sysroot}/usr/include"
    if [[ ! -f "${openssl_include_dir}/openssl/opensslv.h" ]]; then
      echo "Sysroot is missing OpenSSL headers under usr/include/openssl." >&2
      exit 2
    fi
    openssl_libdir=""
    for candidate in "${sysroot}/usr/lib/amd64" "${sysroot}/lib/amd64"; do
      if [[ -e "${candidate}/libssl.so" && -e "${candidate}/libcrypto.so" ]]; then
        openssl_libdir="${candidate}"
        break
      fi
    done
    if [[ -z "${openssl_libdir}" ]]; then
      echo "Sysroot is missing amd64 libssl.so and libcrypto.so." >&2
      exit 2
    fi

    if ! command -v pkg-config >/dev/null 2>&1; then
      echo "Missing pkg-config. Install it with brew (pkgconf), apt (pkg-config)," >&2
      echo "or your platform's package manager." >&2
      exit 2
    fi

    target_env_name="$(printf '%s' "${target}" | tr '[:lower:]-' '[:upper:]_')"
    export "${target_env_name}_OPENSSL_INCLUDE_DIR=${openssl_include_dir}"
    export "${target_env_name}_OPENSSL_LIB_DIR=${openssl_libdir}"
    export AWS_LC_SYS_CMAKE_BUILDER="${AWS_LC_SYS_CMAKE_BUILDER:-0}"

    probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-solaris-probe.XXXXXX")"
    trap 'rm -rf "${probe_dir}"' EXIT
    printf '%s\n' \
      '#include <assert.h>' \
      '#include <sys/types.h>' \
      'int main(void) { return 0; }' \
      >"${probe_dir}/probe.c"
    "${SOLARIS_C_COMPILER_WRAPPER}" \
      -Werror \
      -c "${probe_dir}/probe.c" \
      -o "${probe_dir}/probe.o"
    "${SOLARIS_C_COMPILER_WRAPPER}" \
      "${probe_dir}/probe.o" \
      -o "${probe_dir}/probe"
    probe_program_headers="$("${SOLARIS_READELF}" -l "${probe_dir}/probe")"
    if [[ "${probe_program_headers}" != *"/lib/amd64/ld.so.1"* ]]; then
      echo "Solaris linker probe has the wrong runtime interpreter." >&2
      exit 2
    fi
    rm -rf "${probe_dir}"
    trap - EXIT

    strip_tool=("${SOLARIS_STRIP}" --strip-all)
  elif [[ "${target}" != "${host_target}" ]]; then
    target_env_name="$(printf '%s' "${target}" | tr '[:lower:]-' '[:upper:]_')"
    linker_var="CARGO_TARGET_${target_env_name}_LINKER"
    if [[ -z "${!linker_var:-}" ]]; then
      echo "Set ${linker_var} before cross-compiling for ${target}." >&2
      exit 2
    fi
  fi
  build_args+=(--target "${target}")
fi

echo "Release profile: jobs=${CARGO_BUILD_JOBS}, opt-level=${CARGO_PROFILE_RELEASE_OPT_LEVEL}, lto=${CARGO_PROFILE_RELEASE_LTO}, codegen-units=${CARGO_PROFILE_RELEASE_CODEGEN_UNITS}, panic=abort, debug=${CARGO_PROFILE_RELEASE_DEBUG}, strip=${CARGO_PROFILE_RELEASE_STRIP}"
cargo build "${build_args[@]}"

if [[ -n "${target}" ]]; then
  target_dir="${CARGO_TARGET_DIR:-${repo_root}/codex-rs/target}"
  if [[ "${target_dir}" != /* ]]; then
    target_dir="${repo_root}/codex-rs/${target_dir}"
  fi
  output="${target_dir}/${target}/release/${binary}"
else
  target_dir="${CARGO_TARGET_DIR:-${repo_root}/codex-rs/target}"
  if [[ "${target_dir}" != /* ]]; then
    target_dir="${repo_root}/codex-rs/${target_dir}"
  fi
  output="${target_dir}/release/${binary}"
fi

if [[ "${NO_STRIP:-0}" != "1" ]]; then
  if [[ "${#strip_tool[@]}" -gt 0 ]]; then
    "${strip_tool[@]}" "${output}"
  elif [[ "$(uname -s)" == "Darwin" ]]; then
    /usr/bin/strip -S -x "${output}"
  elif command -v strip >/dev/null 2>&1; then
    strip "${output}"
  fi
fi

ls -lh "${output}"
echo "Built ${output}"
