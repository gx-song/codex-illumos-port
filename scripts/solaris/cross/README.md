# Reusable illumos/Solaris C and C++ cross environment

This directory provides a reusable Clang/LLD cross environment for building
64-bit x86 illumos or Solaris programs on macOS. It is independent of Cargo,
Codex, and the LLVM/clangd source tree.

The environment includes:

- sysroot and target GCC discovery
- C and C++ compiler drivers
- Solaris-to-LLD linker argument translation
- `CC`, `CXX`, binutils, and pkg-config variables
- Cargo linker and target-specific compiler variables
- a general CMake toolchain
- local ELF checks and optional remote runtime checks

## Setup

Fetch a sysroot and install the host tools:

```sh
scripts/solaris/fetch-sysroot.sh pkgsrc-dev
brew install llvm lld cmake ninja pkgconf
```

Install the reusable environment under `$HOME/.local`:

```sh
scripts/solaris/cross/install.sh
```

Configure the current shell using the installed command:

```sh
export SOLARIS_SYSROOT="$HOME/.cache/codex/solaris-sysroot"
eval "$(solaris-cross-env)"
```

The repository entry remains available as
`eval "$(scripts/solaris/cross/env.sh)"`.

The default target is illumos:

```text
Rust target:  x86_64-unknown-illumos
Clang ABI:    x86_64-pc-solaris2.11
Interpreter: /lib/amd64/ld.so.1
```

Set `SOLARIS_GCC_PREFIX=/opt/local/gcc13` to select a specific GCC installation
inside the sysroot. `LLVM_PREFIX`, `LLD_BIN`, and `SOLARIS_LD` can override the
host tool locations.

## Direct compilation

After evaluating `env.sh`, standard build variables point to the cross tools:

```sh
"$CC" -std=c11 hello.c -o hello
"$CXX" -std=c++17 hello.cc -o hello-cxx
"$SOLARIS_READELF" -l hello
```

The output is an x86-64 ELF executable and cannot run directly on macOS.

## CMake

Pass the exported toolchain path to any ordinary CMake project:

```sh
cmake -S . -B build-illumos -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$SOLARIS_CMAKE_TOOLCHAIN_FILE"
cmake --build build-illumos
```

CMake searches target headers, libraries, and packages only inside the
sysroot. Host build programs are still found outside it.

## Validation

Compile C11 and C++17 probes and inspect their ELF metadata:

```sh
scripts/solaris/cross/check.sh
```

Also copy and run the probes on the target:

```sh
scripts/solaris/cross/check.sh --ssh pkgsrc-dev
```

The remote check uses `~/.cache/codex-solaris-cross-check` temporarily and
removes it after a successful run.

After installation, use `solaris-cross-check` in place of the repository path.
