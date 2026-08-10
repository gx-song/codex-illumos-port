#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/solaris/clangd/build.sh

Cross-builds clangd for 64-bit x86 illumos from macOS. It uses the reusable
C/C++ environment under scripts/solaris/cross.

Optional environment variables:
  LLVM_PREFIX        Matching native LLVM installation
  LLVM_VERSION       LLVM release to fetch and build
  LLVM_SOURCE_DIR    Existing llvm-project checkout
  LLVM_BUILD_DIR     CMake/Ninja build directory
  SOLARIS_GCC_PREFIX Target GCC prefix, such as /opt/local/gcc13
  JOBS               Parallel compile jobs (default: 6)
  FETCH_LLVM          Clone the exact LLVM tag when source is absent (0 or 1)
  CONFIGURE_ONLY     Stop after generating the Ninja build (0 or 1)
  NO_STRIP           Retain symbols in the final clangd binary (0 or 1)

The default source and build directories are under $HOME/.cache/codex.
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  "")
    ;;
  *)
    usage
    exit 2
    ;;
esac

for flag_name in FETCH_LLVM CONFIGURE_ONLY NO_STRIP; do
  flag_value="${!flag_name:-}"
  case "${flag_value:-0}" in
    0|1) ;;
    *)
      echo "${flag_name} must be 0 or 1." >&2
      exit 2
      ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
solaris_dir="${repo_root}/scripts/solaris"

for command in cmake git ninja; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "Missing build command: ${command}" >&2
    exit 2
  fi
done

export SOLARIS_RUST_TARGET=x86_64-unknown-illumos
cross_env="$("${solaris_dir}/cross/env.sh")"
eval "${cross_env}"
unset cross_env
llvm_prefix="${SOLARIS_CLANG%/bin/clang}"

for tool in \
  clang-tblgen \
  llvm-config \
  llvm-tblgen
do
  if [[ ! -x "${llvm_prefix}/bin/${tool}" ]]; then
    echo "LLVM installation is missing ${tool}: ${llvm_prefix}" >&2
    exit 2
  fi
done

llvm_version="${LLVM_VERSION:-$("${llvm_prefix}/bin/llvm-config" --version)}"
native_version="$("${llvm_prefix}/bin/llvm-config" --version)"
if [[ "${llvm_version}" != "${native_version}" ]]; then
  echo "LLVM_VERSION=${llvm_version} does not match host tools ${native_version}." >&2
  exit 2
fi

cache_root="${CODEX_CACHE_DIR:-${HOME}/.cache/codex}"
source_dir="${LLVM_SOURCE_DIR:-${cache_root}/llvm-project-${llvm_version}}"
build_dir="${LLVM_BUILD_DIR:-${cache_root}/llvm-clangd-build-${llvm_version}-illumos}"

if [[ ! -f "${source_dir}/llvm/CMakeLists.txt" ]]; then
  if [[ "${FETCH_LLVM:-1}" != "1" ]]; then
    echo "LLVM source is absent and FETCH_LLVM=0: ${source_dir}" >&2
    exit 2
  fi
  if [[ -e "${source_dir}" ]]; then
    echo "LLVM_SOURCE_DIR exists but is not an llvm-project checkout: ${source_dir}" >&2
    exit 2
  fi
  mkdir -p "$(dirname "${source_dir}")"
  git clone \
    --depth 1 \
    --branch "llvmorg-${llvm_version}" \
    --filter=blob:none \
    https://github.com/llvm/llvm-project.git \
    "${source_dir}"
fi

jobs="${JOBS:-6}"
case "${jobs}" in
  ''|*[!0-9]*|0)
    echo "JOBS must be a positive integer." >&2
    exit 2
    ;;
esac

cmake \
  -G Ninja \
  -S "${source_dir}/llvm" \
  -B "${build_dir}" \
  -DCMAKE_TOOLCHAIN_FILE="${SOLARIS_CMAKE_TOOLCHAIN_FILE}" \
  -DCMAKE_BUILD_TYPE=Release \
  '-DLLVM_ENABLE_PROJECTS=clang;clang-tools-extra' \
  -DLLVM_TARGETS_TO_BUILD="${LLVM_TARGETS_TO_BUILD:-X86}" \
  -DLLVM_TARGET_ARCH=X86 \
  -DLLVM_HOST_TRIPLE="${SOLARIS_CLANG_TARGET}" \
  -DLLVM_DEFAULT_TARGET_TRIPLE="${SOLARIS_CLANG_TARGET}" \
  -DLLVM_NATIVE_TOOL_DIR="${llvm_prefix}/bin" \
  -DLLVM_ENABLE_ASSERTIONS=OFF \
  -DLLVM_ENABLE_BACKTRACES=OFF \
  -DLLVM_ENABLE_BINDINGS=OFF \
  -DLLVM_ENABLE_LIBEDIT=OFF \
  -DLLVM_ENABLE_LIBXML2=OFF \
  -DLLVM_ENABLE_ZLIB=OFF \
  -DLLVM_ENABLE_ZSTD=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_INCLUDE_DOCS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DCLANG_INCLUDE_DOCS=OFF \
  -DCLANG_INCLUDE_TESTS=OFF \
  -DCLANG_ENABLE_OBJC_REWRITER=OFF \
  -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
  -DCLANGD_BUILD_DEXP=OFF \
  -DCLANGD_BUILD_XPC=OFF \
  -DCLANGD_TIDY_CHECKS=OFF \
  -DCLANG_TIDY_ENABLE_STATIC_ANALYZER=OFF \
  -DLLVM_PARALLEL_COMPILE_JOBS="${jobs}" \
  -DLLVM_PARALLEL_LINK_JOBS=1

if [[ "${CONFIGURE_ONLY:-0}" == "1" ]]; then
  echo "clangd cross-build configured at ${build_dir}"
  exit 0
fi

cmake --build "${build_dir}" --target clangd -j "${jobs}"

clangd="${build_dir}/bin/clangd"
resource_dir="${build_dir}/lib/clang/${llvm_version%%.*}/include"
if [[ ! -x "${clangd}" || ! -f "${resource_dir}/stddef.h" ]]; then
  echo "clangd build did not produce the expected deployment layout." >&2
  exit 1
fi

if [[ "${NO_STRIP:-0}" != "1" ]]; then
  "${SOLARIS_STRIP}" --strip-all "${clangd}"
fi

readelf="${SOLARIS_READELF}"
elf_header="$("${readelf}" -h "${clangd}")"
program_headers="$("${readelf}" -l "${clangd}")"
if ! grep -q 'Machine:.*X86-64' <<<"${elf_header}"; then
  echo "clangd is not an x86-64 ELF executable." >&2
  exit 1
fi
if ! grep -q '/lib/amd64/ld.so.1' <<<"${program_headers}"; then
  echo "clangd has the wrong runtime interpreter." >&2
  exit 1
fi

echo "clangd: ${clangd}"
echo "resource headers: ${resource_dir}"
echo "target GCC runtime: ${SOLARIS_GCC_RUNTIME_RPATH}"
