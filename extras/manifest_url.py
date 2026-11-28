#!/usr/bin/env python3

# SPDX-License-Identifier: MIT

"""Validate extras artifact URLs against their authoritative source."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import PurePosixPath
from urllib.parse import urlsplit


SOURCE_PATTERN = re.compile(
    r"^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$"
)
RELEASE_VERSION_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$")
COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")


class ExtrasUrlError(ValueError):
    """Raised when an extras artifact URL violates its source policy."""


def invalid_url(context: str) -> ExtrasUrlError:
    return ExtrasUrlError(f"URL is invalid: {context}")


def validate_extras_url(
    source: str,
    version: str,
    url: str,
    *,
    mode: str = "auto",
    filename: str | None = None,
    commit_path: str | None = None,
) -> tuple[str, str]:
    """Validate one artifact URL and return its mode and canonical filename.

    ``auto`` derives the mode from the source-bound host. It deliberately does
    not derive a release or commit mode from the shape of the version: a
    40-character hexadecimal release tag is still a release.
    """

    if not isinstance(source, str) or not SOURCE_PATTERN.fullmatch(source):
        raise invalid_url("the configured source is invalid")
    if not isinstance(version, str) or not version:
        raise invalid_url("the pinned version is invalid")
    if not isinstance(url, str) or not url:
        raise invalid_url("the URL is empty")
    if any(ord(character) < 32 or ord(character) == 127 for character in url):
        raise invalid_url("the URL contains a control character")
    if "\\" in url:
        raise invalid_url("the URL contains a backslash")

    try:
        parsed = urlsplit(url)
        port = parsed.port
    except ValueError as error:
        raise invalid_url("the URL cannot be parsed") from error
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or port is not None
        or parsed.query
        or parsed.fragment
        or not parsed.path.startswith("/")
        or parsed.netloc != parsed.hostname
    ):
        raise invalid_url("the URL is not a canonical HTTPS URL")

    hostname = parsed.hostname.lower()
    if "%" in parsed.path:
        raise invalid_url("the URL path is not canonically encoded")
    decoded_path = parsed.path
    if "\\" in decoded_path:
        raise invalid_url("the URL path contains a backslash")
    if any(ord(character) < 32 or ord(character) == 127 for character in decoded_path):
        raise invalid_url("the URL path contains a control character")

    selected_mode = mode
    if source == "yorhel/ncdu":
        if selected_mode not in {"auto", "ncdu"}:
            raise invalid_url("the ncdu source requires the ncdu URL mode")
        selected_mode = "ncdu"
    elif selected_mode == "ncdu":
        raise invalid_url("the ncdu URL mode requires the configured ncdu source")
    if selected_mode == "auto":
        if hostname == "raw.githubusercontent.com":
            selected_mode = "commit"
        elif hostname == "github.com":
            selected_mode = "release"
        else:
            raise ExtrasUrlError(
                "URL does not match the configured source or commit path"
            )
    if selected_mode not in {"release", "commit", "ncdu"}:
        raise invalid_url("the URL validation mode is invalid")

    if selected_mode == "release":
        if not RELEASE_VERSION_PATTERN.fullmatch(version):
            raise invalid_url("the release version is invalid")
        prefix = f"/{source}/releases/download/{version}/"
        if hostname != "github.com" or not decoded_path.startswith(prefix):
            raise ExtrasUrlError(
                "URL does not match the configured release source"
            )
        asset_name = decoded_path[len(prefix) :]
        if (
            not asset_name
            or "/" in asset_name
            or asset_name in {".", ".."}
        ):
            raise ExtrasUrlError(
                "URL does not match the configured release asset"
            )
        if filename is not None and asset_name != filename:
            raise ExtrasUrlError(
                "URL does not match the configured release asset"
            )
        return selected_mode, asset_name

    if selected_mode == "commit":
        if not COMMIT_PATTERN.fullmatch(version):
            raise invalid_url("the commit version is invalid")
        prefix = f"/{source}/{version}/"
        if hostname != "raw.githubusercontent.com" or not decoded_path.startswith(prefix):
            raise ExtrasUrlError(
                "URL does not match the configured commit source"
            )
        asset_path = decoded_path[len(prefix) :]
        if not asset_path or any(
            part in {"", ".", ".."}
            for part in asset_path.split("/")
        ):
            raise ExtrasUrlError(
                "URL does not match the configured commit path"
            )
        if commit_path is not None and asset_path != commit_path:
            raise ExtrasUrlError(
                "URL does not match the configured commit path"
            )
        return selected_mode, PurePosixPath(asset_path).name

    if not RELEASE_VERSION_PATTERN.fullmatch(version):
        raise invalid_url("the ncdu version is invalid")
    if source != "yorhel/ncdu" or hostname != "dev.yorhel.nl":
        raise ExtrasUrlError(
            "URL does not match the configured ncdu source"
        )
    if (
        filename is None
        or not filename
        or "/" in filename
        or "\\" in filename
        or filename in {".", ".."}
        or any(ord(character) < 32 or ord(character) == 127 for character in filename)
    ):
        raise invalid_url("the ncdu asset filename is invalid")
    expected_path = f"/download/{filename}"
    if not filename.startswith(f"ncdu-{version}-"):
        raise invalid_url("the ncdu asset does not match the pinned version")
    if decoded_path != expected_path:
        raise ExtrasUrlError(
            "URL does not match the configured ncdu asset"
        )
    return selected_mode, filename


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--mode", default="auto")
    parser.add_argument("--filename")
    parser.add_argument("--commit-path")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    try:
        mode, filename = validate_extras_url(
            arguments.source,
            arguments.version,
            arguments.url,
            mode=arguments.mode,
            filename=arguments.filename,
            commit_path=arguments.commit_path,
        )
    except ExtrasUrlError as error:
        print(f"extras: {error}", file=sys.stderr)
        return 1
    print(f"{mode}\t{filename}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
