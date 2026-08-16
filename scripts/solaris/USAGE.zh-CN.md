# illumos/Solaris 本地交叉编译使用指引

本文说明如何在 Apple Silicon macOS 上构建可运行于 64 位 x86
illumos/OmniOS 的 C、C++、Rust 和 clangd 程序。

## 目录结构

所有入口都位于仓库的 `scripts/solaris/`：

| 路径 | 用途 |
| --- | --- |
| `cross/` | 通用 C/C++ 交叉编译环境、Clang/LLD 包装器和 CMake toolchain |
| `cross/install.sh` | 将通用 C/C++ 和 Rust 环境安装到 `$HOME/.local` |
| `build-tui.sh` | Rust/Cargo 交叉构建入口 |
| `clangd/` | 使用通用 C/C++ 环境构建 clangd |
| `fetch-sysroot.sh` | 从目标主机提取头文件、库和 GCC runtime |

C/C++、Rust 和 clangd 共用同一份 sysroot、Clang、LLD 和目标 GCC
runtime。

## 1. 安装宿主工具

```sh
brew install llvm lld cmake ninja pkgconf
```

Rust 构建还需要仓库指定的 Rust 工具链：

```sh
cd codex-rs
rustup target add x86_64-unknown-illumos
cd ..
```

## 2. 获取目标 sysroot

目标主机需要安装开发头文件和完整的 64 位 GCC C++ runtime。以下示例使用
SSH 别名 `pkgsrc-dev`：

```sh
scripts/solaris/fetch-sysroot.sh pkgsrc-dev
```

默认保存位置：

```text
$HOME/.cache/codex/solaris-sysroot
```

也可以指定其他目录：

```sh
scripts/solaris/fetch-sysroot.sh \
  pkgsrc-dev \
  "$HOME/.cache/codex/omnios-r151058-sysroot"
```

sysroot 必须与实际部署主机的系统版本和 ABI 匹配。

## 3. 安装到 HOME

执行：

```sh
scripts/solaris/cross/install.sh
```

默认安装布局：

```text
$HOME/.local/bin/solaris-cross-env
$HOME/.local/bin/solaris-cross-check
$HOME/.local/libexec/solaris-cross/
$HOME/.local/share/doc/solaris-cross/USAGE.zh-CN.md
```

该目录包含 C/C++ 编译器包装器、LLD 包装器、CMake toolchain、环境脚本和
使用文档。它不依赖仓库路径，可以在后续项目中直接复用。

确保命令目录在 `PATH` 中：

```sh
export PATH="$HOME/.local/bin:$PATH"
```

也可以指定其他 HOME 内安装前缀：

```sh
scripts/solaris/cross/install.sh "$HOME/tools"
```

## 4. 启用通用 C/C++ 和 Rust 环境

使用安装后的命令：

```sh
export SOLARIS_SYSROOT="$HOME/.cache/codex/solaris-sysroot"
eval "$(solaris-cross-env)"
```

该命令会设置：

- `CC`、`CXX`
- `AR`、`RANLIB`、`STRIP`
- `PKG_CONFIG_SYSROOT_DIR`、`PKG_CONFIG_LIBDIR`
- `SOLARIS_CMAKE_TOOLCHAIN_FILE`
- `CC_x86_64_unknown_illumos`、`CXX_x86_64_unknown_illumos`
- `CARGO_TARGET_X86_64_UNKNOWN_ILLUMOS_LINKER`
- Clang、LLD 和目标 GCC runtime 相关变量

默认目标配置：

```text
Clang target: x86_64-pc-solaris2.11
Rust target:  x86_64-unknown-illumos
ELF loader:   /lib/amd64/ld.so.1
```

如 sysroot 中存在多个 GCC，可以显式选择：

```sh
export SOLARIS_GCC_PREFIX=/opt/local/gcc13
eval "$(solaris-cross-env)"
```

## 5. 编译 C 和 C++

C：

```sh
"$CC" -std=c11 -O2 hello.c -o hello
```

C++：

```sh
"$CXX" -std=c++17 -O2 hello.cc -o hello-cxx
```

检查产物：

```sh
"$SOLARIS_READELF" -h hello
"$SOLARIS_READELF" -l hello
```

产物应为 `x86-64` ELF，并使用：

```text
/lib/amd64/ld.so.1
```

这些程序不能直接在 macOS 上运行，需要复制到目标主机。

## 6. 构建 CMake 项目

先按第 4 节启用环境，然后执行：

```sh
cmake -S . -B build-illumos -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="$SOLARIS_CMAKE_TOOLCHAIN_FILE"

cmake --build build-illumos
```

CMake 会从 sysroot 查找目标头文件、库和 pkg-config 包，同时仍允许在 macOS
上查找构建期间需要运行的宿主工具。

## 7. 验证 C/C++ 环境

仅做本地交叉编译和 ELF 检查：

```sh
SOLARIS_SYSROOT="$HOME/.cache/codex/solaris-sysroot" \
  solaris-cross-check
```

同时复制到目标主机并运行：

```sh
SOLARIS_SYSROOT="$HOME/.cache/codex/solaris-sysroot" \
  solaris-cross-check --ssh pkgsrc-dev
```

