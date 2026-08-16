#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: eval "$(scripts/solaris/cross/env.sh)"

Prints shell export statements for the reusable illumos/Solaris C and C++
cross-compilation environment.
EOF
}

case "${1:-}" in
  "")
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac

resolve_script_dir() {
  local source="${BASH_SOURCE[0]}"
  local source_dir
  local link_target

  while [[ -L "${source}" ]]; do
    source_dir="$(cd -P "$(dirname "${source}")" && pwd)"
    link_target="$(readlink "${source}")"
    if [[ "${link_target}" == /* ]]; then
      source="${link_target}"
    else
      source="${source_dir}/${link_target}"
    fi
  done
  cd -P "$(dirname "${source}")" && pwd
}

cross_dir="$(resolve_script_dir)"
sysroot="${SOLARIS_SYSROOT:-${HOME}/.cache/codex/solaris-sysroot}"
if [[ ! -d "${sysroot}" ]]; then
  echo "Solaris sysroot does not exist: ${sysroot}" >&2
  exit 2
fi
sysroot="$(cd "${sysroot}" && pwd)"

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

llvm_prefix="${LLVM_PREFIX:-}"
if [[ -z "${llvm_prefix}" ]] && command -v brew >/dev/null 2>&1; then
  llvm_prefix="$(brew --prefix llvm)"
fi
if [[ -z "${llvm_prefix}" ]] && command -v llvm-config >/dev/null 2>&1; then
  llvm_prefix="$(llvm-config --prefix)"
fi
if [[ -z "${llvm_prefix}" ]]; then
  for candidate in /usr/lib/llvm-* /usr/local/llvm* /opt/llvm*; do
    if [[ -x "${candidate}/bin/clang" ]]; then
      llvm_prefix="${candidate}"
      break
    fi
  done
fi
if [[ -z "${llvm_prefix}" ]]; then
  echo "Install LLVM (brew install llvm, apt install llvm, or an official LLVM" >&2
  echo "release tarball) or set LLVM_PREFIX." >&2
  exit 2
fi
llvm_prefix="$(cd "${llvm_prefix}" && pwd)"

for tool in clang clang++ llvm-ar llvm-ranlib llvm-readelf llvm-strip; do
  if [[ ! -x "${llvm_prefix}/bin/${tool}" ]]; then
    echo "LLVM installation is missing ${tool}: ${llvm_prefix}" >&2
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
if [[ -z "${solaris_ld}" && -x "${llvm_prefix}/bin/ld.lld" ]]; then
  solaris_ld="${llvm_prefix}/bin/ld.lld"
fi
if [[ -z "${solaris_ld}" || ! -x "${solaris_ld}" ]]; then
  echo "Install lld (bundled with LLVM releases and most Linux LLVM packages)," >&2
  echo "set LLD_BIN, or set SOLARIS_LD." >&2
  exit 2
fi
solaris_ld="$(cd "$(dirname "${solaris_ld}")" && pwd)/$(basename "${solaris_ld}")"

rust_target="${SOLARIS_RUST_TARGET:-x86_64-unknown-illumos}"
clang_target="${SOLARIS_CLANG_TARGET:-}"
target_os="${SOLARIS_TARGET_OS:-}"
case "${rust_target}" in
  x86_64-unknown-illumos)
    clang_target="${clang_target:-x86_64-pc-solaris2.11}"
    target_os="${target_os:-illumos}"
    ;;
  x86_64-pc-solaris)
    clang_target="${clang_target:-x86_64-pc-solaris2.11}"
    target_os="${target_os:-solaris}"
    ;;
  *)
    if [[ -z "${clang_target}" || -z "${target_os}" ]]; then
      echo "Set SOLARIS_CLANG_TARGET and SOLARIS_TARGET_OS for ${rust_target}." >&2
      exit 2
    fi
    ;;
esac
target_env_suffix="${rust_target//-/_}"
target_env_name="$(printf '%s' "${rust_target}" | tr '[:lower:]-' '[:upper:]_')"

nullglob_was_set=0
if shopt -q nullglob; then
  nullglob_was_set=1
else
  shopt -s nullglob
fi
if [[ -n "${SOLARIS_GCC_PREFIX:-}" ]]; then
  case "${SOLARIS_GCC_PREFIX}" in
    "${sysroot}"/*) gcc_candidates=("${SOLARIS_GCC_PREFIX}") ;;
    /*) gcc_candidates=("${sysroot}${SOLARIS_GCC_PREFIX}") ;;
    *) gcc_candidates=("${sysroot}/${SOLARIS_GCC_PREFIX}") ;;
  esac
else
  gcc_candidates=("${sysroot}"/opt/local/gcc* "${sysroot}"/usr/gcc/*)
fi

gcc_prefix=""
gcc_libdir=""
gcc_runtime_libdir=""
gcc_cxx_include_dir=""
gcc_cxx_target_include_dir=""
for candidate in "${gcc_candidates[@]}"; do
  cxx_header="$(find "${candidate}/include/c++" \
    -mindepth 2 -maxdepth 2 -type f -name cstddef -print -quit 2>/dev/null || true)"
  [[ -n "${cxx_header}" ]] || continue
  cxx_include_dir="$(dirname "${cxx_header}")"
  target_dirs=("${cxx_include_dir}"/x86_64-*-solaris*)
  cxx_target_dir=""
  for target_dir in "${target_dirs[@]}"; do
    if [[ -f "${target_dir}/bits/c++config.h" ]]; then
      cxx_target_dir="${target_dir}"
      break
    fi
  done
  [[ -n "${cxx_target_dir}" ]] || continue

  crtbegin="$(find "${candidate}/lib/gcc" \
    -type f -name crtbegin.o ! -path '*/32/*' -print -quit 2>/dev/null || true)"
  [[ -n "${crtbegin}" ]] || continue
  [[ -e "${candidate}/lib/amd64/libstdc++.so" ]] || continue
  [[ -e "${candidate}/lib/amd64/libgcc_s.so.1" ]] || continue

  gcc_prefix="${candidate}"
  gcc_libdir="$(dirname "${crtbegin}")"
  gcc_runtime_libdir="${candidate}/lib/amd64"
  gcc_cxx_include_dir="${cxx_include_dir}"
  gcc_cxx_target_include_dir="${cxx_target_dir}"
  break
done
if [[ "${nullglob_was_set}" == "0" ]]; then
  shopt -u nullglob
fi

if [[ -z "${gcc_prefix}" ]]; then
  echo "No complete 64-bit GCC C++ installation found in ${sysroot}." >&2
  echo "Refresh the sysroot or set SOLARIS_GCC_PREFIX." >&2
  exit 2
fi
for required_file in crtbegin.o crtbeginS.o crtend.o crtendS.o libgcc.a; do
  if [[ ! -e "${gcc_libdir}/${required_file}" ]]; then
    echo "Solaris GCC runtime is missing ${required_file}: ${gcc_libdir}" >&2
    exit 2
  fi
done

emit_export() {
  printf 'export %s=%q\n' "$1" "$2"
}

emit_export LLVM_PREFIX "${llvm_prefix}"
emit_export SOLARIS_SYSROOT "${sysroot}"
emit_export SOLARIS_RUST_TARGET "${rust_target}"
emit_export SOLARIS_CLANG_TARGET "${clang_target}"
emit_export SOLARIS_TARGET_OS "${target_os}"
emit_export SOLARIS_CLANG "${llvm_prefix}/bin/clang"
emit_export SOLARIS_CLANGXX "${llvm_prefix}/bin/clang++"
emit_export SOLARIS_LD "${solaris_ld}"
emit_export SOLARIS_AR "${llvm_prefix}/bin/llvm-ar"
emit_export SOLARIS_RANLIB "${llvm_prefix}/bin/llvm-ranlib"
emit_export SOLARIS_READELF "${llvm_prefix}/bin/llvm-readelf"
emit_export SOLARIS_STRIP "${llvm_prefix}/bin/llvm-strip"
emit_export SOLARIS_GCC_PREFIX "/${gcc_prefix#"${sysroot}/"}"
emit_export SOLARIS_GCC_SYSROOT_PREFIX "${gcc_prefix}"
emit_export SOLARIS_GCC_LIBDIR "${gcc_libdir}"
emit_export SOLARIS_GCC_RUNTIME_LIBDIR "${gcc_runtime_libdir}"
emit_export SOLARIS_GCC_RUNTIME_RPATH "/${gcc_runtime_libdir#"${sysroot}/"}"
emit_export SOLARIS_GCC_CXX_INCLUDE_DIR "${gcc_cxx_include_dir}"
emit_export SOLARIS_GCC_CXX_TARGET_INCLUDE_DIR "${gcc_cxx_target_include_dir}"
emit_export SOLARIS_C_COMPILER_WRAPPER "${cross_dir}/bin/clang"
emit_export SOLARIS_CXX_COMPILER_WRAPPER "${cross_dir}/bin/clang++"
emit_export SOLARIS_CMAKE_TOOLCHAIN_FILE "${cross_dir}/toolchain.cmake"
emit_export CC "${cross_dir}/bin/clang"
emit_export CXX "${cross_dir}/bin/clang++"
emit_export AR "${llvm_prefix}/bin/llvm-ar"
emit_export RANLIB "${llvm_prefix}/bin/llvm-ranlib"
emit_export STRIP "${llvm_prefix}/bin/llvm-strip"
emit_export PKG_CONFIG_ALLOW_CROSS 1
emit_export PKG_CONFIG_SYSROOT_DIR "${sysroot}"
emit_export PKG_CONFIG_LIBDIR \
  "${sysroot}/usr/lib/amd64/pkgconfig:${sysroot}/usr/lib/pkgconfig:${sysroot}/usr/share/pkgconfig"
emit_export "CC_${target_env_suffix}" "${cross_dir}/bin/clang"
emit_export "CXX_${target_env_suffix}" "${cross_dir}/bin/clang++"
emit_export "AR_${target_env_suffix}" "${llvm_prefix}/bin/llvm-ar"
emit_export "RANLIB_${target_env_suffix}" "${llvm_prefix}/bin/llvm-ranlib"
emit_export "CARGO_TARGET_${target_env_name}_LINKER" "${cross_dir}/bin/clang"
emit_export "PKG_CONFIG_ALLOW_CROSS_${target_env_suffix}" 1
emit_export "PKG_CONFIG_SYSROOT_DIR_${target_env_suffix}" "${sysroot}"
emit_export "PKG_CONFIG_LIBDIR_${target_env_suffix}" \
  "${sysroot}/usr/lib/amd64/pkgconfig:${sysroot}/usr/lib/pkgconfig:${sysroot}/usr/share/pkgconfig"
