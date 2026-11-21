#!/usr/bin/env python3
"""Turn a flat ROM image into $readmemh lines of 64-bit little-endian words.

usage: bin2hex64.py <image.bin> <out.hex> <rom size in bytes>
"""
import sys


def main() -> int:
    src, dst, size = sys.argv[1], sys.argv[2], int(sys.argv[3], 0)
    with open(src, "rb") as f:
        data = f.read()
    if len(data) > size:
        print(f"{src}: {len(data)} bytes do not fit in a {size}-byte ROM", file=sys.stderr)
        return 1
    data += bytes((-len(data)) % 8)
    with open(dst, "w") as f:
        for i in range(0, len(data), 8):
            f.write(f"{int.from_bytes(data[i:i + 8], 'little'):016x}\n")
    print(f"{dst}: {len(data)} bytes, {len(data) // 8} words")
    return 0


if __name__ == "__main__":
    sys.exit(main())
