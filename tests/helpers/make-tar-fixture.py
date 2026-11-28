#!/usr/bin/env python3

# SPDX-License-Identifier: MIT

"""Create raw TAR fixtures for bounded metadata regression tests."""

from __future__ import annotations

import gzip
import sys
from pathlib import Path


BLOCK_SIZE = 512


def octal_field(value: int, width: int = 11) -> bytes:
    return f"{value:0{width}o}".encode("ascii") + b"\0"


def tar_header(name: str, type_flag: bytes, size: int = 0) -> bytes:
    header = bytearray(BLOCK_SIZE)
    encoded_name = name.encode("utf-8")
    if len(encoded_name) > 100:
        raise ValueError("fixture name is too long")
    header[0 : len(encoded_name)] = encoded_name
    header[100:108] = octal_field(0o755, 7)
    header[108:116] = octal_field(0, 7)
    header[116:124] = octal_field(0, 7)
    header[124:136] = octal_field(size, 11)
    header[136:148] = octal_field(0, 11)
    header[148:156] = b" " * 8
    header[156:157] = type_flag
    header[257:263] = b"ustar\0"
    header[263:265] = b"00"
    header[265:269] = b"root"
    header[297:301] = b"root"
    checksum = sum(header)
    header[148:156] = f"{checksum:06o}".encode("ascii") + b"\0 "
    return bytes(header)


def pax_record(key: str, value: str) -> bytes:
    body = key.encode("utf-8") + b"=" + value.encode("utf-8") + b"\n"
    length = len(body) + 2
    while len(str(length)) + 1 + len(body) != length:
        length += 1
    return str(length).encode("ascii") + b" " + body


def padded(payload: bytes) -> bytes:
    return payload + b"\0" * ((-len(payload)) % BLOCK_SIZE)


def archive_bytes(kind: str) -> bytes:
    if kind == "pax-oversized":
        return tar_header("PaxHeaders/fd", b"x", 2 * 1024 * 1024)
    if kind == "gnu-long-oversized":
        return tar_header("././@LongLink", b"L", 2 * 1024 * 1024)
    if kind == "pax-too-many-records":
        records = b"".join(
            pax_record(f"key{index:04d}", "0")
            for index in range(1025)
        )
        return (
            tar_header("PaxHeaders/fd", b"x", len(records))
            + padded(records)
        )
    if kind == "pax-sparse":
        records = pax_record("GNU.sparse.map", "0,0,0")
        return (
            tar_header("PaxHeaders/fd", b"x", len(records))
            + padded(records)
        )
    if kind == "gnu-sparse":
        return tar_header("fd", b"S", 0)
    if kind == "valid-pax":
        records = pax_record("path", "fd")
        payload = b"fixture fd\n"
        return (
            tar_header("PaxHeaders/fd", b"x", len(records))
            + padded(records)
            + tar_header("fd", b"0", len(payload))
            + padded(payload)
            + b"\0" * (BLOCK_SIZE * 2)
        )
    raise ValueError(f"unknown fixture kind: {kind}")


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: make-tar-fixture.py OUTPUT KIND", file=sys.stderr)
        return 64
    output = Path(sys.argv[1])
    kind = sys.argv[2]
    output.write_bytes(gzip.compress(archive_bytes(kind), mtime=0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
