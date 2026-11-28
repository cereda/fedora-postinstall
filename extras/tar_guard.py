#!/usr/bin/env python3

# SPDX-License-Identifier: MIT

"""Bound TAR extended metadata before Python's tarfile parser consumes it."""

from __future__ import annotations

import gzip
import os
import stat
import tarfile
from contextlib import contextmanager
from pathlib import Path
from typing import BinaryIO, Iterator


MAX_MEMBER_COUNT = 10_000
MAX_MEMBER_SIZE = 1024 * 1024 * 1024
MAX_TOTAL_SIZE = 2 * 1024 * 1024 * 1024
MAX_METADATA_SIZE = 1024 * 1024
MAX_METADATA_TOTAL = 8 * 1024 * 1024
MAX_METADATA_HEADERS = 1024
MAX_PAX_RECORDS_PER_HEADER = 1024
MAX_PAX_RECORDS_TOTAL = 4096
MAX_PAX_KEY_SIZE = 1024
MAX_PAX_VALUE_SIZE = 256 * 1024
BLOCK_SIZE = 512
READ_SIZE = 1024 * 1024


class TarGuardError(Exception):
    """Raised when a TAR archive violates the bounded metadata policy."""


def fail(message: str) -> None:
    raise TarGuardError(message)


def read_exact(stream: BinaryIO, size: int, context: str) -> bytes:
    """Read exactly ``size`` bytes without accepting a truncated payload."""

    chunks: list[bytes] = []
    remaining = size
    while remaining:
        chunk = stream.read(min(remaining, READ_SIZE))
        if not chunk:
            fail(f"TAR {context} is truncated")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def skip_payload(stream: BinaryIO, size: int, context: str) -> None:
    """Skip a payload in bounded chunks."""

    remaining = size
    while remaining:
        chunk = stream.read(min(remaining, READ_SIZE))
        if not chunk:
            fail(f"TAR {context} is truncated")
        remaining -= len(chunk)


def parse_numeric_field(field: bytes, context: str) -> int:
    """Parse a POSIX octal or GNU base-256 TAR numeric field."""

    if not field:
        fail(f"TAR {context} has an invalid numeric field")
    if field[0] & 0x80:
        # GNU base-256 stores a signed two's-complement value. Negative sizes
        # are never valid archive metadata.
        if field[0] & 0x40:
            fail(f"TAR {context} has a negative size")
        value = int.from_bytes(
            bytes([field[0] & 0x7F]) + field[1:],
            "big",
            signed=False,
        )
        if value < 0:
            fail(f"TAR {context} has a negative size")
        return value

    text = field.split(b"\0", 1)[0].strip(b" ")
    if not text:
        return 0
    if any(character < ord("0") or character > ord("7") for character in text):
        fail(f"TAR {context} has a malformed size")
    return int(text, 8)


def parse_pax_records(
    payload: bytes,
    total_record_count: int,
) -> int:
    """Validate bounded PAX records and reject sparse metadata."""

    record_count = 0
    position = 0
    while position < len(payload):
        separator = payload.find(b" ", position)
        if separator < 0:
            fail("TAR PAX metadata has a malformed record")
        length_text = payload[position:separator]
        if not length_text or not length_text.isdigit():
            fail("TAR PAX metadata has a malformed record length")
        record_length = int(length_text)
        minimum = separator - position + 2
        if record_length < minimum:
            fail("TAR PAX metadata has an invalid record length")
        end = position + record_length
        if end > len(payload) or payload[end - 1 : end] != b"\n":
            fail("TAR PAX metadata has a truncated record")
        record = payload[separator + 1 : end - 1]
        key, separator, value = record.partition(b"=")
        if not separator or not key:
            fail("TAR PAX metadata has an invalid record")
        if len(key) > MAX_PAX_KEY_SIZE:
            fail("TAR PAX metadata key exceeds the permitted size")
        if len(value) > MAX_PAX_VALUE_SIZE:
            fail("TAR PAX metadata value exceeds the permitted size")
        lowered = key.lower()
        if lowered.startswith(b"gnu.sparse.") or lowered == b"schily.realsize":
            fail("TAR sparse metadata is not permitted")
        if key == b"size":
            # A separate PAX size can disagree with the raw member size and
            # changes how readers calculate member boundaries. The bounded
            # policy accepts only unambiguous raw member sizes.
            fail("TAR PAX size metadata is not permitted")
        record_count += 1
        total_record_count += 1
        if record_count > MAX_PAX_RECORDS_PER_HEADER:
            fail("TAR PAX metadata contains too many records")
        if total_record_count > MAX_PAX_RECORDS_TOTAL:
            fail("TAR archive contains too many PAX records")
        position = end
    return total_record_count


