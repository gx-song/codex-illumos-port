# Vendored illumos V8

The archive and bindings in `vendor/` must match the exact `v8` version in
`codex-rs/Cargo.toml`. `build-code-mode-host.sh` verifies their version and
SHA-256 checksums against `vendor/manifest.json` before invoking Cargo.

## V8 152.2.0 configuration

Source: the published `v8` 152.2.0 crate (V8 15.2.124.1), including its pinned
Chromium dependencies. The build host is macOS arm64 with LLVM/Clang 23.1.1,
GN and Ninja. Use a private copy of the target OmniOS r151058 sysroot; do not
change the sysroot used by ordinary Rust builds.

Apply both patches from the crate root:

```sh
git apply --directory=v8 -p3 /path/to/codex/patches/v8_array_sort_elements_kind.patch
git apply /path/to/codex/scripts/solaris/v8-152.2.0-illumos.patch
git apply /path/to/codex/scripts/solaris/v8-152.2.0-build.patch
```

The first patch preserves the workspace's V8 Array.sort safety fix. The second
handles Solaris integer types, timezone fields, thread stack attributes,
unsupported Linux memory calls, and host/target guards for Wasm memory mapping.
The build patch supports macOS Command Line Tools without full Xcode, avoids
linking a Linux compiler runtime into the Solaris archive, and selects pthread
mutex initialization guards instead of Linux futexes for libc++abi.

The crate omits ICU's data file. Obtain `common/icudtl.dat` from Chromium ICU
revision `d578f2e8b7bd5938e21cfb6bf15c079e0aa5b738` and place it under
`third_party/icu/common/icudtl.dat`. Keep that revision aligned with the crate's
`DEPS` file.

Prepare the private sysroot headers for the bundled libc++:

- In `iso/math_iso.h`, `iso/stdlib_iso.h`, `math.h` and `stdlib.h`, append
  `&& !defined(__clang__)` to `#if __cplusplus >= 199711L`. This lets libc++ own
  `namespace std`.
- Rename the header macro `__sentinel` and its uses to `__illumos_sentinel`,
  matching whole identifiers. Otherwise it collides with libc++ ranges types.
- Compile target C++ with `-D_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE`,
  `-D__EXTENSIONS__` and `-D__illumos__`.

Create a `build/toolchain/illumos/BUILD.gn` using `gcc_toolchain("x64")` from
`//build/toolchain/gcc_toolchain.gni`. Set `cc` and `cxx` to wrappers around the
host LLVM compiler, `ar`/`nm` to LLVM's tools, `ld = cxx`, and toolchain args
`current_cpu = "x64"`, `current_os = "linux"`, `use_lld = false`.

Each compiler wrapper supplies the private `--sysroot` and the three defines
above. Append `--target=x86_64-pc-solaris2.11` **after** the forwarded arguments:
GN's Linux target flag must not override the Solaris frontend ABI.

Use these GN arguments, with `clang_base_path` set to the host LLVM prefix:

```gn
target_os = "linux"
target_cpu = "x64"
custom_toolchain = "//build/toolchain/illumos:x64"
clang_base_path = "/path/to/llvm"
clang_use_chrome_plugins = false
is_debug = false
is_clang = true
use_custom_libcxx = true
use_sysroot = false
use_glib = false
use_lld = false
treat_warnings_as_errors = false
v8_enable_sandbox = false
v8_enable_pointer_compression = false
v8_enable_external_code_space = false
v8_enable_i18n_support = true
v8_enable_webassembly = true
v8_enable_turbofan = true
v8_enable_maglev = false
enable_rust = false
v8_enable_temporal_support = false
symbol_level = 0
```

`target_os = "linux"` selects GN build scaffolding. The compiler still targets
Solaris, and V8's C++ platform detection selects Solaris. Host tools must retain
their native compiler and SDK. Build with `gn gen out/illumos`, then
`ninja -C out/illumos -j 6 rusty_v8`. The output is
`out/illumos/obj/librusty_v8.a`.

Generate the bindings with the crate's `build.rs` bindgen configuration and
bindgen 0.72.1, using the **same target compiler arguments and GN header defines**
(`gn desc out/illumos //v8:v8_headers defines --format=json`). Include the generated
V8 include directory and bundled libc++/libc++abi headers. Disable bindgen's
automatic include-path detection, and put LLVM 23's resource include directory
after those C++ headers; otherwise bindgen can insert Xcode host headers.
Do not reuse a macOS or Linux binding: target integer and C++ layout details differ.

With Solaris's LP64 headers, bindgen can canonicalize `size_t` to Rust `c_ulong`.
Normalize those declarations against the exact crate's official Rust API:

```sh
python3 /path/to/codex/scripts/solaris/normalize-v8-bindings.py \
  out/illumos/src_binding.rs \
  gen/src_binding_release_x86_64-unknown-linux-gnu.rs
```

The normalizer verifies every changed declaration uses `usize` in the official
binding. It preserves all illumos-generated sizes, alignments, offsets and
constant values. The subsequent Rust build checks the generated layout assertions.

Keep the Solaris assert-data TLS variable aligned to 16 bytes, as recorded in
the platform patch. Solaris rounds static TLS blocks to at least that alignment;
an 8-byte-aligned segment can otherwise disagree with LLD's relaxed TLS offsets
and read zero instead of V8's nonzero initial assertion mask. A minimal pthread
probe reproduced the mismatch, and the host smoke test exercises initialization
on the runtime worker thread without disabling any V8 assertions.

Copy the archive and binding to `vendor/librusty_v8.a` and
`vendor/src_binding_prefixed.rs`, update both checksums in `manifest.json`, then
build the host. Validate the resulting host on illumos with
`code-mode-host-smoke.py`, using `LD_PRELOAD_64=libumem.so` and
`UMEM_OPTIONS=backend=mmap`. A successful link alone does not validate V8.
