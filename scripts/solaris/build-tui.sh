#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/solaris/build-tui.sh [RUST_TARGET]

Without RUST_TARGET, builds natively for the current system.
For x86_64-unknown-illumos or x86_64-pc-solaris cross builds, SOLARIS_SYSROOT
must point to a matching sysroot containing /usr/include, /usr/lib, and /lib.
The release profile is overridden for minimum size: opt-level=z, fat LTO,
one codegen unit, panic=abort, no debug info, and stripped symbols.
Set NO_STRIP=1 to retain symbols and line tables for diagnostics.

Example:
  export SOLARIS_SYSROOT="$HOME/.cache/codex/solaris-sysroot"
  scripts/solaris/build-tui.sh x86_64-unknown-illumos
EOF
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

target="${1:-}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script_dir="${repo_root}/scripts/solaris"
strip_tool=()
cd "${repo_root}/codex-rs"

# Override the workspace release profile without changing Cargo.toml. These
# defaults favor deployment size and spend more CPU/RAM on the local builder.
export CARGO_PROFILE_RELEASE_OPT_LEVEL="${CARGO_PROFILE_RELEASE_OPT_LEVEL:-z}"
export CARGO_PROFILE_RELEASE_LTO="${CARGO_PROFILE_RELEASE_LTO:-fat}"
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS="${CARGO_PROFILE_RELEASE_CODEGEN_UNITS:-1}"
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

build_args=(
  --manifest-path Cargo.toml
  -p codex-tui
  --bin codex-tui
  --release
  --locked
)

