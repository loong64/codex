#!/usr/bin/env python3
"""Adapt the pinned LP64 bindings to the source-built LoongArch V8 ABI.

The accompanying C++ assertions check the values against the actual build.
All record layouts remain unchanged. Keep the expected old values explicit so
an upstream binding change requires reviewing this adaptation.
"""

import argparse
from pathlib import Path
import re


def adapt(source: str, sandbox: bool) -> str:
    replacements = {
        "cppgc__Member_SIZE": (4, 8),
        "cppgc__WeakMember_SIZE": (4, 8),
        "v8__TYPED_ARRAY_MAX_SIZE_IN_HEAP": (0, 64),
    }
    if sandbox:
        max_bytes = (1 << 35) - 1
        replacements["v8__TypedArray__kMaxByteLength"] = ((1 << 53) - 1, max_bytes)
        for name, width in {
            "Uint8Array": 1,
            "Uint8ClampedArray": 1,
            "Int8Array": 1,
            "Uint16Array": 2,
            "Int16Array": 2,
            "Uint32Array": 4,
            "Int32Array": 4,
            "Float16Array": 2,
            "Float32Array": 4,
            "Float64Array": 8,
            "BigInt64Array": 8,
            "BigUint64Array": 8,
        }.items():
            replacements[f"v8__{name}__kMaxLength"] = (
                ((1 << 53) - 1) // width,
                max_bytes // width,
            )
    for name, (old, new) in replacements.items():
        pattern = rf"(pub const {re.escape(name)}: usize =\s*){old}(;)"
        source, count = re.subn(pattern, rf"\g<1>{new}\2", source)
        if count != 1:
            raise ValueError(f"Expected exactly one {name} = {old}; found {count}")
    old_version = 'c"15.2.124.1-rusty"'
    if source.count(old_version) != 1:
        raise ValueError("Expected the pinned rusty_v8 152.2.0 version string")
    return source.replace(old_version, 'c"15.2.124.1"')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sandbox", action="store_true")
    args = parser.parse_args()
    args.output.write_text(
        adapt(args.input.read_text(encoding="utf-8"), args.sandbox),
        encoding="utf-8",
        newline="\n",
    )


if __name__ == "__main__":
    main()