脚本会编译 C11 和 C++17 探针，检查 ELF 架构和解释器，并在远程检查
`libstdc++`、`libgcc_s` 等动态库。

## 8. 构建 Rust 程序

对于普通 Rust 项目，先启用安装后的统一环境：

```sh
export SOLARIS_SYSROOT="$HOME/.cache/codex/solaris-sysroot"
eval "$(solaris-cross-env)"
rustup target add x86_64-unknown-illumos
cargo build --target x86_64-unknown-illumos
```

环境已设置 Cargo linker、C/C++ 编译器和 pkg-config 目标变量。

对于本仓库，可使用专用构建入口。

构建独立 Codex TUI：

```sh
export SOLARIS_SYSROOT="$HOME/.cache/codex/solaris-sysroot"
scripts/solaris/build-tui.sh x86_64-unknown-illumos
```

产物：

```text
codex-rs/target/x86_64-unknown-illumos/release/codex-tui
```

构建完整 `codex` CLI：

```sh
CODEX_BUILD_FULL_CLI=1 \
  scripts/solaris/build-tui.sh x86_64-unknown-illumos
```

产物：

```text
codex-rs/target/x86_64-unknown-illumos/release/codex
```

保留调试符号：

```sh
NO_STRIP=1 scripts/solaris/build-tui.sh x86_64-unknown-illumos
```

Rust 构建脚本会自动调用 `cross/` 中的通用 Clang/LLD 环境，无需预先执行
`eval "$(solaris-cross-env)"`。

## 9. 构建 clangd

```sh
export SOLARIS_SYSROOT="$HOME/.cache/codex/solaris-sysroot"
scripts/solaris/clangd/build.sh
```

默认产物：

```text
$HOME/.cache/codex/llvm-clangd-build-<LLVM版本>-illumos/bin/clangd
$HOME/.cache/codex/llvm-clangd-build-<LLVM版本>-illumos/lib/clang/<主版本>/include
```

只生成 CMake/Ninja 配置：

```sh
CONFIGURE_ONLY=1 scripts/solaris/clangd/build.sh
```

clangd 可按以下结构部署：

```text
目标主机：~/.local/bin/clangd
目标主机：~/.local/lib/clang/<主版本>/include
```

## 10. 部署普通程序

示例：

```sh
scp hello pkgsrc-dev:.local/bin/hello
ssh pkgsrc-dev 'chmod 755 ~/.local/bin/hello && ~/.local/bin/hello'
```

部署后检查动态库：

```sh
ssh pkgsrc-dev 'ldd ~/.local/bin/hello'
```

如果 `ldd` 出现 `not found`，应检查 sysroot 是否与目标主机一致，以及
`SOLARIS_GCC_PREFIX` 是否选择了目标主机实际安装的 GCC。

## 11. 常用覆盖变量

| 变量 | 用途 |
| --- | --- |
| `SOLARIS_SYSROOT` | 指定 sysroot |
| `SOLARIS_GCC_PREFIX` | 选择 sysroot 中的目标 GCC，例如 `/opt/local/gcc13` |
| `LLVM_PREFIX` | 指定宿主 LLVM 安装目录 |
| `LLD_BIN` | 指定宿主 `ld.lld` 所在目录 |
| `SOLARIS_LD` | 直接指定宿主 `ld.lld` |
| `SOLARIS_SSH_PROXY_JUMP` | SSH 跳板机 |
| `NO_STRIP=1` | 保留 Rust 或 clangd 调试符号 |
| `CARGO_BUILD_JOBS` | 覆盖 Codex 编译并行任务数；默认使用在线 CPU 数 |
| `CARGO_PROFILE_RELEASE_CODEGEN_UNITS` | 覆盖 release codegen 单元数；默认与编译任务数相同 |

## 12. Code mode（V8 现状）

`codex-code-mode-host` 依赖 V8 引擎（rusty_v8），没有 illumos 预编译产
物，本 port 暂不产出 illumos 版本的该二进制。规划：为
`x86_64-unknown-illumos` 一次性交叉构建 V8 静态库并 vendor 进仓库，通
过官方 `RUSTY_V8_ARCHIVE` 覆盖钩子接入 v8 crate 构建脚本，使该二进制
在 illumos 上原生编译，不依赖任何外部机器。

在原生构建落地之前，目标机上应关闭 code mode，避免模型请求代码执行
时出现 fail-closed 报错：

```toml
[features]
code_mode = false
```

还可以在 `~/.codex/model-catalog.json` 中给特定模型条目显式设置
`"tool_mode": "direct"`，这样无论 feature 开关如何，该模型都不会请求
code mode。

## 快速检查流程

```sh
export SOLARIS_SYSROOT="$HOME/.cache/codex/solaris-sysroot"

# 验证 C/C++ 编译和远程运行
solaris-cross-check --ssh pkgsrc-dev

# 使用全部在线 CPU 构建完整 Codex CLI
CODEX_BUILD_FULL_CLI=1 \
  scripts/solaris/build-tui.sh x86_64-unknown-illumos

# 仅验证 clangd 配置
CONFIGURE_ONLY=1 scripts/solaris/clangd/build.sh
```
