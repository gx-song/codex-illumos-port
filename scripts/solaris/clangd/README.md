# clangd for illumos

This directory contains the LLVM-specific CMake/Ninja build for producing
`clangd` on Apple Silicon macOS for a 64-bit x86 illumos host.

It consumes the reusable C/C++ environment in
[`../cross`](../cross/README.md), but it does not invoke Cargo or build any
Codex crates.

## Verified configuration

The following combination was built and run on August 4, 2026:

| Component | Tested value |
| --- | --- |
| LLVM source and native tools | `22.1.8` |
| Build host | Apple Silicon macOS |
| Target ABI | `x86_64-pc-solaris2.11` with `__illumos__` |
| Target runtime | OmniOS r151058, amd64 |
| Target C++ runtime | pkgsrc GCC 13.4.0 |

The resulting `clangd --version` reports platform
`x86_64-pc-solaris2.11`. A remote `clangd --check` using the GCC 13 standard
library completed without diagnostics.

## Prerequisites

Create the Solaris sysroot as described in the parent
[README](../README.md), then install the native build tools:

```sh
brew install llvm lld cmake ninja
```

The host LLVM tools and LLVM source release must match exactly because the
cross-build reuses native `llvm-tblgen` and `clang-tblgen`.

The sysroot must contain one complete 64-bit GCC C++ installation with:

- `include/c++/<version>`
- `lib/gcc/<triple>/<version>/crtbegin.o`
- `lib/amd64/libstdc++.so`
- `lib/amd64/libgcc_s.so.1`

The tested sysroot provides these under `/opt/local/gcc13`.

## Build

```sh
export SOLARIS_SYSROOT="$HOME/.cache/codex/solaris-sysroot"
scripts/solaris/clangd/build.sh
```

By default, the script:

- derives the LLVM version from Homebrew `llvm-config`
- shallow-clones the matching official `llvmorg-<version>` tag when needed
- stores source and build files under `$HOME/.cache/codex`
- builds only the X86 target and the libraries needed by `clangd`
- disables tests, examples, docs, optional compression libraries, and all
  clang-tidy checks
- strips the final executable

For the verified LLVM 22.1.8 build, the source checkout occupied about 2.6 GiB
and the build directory about 580 MiB before stripping.

Use an existing source checkout or stop after CMake configuration with:

```sh
LLVM_SOURCE_DIR=/path/to/llvm-project \
CONFIGURE_ONLY=1 \
  scripts/solaris/clangd/build.sh
```

The output paths are:

```text
$LLVM_BUILD_DIR/bin/clangd
$LLVM_BUILD_DIR/lib/clang/<major>/include
```

The default build directory is:

```text
$HOME/.cache/codex/llvm-clangd-build-<version>-illumos
```

Both are required for deployment. The resource headers are located relative to
the executable, so a normal user installation uses:

```text
$HOME/.local/bin/clangd
$HOME/.local/lib/clang/<major>/include
```

## Why PIC is required during configuration

Solaris libc exports many functions with protected visibility. CMake feature
checks take the address of functions such as `getpagesize`, `sysconf`,
`getrusage`, and `posix_spawn`. LLD rejects the resulting non-PIC relocations,
which makes available functions appear missing.

The shared CMake toolchain under `../cross` enables PIC before CMake runs those
checks. This avoids hardcoded feature overrides and lets LLVM generate the
correct target configuration.

## Runtime dependencies

The verified binary resolved:

```text
librt.so.1
libdl.so.1
libm.so.2
libsocket.so.1
libkstat.so.1
libstdc++.so.6
libgcc_s.so.1
libc.so.1
```

The linker wrapper embeds the selected GCC runtime directory in RUNPATH. Run
`ldd ~/.local/bin/clangd` after deployment because another illumos image may
use a different GCC prefix.