def scan_tar_stream(stream: BinaryIO) -> None:
    """Inspect raw TAR headers before tarfile parses extended metadata."""

    member_count = 0
    total_size = 0
    metadata_total = 0
    metadata_headers = 0
    pax_record_count = 0

    with gzip.GzipFile(fileobj=stream, mode="rb") as compressed:
        while True:
            header = read_exact(compressed, BLOCK_SIZE, "header")
            if header == b"\0" * BLOCK_SIZE:
                return
            type_flag = header[156:157]
            size = parse_numeric_field(header[124:136], "member")

            if type_flag in {b"x", b"g", b"X"}:
                metadata_headers += 1
                if metadata_headers > MAX_METADATA_HEADERS:
                    fail("TAR archive contains too many extended metadata headers")
                if size > MAX_METADATA_SIZE:
                    fail("TAR extended metadata exceeds the permitted size")
                metadata_total += size
                if metadata_total > MAX_METADATA_TOTAL:
                    fail("TAR extended metadata exceeds the aggregate size limit")
                payload = read_exact(compressed, size, "extended metadata")
                padding = (-size) % BLOCK_SIZE
                if padding:
                    read_exact(compressed, padding, "extended metadata padding")
                pax_record_count = parse_pax_records(payload, pax_record_count)
                continue

            if type_flag in {b"L", b"K"}:
                metadata_headers += 1
                if metadata_headers > MAX_METADATA_HEADERS:
                    fail("TAR archive contains too many extended metadata headers")
                if size > MAX_METADATA_SIZE:
                    fail("TAR extended metadata exceeds the permitted size")
                metadata_total += size
                if metadata_total > MAX_METADATA_TOTAL:
                    fail("TAR extended metadata exceeds the aggregate size limit")
                read_exact(compressed, size, "extended metadata")
                padding = (-size) % BLOCK_SIZE
                if padding:
                    read_exact(compressed, padding, "extended metadata padding")
                continue

            if type_flag == b"S":
                fail("TAR sparse member metadata is not permitted")

            member_count += 1
            if member_count > MAX_MEMBER_COUNT:
                fail(f"TAR archive contains more than {MAX_MEMBER_COUNT} members")
            if size > MAX_MEMBER_SIZE:
                fail("TAR archive member exceeds the permitted size")
            # Count every raw payload, including special-member payloads, so a
            # compressed archive cannot expand beyond the limit merely by
            # changing the member type.
            total_size += size
            if total_size > MAX_TOTAL_SIZE:
                fail("TAR archive expands beyond the permitted size limit")
            skip_payload(compressed, size, "member payload")
            padding = (-size) % BLOCK_SIZE
            if padding:
                read_exact(compressed, padding, "member padding")


@contextmanager
def bounded_tar_gz(path: Path) -> Iterator[tarfile.TarFile]:
    """Open a gzip TAR archive after a bounded raw-header preflight.

    The preflight and ``tarfile`` parser use the same opened descriptor, so a
    path replacement cannot substitute different bytes between validation and
    extraction.
    """

    descriptor = -1
    try:
        flags = os.O_RDONLY | os.O_CLOEXEC
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(path, flags)
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            fail(f"TAR archive is not a regular file: {path}")
        with os.fdopen(descriptor, "rb") as raw:
            descriptor = -1
            scan_tar_stream(raw)
            raw.seek(0)
            with tarfile.open(fileobj=raw, mode="r:gz") as archive:
                yield archive
    except TarGuardError:
        raise
    except (EOFError, OSError, gzip.BadGzipFile, tarfile.TarError) as error:
        raise TarGuardError(f"unable to inspect TAR archive: {error}") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
