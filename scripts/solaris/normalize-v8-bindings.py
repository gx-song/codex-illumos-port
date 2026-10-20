#!/usr/bin/env python3
"""Restore size_t's Rust spelling in LP64 illumos bindgen output.

Usage: normalize-v8-bindings.py GENERATED_BINDING OFFICIAL_BINDING

Clang can canonicalize Solaris size_t aliases to unsigned long while parsing
V8's full C++ headers. Both have the same LP64 ABI, but rusty_v8 requires usize.
Only change declarations whose matching official Rust declaration uses usize;
retain every target-generated constant, layout and field offset.
"""

import argparse
from pathlib import Path
import re


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("generated_binding", type=Path)
    parser.add_argument("official_binding", type=Path)
    args = parser.parse_args()
    generated = args.generated_binding.read_text()
    official = args.official_binding.read_text()
    declaration = re.compile(
        r"(\bpub\s+(?:(?:const|static)\s+)?(\w+)\s*:\s*)"
        r"::std::os::raw::c_ulong\b"
    )

    def normalize(match: re.Match) -> str:
        name = match.group(2)
        expected = rf"\bpub\s+(?:(?:const|static)\s+)?{re.escape(name)}\s*:\s*usize\b"
        if re.search(expected, official) is None:
            raise ValueError(
                f"Cannot verify size_t declaration against rusty_v8: {name}"
            )
        return match.group(1) + "usize"

    normalized, count = declaration.subn(normalize, generated)
    if "::std::os::raw::c_ulong" in normalized:
        raise ValueError("Unreviewed unsigned long type remains in generated binding")
    args.generated_binding.write_text(normalized)
    print(f"Normalized {count} verified LP64 size_t declarations")


if __name__ == "__main__":
    main()
