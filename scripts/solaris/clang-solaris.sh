#!/usr/bin/env bash
set -euo pipefail

: "${SOLARIS_SYSROOT:?SOLARIS_SYSROOT is required}"
: "${SOLARIS_CLANG:?SOLARIS_CLANG is required}"
: "${SOLARIS_LD:?SOLARIS_LD is required}"
: "${SOLARIS_CLANG_TARGET:?SOLARIS_CLANG_TARGET is required}"
: "${SOLARIS_RUST_TARGET:?SOLARIS_RUST_TARGET is required}"
: "${SOLARIS_GCC_RUNTIME_LIBDIR:?SOLARIS_GCC_RUNTIME_LIBDIR is required}"
: "${SOLARIS_GCC_RUNTIME_RPATH:?SOLARIS_GCC_RUNTIME_RPATH is required}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
linking=1
for arg in "$@"; do
  case "${arg}" in
    -c|-E|-S|-M|-MM|-fsyntax-only)
      linking=0
      break
      ;;
  esac
done

args=(
  "--target=${SOLARIS_CLANG_TARGET}"
  "--sysroot=${SOLARIS_SYSROOT}"
)
if [[ "${SOLARIS_RUST_TARGET}" == "x86_64-unknown-illumos" ]]; then
  args+=(-D__illumos__)
fi
if [[ "${linking}" == "1" ]]; then
  args+=(
    "-fuse-ld=${script_dir}/ld.lld"
    "-Wl,--sysroot=${SOLARIS_SYSROOT}"
    "-Wl,--dynamic-linker=/lib/amd64/ld.so.1"
    "-Wl,-L,${SOLARIS_SYSROOT}/usr/lib/amd64"
    "-Wl,-L,${SOLARIS_SYSROOT}/lib/amd64"
    "-Wl,-L,${SOLARIS_GCC_LIBDIR}"
    "-Wl,-L,${SOLARIS_GCC_RUNTIME_LIBDIR}"
    "-Wl,-rpath,${SOLARIS_GCC_RUNTIME_RPATH}"
  )
fi

exec "${SOLARIS_CLANG}" "${args[@]}" "$@"
