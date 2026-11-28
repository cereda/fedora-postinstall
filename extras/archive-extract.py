#!/usr/bin/env python3

# SPDX-License-Identifier: MIT

"""Safely extract explicitly declared regular files from release archives."""

from __future__ import annotations

import argparse
import os
import shutil
import stat
import sys
import tarfile
import zipfile
from pathlib import Path
from typing import BinaryIO

from tar_guard import (
    MAX_MEMBER_COUNT,
    MAX_MEMBER_SIZE,
    MAX_TOTAL_SIZE,
    TarGuardError,
    bounded_tar_gz,
)


class ArchiveError(Exception):
    """Raised when an archive violates the extraction policy."""


def fail(message: str) -> None:
    raise ArchiveError(message)


def validate_member_name(name: str) -> str:
    """Return a safe archive-relative path or raise an error."""
    if not name:
        fail("archive contains an empty member name")

    if name.startswith("/"):
        fail(f"archive contains an absolute path: {name!r}")

    if "\\" in name:
        fail(f"archive contains a backslash path: {name!r}")

    if any(ord(character) < 32 or ord(character) == 127 for character in name):
        fail(f"archive contains a control character in path: {name!r}")

    normalized = name.rstrip("/")
    while normalized.startswith("./"):
        normalized = normalized[2:]
    parts = normalized.split("/")
    if not normalized or any(part in ("", ".", "..") for part in parts):
        fail(f"archive contains an unsafe path: {name!r}")

    return normalized


def validate_limits(member_count: int, total_size: int) -> None:
    if member_count > MAX_MEMBER_COUNT:
        fail(f"archive contains more than {MAX_MEMBER_COUNT} members")
    if total_size > MAX_TOTAL_SIZE:
        fail("archive expands beyond the permitted size limit")


def copy_limited(source: BinaryIO, destination: Path, expected_size: int) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW

    file_descriptor = os.open(destination, flags, 0o755)
    try:
        with os.fdopen(file_descriptor, "wb") as output:
            copied = 0
            while True:
                chunk = source.read(1024 * 1024)
                if not chunk:
                    break
                copied += len(chunk)
                if copied > expected_size or copied > MAX_MEMBER_SIZE:
                    fail(f"archive member exceeds the permitted size: {destination.name!r}")
                output.write(chunk)
            if copied != expected_size:
                fail(f"archive member size does not match its metadata: {destination.name!r}")
            output.flush()
            os.fsync(output.fileno())
    except BaseException:
        try:
            destination.unlink()
        except FileNotFoundError:
            pass
        raise

    os.chmod(destination, 0o755)


def extract_tar(archive: Path, destination: Path, requested: set[str]) -> None:
    try:
        with bounded_tar_gz(archive) as tar_file:
            names: set[str] = set()
            total_size = 0
            member_count = 0
            regular_members: dict[str, tarfile.TarInfo] = {}

            for member in tar_file:
                member_count += 1
                name = validate_member_name(member.name)
                if name in names:
                    fail(f"archive contains a duplicate path: {name!r}")
                names.add(name)

                if member.isdir():
                    continue
                if not member.isreg():
                    fail(f"archive contains a link or special file: {name!r}")
                if getattr(member, "sparse", None):
                    fail(f"archive contains a sparse member: {name!r}")
                if member.size < 0 or member.size > MAX_MEMBER_SIZE:
                    fail(f"archive member is too large: {name!r}")
                total_size += member.size
                regular_members[name] = member

            validate_limits(member_count, total_size)

            missing = sorted(requested - set(regular_members))
            if missing:
                fail(f"declared archive member is missing: {missing[0]!r}")

            for name in sorted(requested):
                member = regular_members[name]
                source = tar_file.extractfile(member)
                if source is None:
                    fail(f"unable to read declared archive member: {name!r}")
                with source:
                    copy_limited(source, destination / name, member.size)
    except TarGuardError as error:
        fail(f"unable to inspect tar archive: {error}")
    except (tarfile.TarError, OSError) as error:
        fail(f"unable to inspect tar archive: {error}")


def zip_member_is_regular(member: zipfile.ZipInfo) -> bool:
    unix_mode = (member.external_attr >> 16) & 0xFFFF
    if unix_mode == 0:
        return True
    return stat.S_ISREG(unix_mode)


def extract_zip(archive: Path, destination: Path, requested: set[str]) -> None:
    try:
        with zipfile.ZipFile(archive, mode="r") as zip_file:
            infos = zip_file.infolist()
            names: set[str] = set()
            total_size = 0
            regular_members: dict[str, zipfile.ZipInfo] = {}

            for member in infos:
                name = validate_member_name(member.filename)
                if name in names:
                    fail(f"archive contains a duplicate path: {name!r}")
                names.add(name)

                if member.flag_bits & 0x1:
                    fail(f"archive contains an encrypted member: {name!r}")
                if member.is_dir():
                    continue
                if not zip_member_is_regular(member):
                    fail(f"archive contains a link or special file: {name!r}")
                if member.file_size < 0 or member.file_size > MAX_MEMBER_SIZE:
                    fail(f"archive member is too large: {name!r}")
                total_size += member.file_size
                regular_members[name] = member

            validate_limits(len(infos), total_size)

            missing = sorted(requested - set(regular_members))
            if missing:
                fail(f"declared archive member is missing: {missing[0]!r}")

            for name in sorted(requested):
                member = regular_members[name]
                with zip_file.open(member, mode="r") as source:
                    copy_limited(source, destination / name, member.file_size)
    except (zipfile.BadZipFile, OSError) as error:
        fail(f"unable to inspect ZIP archive: {error}")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--type", required=True, choices=("tar.gz", "zip"))
    parser.add_argument("--destination", required=True, type=Path)
    parser.add_argument("--members", required=True, nargs="+")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()

    if not arguments.archive.is_file() or arguments.archive.is_symlink():
        print(f"extras: archive is not a regular file: {arguments.archive}", file=sys.stderr)
        return 1

    try:
        requested = {validate_member_name(member) for member in arguments.members}
    except ArchiveError as error:
        print(f"extras: {error}", file=sys.stderr)
        return 1
    if not requested:
        print("extras: no archive members were declared", file=sys.stderr)
        return 1

    destination = arguments.destination
    if destination.is_symlink() or (destination.exists() and not destination.is_dir()):
        destination.unlink()
    elif destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(mode=0o700, parents=True, exist_ok=True)

    try:
        if arguments.type == "tar.gz":
            extract_tar(arguments.archive, destination, requested)
        else:
            extract_zip(arguments.archive, destination, requested)
    except ArchiveError as error:
        print(f"extras: {error}", file=sys.stderr)
        shutil.rmtree(destination, ignore_errors=True)
        return 1
    except OSError as error:
        print(f"extras: unable to extract archive: {error}", file=sys.stderr)
        shutil.rmtree(destination, ignore_errors=True)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