if [[ -n "${target}" ]]; then
  rustup target add "${target}"
  host_target="$(rustc -vV | sed -n 's/^host: //p')"
  if [[ "${target}" =~ ^x86_64-(pc-solaris|unknown-illumos)$ && "${target}" != "${host_target}" ]]; then
    : "${SOLARIS_SYSROOT:?Set SOLARIS_SYSROOT to the extracted Solaris sysroot.}"
    sysroot="$(cd "${SOLARIS_SYSROOT}" && pwd)"

    for required_file in \
      usr/include/assert.h \
      usr/include/sys/types.h \
      usr/lib/amd64/crt1.o \
      usr/lib/amd64/crti.o \
      usr/lib/amd64/crtn.o \
      usr/lib/amd64/values-Xa.o \
      usr/lib/amd64/values-xpg6.o
    do
      if [[ ! -f "${sysroot}/${required_file}" ]]; then
        echo "Solaris sysroot is missing ${required_file}: ${sysroot}" >&2
        exit 2
      fi
    done

    gcc_crtbegin="$(find "${sysroot}/usr/gcc" "${sysroot}"/opt/local/gcc* \
      -type f -name crtbegin.o ! -path '*/32/*' -print -quit 2>/dev/null || true)"
    if [[ -z "${gcc_crtbegin}" ]]; then
      echo "Sysroot is missing an amd64 GCC crtbegin.o under usr/gcc or opt/local/gcc*." >&2
      exit 2
    fi
    gcc_libdir="$(dirname "${gcc_crtbegin}")"
    gcc_root="${gcc_libdir%%/lib/gcc/*}"
    for required_file in crtbegin.o crtbeginS.o crtend.o crtendS.o libgcc.a; do
      if [[ ! -e "${gcc_libdir}/${required_file}" ]]; then
        echo "Solaris GCC runtime is missing ${required_file}: ${gcc_libdir}" >&2
        exit 2
      fi
    done
    gcc_runtime="$(find "${gcc_root}" -type f -name libgcc_s.so.1 \
      ! -path '*/32/*' -print -quit 2>/dev/null || true)"
    if [[ -z "${gcc_runtime}" ]]; then
      echo "Sysroot is missing an amd64 libgcc_s.so.1." >&2
      exit 2
    fi
    gcc_runtime_libdir="$(dirname "${gcc_runtime}")"
    gcc_runtime_rpath="/${gcc_runtime_libdir#"${sysroot}/"}"

    llvm_prefix="${LLVM_PREFIX:-}"
    if [[ -z "${llvm_prefix}" ]] && command -v brew >/dev/null 2>&1; then
      llvm_prefix="$(brew --prefix llvm)"
    fi

    clang="${SOLARIS_CLANG:-${llvm_prefix:+${llvm_prefix}/bin/clang}}"
    clangxx="${SOLARIS_CLANGXX:-${llvm_prefix:+${llvm_prefix}/bin/clang++}}"
    llvm_ar="${SOLARIS_AR:-${llvm_prefix:+${llvm_prefix}/bin/llvm-ar}}"
    llvm_ranlib="${SOLARIS_RANLIB:-${llvm_prefix:+${llvm_prefix}/bin/llvm-ranlib}}"
    llvm_readelf="${SOLARIS_READELF:-${llvm_prefix:+${llvm_prefix}/bin/llvm-readelf}}"
    llvm_strip="${SOLARIS_STRIP:-${llvm_prefix:+${llvm_prefix}/bin/llvm-strip}}"

    for tool in \
      "${clang}" \
      "${clangxx}" \
      "${llvm_ar}" \
      "${llvm_ranlib}" \
      "${llvm_readelf}" \
      "${llvm_strip}"
    do
      if [[ -z "${tool}" || ! -x "${tool}" ]]; then
        echo "Missing LLVM tool: ${tool:-unset}. Install Homebrew llvm or set LLVM_PREFIX." >&2
        exit 2
      fi
    done

    solaris_ld="${SOLARIS_LD:-}"
    if [[ -z "${solaris_ld}" ]]; then
      lld_bin="${LLD_BIN:-}"
      if [[ -z "${lld_bin}" ]] && command -v brew >/dev/null 2>&1; then
        lld_bin="$(brew --prefix lld)/bin"
      fi
      solaris_ld="${lld_bin:+${lld_bin}/ld.lld}"
    fi
    if [[ -z "${solaris_ld}" || ! -x "${solaris_ld}" ]]; then
      echo "Missing ld.lld. Install Homebrew lld or set SOLARIS_LD." >&2
      exit 2
    fi

    if ! command -v pkg-config >/dev/null 2>&1; then
      echo "Missing pkg-config. Install Homebrew pkgconf." >&2
      exit 2
    fi

    export SOLARIS_SYSROOT="${sysroot}"
    export SOLARIS_CLANG="${clang}"
    export SOLARIS_CLANGXX="${clangxx}"
    export SOLARIS_RUST_TARGET="${target}"
    if [[ "${target}" == "x86_64-unknown-illumos" ]]; then
      # Clang recognizes the illumos frontend triple but its Darwin-hosted
      # driver emits macOS linker flags. The Solaris 2.11 driver uses the
      # matching illumos ABI and emits the expected Sun linker arguments.
      export SOLARIS_CLANG_TARGET="x86_64-pc-solaris2.11"
    else
      export SOLARIS_CLANG_TARGET="${target}"
    fi
    export SOLARIS_LD="${solaris_ld}"
    export SOLARIS_GCC_LIBDIR="${gcc_libdir}"
    export SOLARIS_GCC_RUNTIME_LIBDIR="${gcc_runtime_libdir}"
    export SOLARIS_GCC_RUNTIME_RPATH="${gcc_runtime_rpath}"
    target_env_suffix="${target//-/_}"
    target_env_name="$(printf '%s' "${target}" | tr '[:lower:]-' '[:upper:]_')"
    export "CC_${target_env_suffix}=${script_dir}/clang-solaris.sh"
    export "CXX_${target_env_suffix}=${script_dir}/clangxx-solaris.sh"
    export "AR_${target_env_suffix}=${llvm_ar}"
    export "RANLIB_${target_env_suffix}=${llvm_ranlib}"
    export "CARGO_TARGET_${target_env_name}_LINKER=${script_dir}/clang-solaris.sh"
    export "PKG_CONFIG_ALLOW_CROSS_${target_env_suffix}=1"
    export "PKG_CONFIG_SYSROOT_DIR_${target_env_suffix}=${sysroot}"
    export "PKG_CONFIG_LIBDIR_${target_env_suffix}=${sysroot}/usr/lib/amd64/pkgconfig:${sysroot}/usr/lib/pkgconfig:${sysroot}/usr/share/pkgconfig"
    export AWS_LC_SYS_CMAKE_BUILDER="${AWS_LC_SYS_CMAKE_BUILDER:-0}"

    probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-solaris-probe.XXXXXX")"
    trap 'rm -rf "${probe_dir}"' EXIT
    printf '%s\n' \
      '#include <assert.h>' \
      '#include <sys/types.h>' \
      'int main(void) { return 0; }' \
      >"${probe_dir}/probe.c"
    "${script_dir}/clang-solaris.sh" \
      -Werror \
      -c "${probe_dir}/probe.c" \
      -o "${probe_dir}/probe.o"
    "${script_dir}/clang-solaris.sh" \
      "${probe_dir}/probe.o" \
      -o "${probe_dir}/probe"
    probe_program_headers="$("${llvm_readelf}" -l "${probe_dir}/probe")"
    if [[ "${probe_program_headers}" != *"/lib/amd64/ld.so.1"* ]]; then
      echo "Solaris linker probe has the wrong runtime interpreter." >&2
      exit 2
    fi
    rm -rf "${probe_dir}"
    trap - EXIT

    strip_tool=("${llvm_strip}" --strip-all)
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

echo "Release profile: opt-level=${CARGO_PROFILE_RELEASE_OPT_LEVEL}, lto=${CARGO_PROFILE_RELEASE_LTO}, codegen-units=${CARGO_PROFILE_RELEASE_CODEGEN_UNITS}, panic=abort, debug=${CARGO_PROFILE_RELEASE_DEBUG}, strip=${CARGO_PROFILE_RELEASE_STRIP}"
cargo build "${build_args[@]}"

if [[ -n "${target}" ]]; then
  target_dir="${CARGO_TARGET_DIR:-${repo_root}/codex-rs/target}"
  if [[ "${target_dir}" != /* ]]; then
    target_dir="${repo_root}/codex-rs/${target_dir}"
  fi
  output="${target_dir}/${target}/release/codex-tui"
else
  target_dir="${CARGO_TARGET_DIR:-${repo_root}/codex-rs/target}"
  if [[ "${target_dir}" != /* ]]; then
    target_dir="${repo_root}/codex-rs/${target_dir}"
  fi
  output="${target_dir}/release/codex-tui"
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
