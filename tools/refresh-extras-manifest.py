#!/usr/bin/env python3

# SPDX-License-Identifier: MIT

"""Refresh pinned releases in the reviewed extras manifest.

The refresher queries official release metadata, downloads the selected
architecture assets, verifies an upstream checksum when one is published (or
calculates one otherwise), validates a candidate manifest, runs the local
mocked extras tests, and shows a unified diff. The tracked manifest is changed
only when ``--write`` is explicitly supplied. This tool never creates a Git
commit.
"""

from __future__ import annotations

import argparse
import ctypes
import difflib
import errno
import fcntl
import hashlib
import json
import os
import re
import shutil
import signal
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import uuid
import zipfile
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path, PurePosixPath
from typing import Any, Iterator
from urllib.parse import quote, unquote, urlsplit


EXTRAS_DIRECTORY = Path(__file__).resolve().parent.parent / "extras"
if str(EXTRAS_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(EXTRAS_DIRECTORY))

from manifest_url import ExtrasUrlError, validate_extras_url  # noqa: E402
from tar_guard import (  # noqa: E402
    MAX_MEMBER_COUNT as MAXIMUM_ARCHIVE_MEMBER_COUNT,
    MAX_MEMBER_SIZE as MAXIMUM_ARCHIVE_MEMBER_SIZE,
    MAX_TOTAL_SIZE as MAXIMUM_ARCHIVE_TOTAL_SIZE,
    TarGuardError,
    bounded_tar_gz,
)


SCHEMA_VERSION = 1
CONFIG_SCHEMA_VERSION = 2
ARCHITECTURES = ("x86_64", "aarch64")
ARCHIVE_TYPES = ("tar.gz", "zip", "none")
MAXIMUM_ASSET_SIZE = 256 * 1024 * 1024
MAXIMUM_METADATA_SIZE = 32 * 1024 * 1024
MAXIMUM_ZIP_METADATA_SIZE = 4 * 1024 * 1024
MAXIMUM_SOURCE_SIZE = 64 * 1024 * 1024
MAXIMUM_GITHUB_RELEASE_PAGES = 100
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
RELEASE_VERSION_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$")
TARGET_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")
TOOL_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]*$")
GITHUB_SOURCE_PATTERN = re.compile(
    r"^[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,99})/"
    r"[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,99})$"
)
SENSITIVE_ENVIRONMENT_KEYS = {
    "GITHUB_TOKEN",
    "GH_TOKEN",
}
NCDU_DOWNLOAD_URL = "https://dev.yorhel.nl/download"
NCDU_ASSET_PATTERN = re.compile(
    r"ncdu-([0-9]+(?:\.[0-9]+)+)-linux-(x86_64|aarch64)\.tar\.gz"
)
NCDU_HTML_PATTERN = re.compile(
    r'<dt><a\s+id="(?P<filename>ncdu-[^"]+\.tar\.gz)"[^>]*>.*?</dt>'
    r"\s*<dd>(?P<details>.*?)</dd>",
    re.DOTALL | re.IGNORECASE,
)
NCDU_SHA256_PATTERN = re.compile(
    r"SHA256\s*</td>\s*<td>\s*(?P<checksum>[0-9a-f]{64})\s*</td>",
    re.DOTALL | re.IGNORECASE,
)


class RefreshError(Exception):
    """An expected refresher failure."""

    def __init__(self, message: str, status: int = 1) -> None:
        super().__init__(message)
        self.status = status


@dataclass(frozen=True)
class SourceSnapshot:
    """The exact bytes and filesystem identity of a refresh input."""

    data: bytes
    identity: tuple[int, int, int, int, int]


def snapshot_matches_expected(
    actual: SourceSnapshot,
    expected: SourceSnapshot,
) -> bool:
    """Return whether source bytes and stable inode identity are unchanged."""

    return (
        actual.data == expected.data
        and actual.identity[:2] == expected.identity[:2]
    )


def fail(message: str, status: int = 1) -> int:
    print(f"refresh: {message}", file=sys.stderr)
    return status


def protect_token_process() -> None:
    """Prevent child processes from reading this process's initial environment."""

    if not any(
        os.environ.get(key, "").strip()
        for key in SENSITIVE_ENVIRONMENT_KEYS
    ):
        return
    if not sys.platform.startswith("linux"):
        raise RefreshError(
            "GitHub token isolation is unsupported on this platform",
            69,
        )
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        prctl = libc.prctl
        prctl.argtypes = [
            ctypes.c_int,
            ctypes.c_ulong,
            ctypes.c_ulong,
            ctypes.c_ulong,
            ctypes.c_ulong,
        ]
        prctl.restype = ctypes.c_int
        result = prctl(4, 0, 0, 0, 0)  # PR_SET_DUMPABLE
    except (AttributeError, OSError) as error:
        raise RefreshError(
            f"unable to protect the GitHub token: {error}",
            69,
        ) from error
    if result != 0:
        error_number = ctypes.get_errno()
        raise RefreshError(
            "unable to protect the GitHub token: "
            f"{os.strerror(error_number) if error_number else 'unknown error'}",
            69,
        )


def sanitized_environment() -> dict[str, str]:
    """Return the parent environment without bearer-token credentials."""

    return {
        key: value
        for key, value in os.environ.items()
        if key not in SENSITIVE_ENVIRONMENT_KEYS
    }


def run_command(
    command: list[str],
    *,
    capture: bool = False,
    cwd: Path | None = None,
    timeout: int | None = None,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[bytes]:
    child_environment = sanitized_environment() if env is None else env
    try:
        return subprocess.run(
            command,
            cwd=cwd,
            check=False,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
            timeout=timeout,
            env=child_environment,
        )
    except subprocess.TimeoutExpired as error:
        raise RefreshError(
            f"command timed out: {command[0]}", 69
        ) from error
    except OSError as error:
        raise RefreshError(
            f"unable to run {command[0]}: {error}", 69
        ) from error


def validate_configured_url(
    value: str,
    *,
    mode: str,
    source: str,
    version: str,
    context: str,
    filename: str | None = None,
    commit_path: str | None = None,
) -> None:
    try:
        validate_extras_url(
            source,
            version,
            value,
            mode=mode,
            filename=filename,
            commit_path=commit_path,
        )
    except ExtrasUrlError as error:
        raise RefreshError(f"{error}: {context}") from error


def handle_termination_signal(signum: int, frame: Any) -> None:
    raise RefreshError("interrupted", 143)


def curl_bytes(url: str, *, optional: bool = False) -> bytes | None:
    if not url.startswith("https://"):
        raise RefreshError(f"release URL is not HTTPS: {url}", 69)
    if shutil.which("curl") is None:
        raise RefreshError("curl is unavailable", 69)

    marker = b"\n__fedora_postinstall_http_status__:"
    command = [
        "curl",
        "--disable",
        "--location",
        "--silent",
        "--show-error",
        "--connect-timeout",
        "20",
        "--max-time",
        "180",
        "--max-filesize",
        str(MAXIMUM_METADATA_SIZE),
        "--proto",
        "=https",
        "--tlsv1.2",
        "--user-agent",
        "fedora-postinstall-extras-refresher",
    ]
    token = os.environ.get("GITHUB_TOKEN", "").strip()
    token_config: Path | None = None
    previous_sigterm_handler: Any = None
    try:
        if token:
            if not re.fullmatch(r"[A-Za-z0-9_-]+", token):
                raise RefreshError("GITHUB_TOKEN contains invalid characters", 69)
            if url.startswith("https://api.github.com/"):
                previous_sigterm_handler = signal.getsignal(signal.SIGTERM)
                signal.signal(signal.SIGTERM, handle_termination_signal)
                descriptor, token_name = tempfile.mkstemp(
                    prefix="fedora-postinstall-github-token.",
                )
                token_config = Path(token_name)
                try:
                    os.fchmod(descriptor, 0o600)
                    header = (
                        f'header = "Authorization: Bearer {token}"\n'.encode("ascii")
                    )
                    offset = 0
                    while offset < len(header):
                        written = os.write(descriptor, header[offset:])
                        if written <= 0:
                            raise RefreshError(
                                "unable to prepare the GitHub API authentication",
                                69,
                            )
                        offset += written
                finally:
                    os.close(descriptor)
                # A custom Authorization header is forwarded by curl to the
                # target of a redirect. Keep authenticated API requests on the
                # original api.github.com host instead of allowing a redirect
                # to disclose the token to another server.
                command.extend(
                    ["--config", str(token_config), "--max-redirs", "0"]
                )
        command.extend(
            [
                "--write-out",
                f"\n__fedora_postinstall_http_status__:%{{http_code}}",
                url,
            ]
        )
        result = run_command(command, capture=True)
    finally:
        if token_config is not None:
            try:
                token_config.unlink()
            except OSError:
                pass
        if previous_sigterm_handler is not None:
            signal.signal(signal.SIGTERM, previous_sigterm_handler)
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise RefreshError(
            f"unable to download {url}: {detail or result.returncode}", 69
        )

    payload = result.stdout
    if marker not in payload:
        raise RefreshError(f"invalid HTTP response metadata: {url}", 69)
    body, status_bytes = payload.rsplit(marker, 1)
    if len(body) > MAXIMUM_METADATA_SIZE:
        raise RefreshError(
            f"downloaded release metadata exceeds the size limit: {url}",
            69,
        )
    status_text = status_bytes.decode("ascii", "replace").strip()
    if not status_text.isdigit():
        raise RefreshError(f"invalid HTTP response status: {url}", 69)
    status = int(status_text)
    if status == 404 and optional:
        return None
    if not 200 <= status < 300:
        raise RefreshError(f"HTTP request failed with status {status}: {url}", 69)
    if not body:
        raise RefreshError(f"downloaded release metadata is empty: {url}", 69)
    return body


def curl_file(
    url: str,
    destination: Path,
    *,
    expected_size: int | None = None,
) -> None:
    if not url.startswith("https://"):
        raise RefreshError(f"release URL is not HTTPS: {url}", 69)
    if shutil.which("curl") is None:
        raise RefreshError("curl is unavailable", 69)
    result = run_command(
        [
            "curl",
            "--disable",
            "--fail",
            "--location",
            "--silent",
            "--show-error",
            "--connect-timeout",
            "20",
            "--max-time",
            "300",
            "--max-filesize",
            str(MAXIMUM_ASSET_SIZE),
            "--proto",
            "=https",
            "--tlsv1.2",
            "--user-agent",
            "fedora-postinstall-extras-refresher",
            "--output",
            str(destination),
            url,
        ],
        capture=True,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise RefreshError(
            f"unable to download {url}: {detail or result.returncode}", 69
        )
    try:
        size = destination.stat().st_size
    except OSError as error:
        raise RefreshError(f"unable to inspect {url}: {error}", 69) from error
    if size <= 0:
        raise RefreshError(f"downloaded release asset is empty: {url}", 69)
    if size > MAXIMUM_ASSET_SIZE:
        raise RefreshError(f"release asset is too large: {url}", 69)
    if expected_size is not None and size != expected_size:
        raise RefreshError(
            f"downloaded release asset size does not match release metadata: {url}",
            69,
        )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        raise RefreshError(f"unable to hash {path}: {error}") from error
    return digest.hexdigest()


def reject_duplicate_json_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise RefreshError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def parse_json_bytes(data: bytes, context: str) -> Any:
    try:
        return json.loads(
            data.decode("utf-8"),
            object_pairs_hook=reject_duplicate_json_keys,
        )
    except RefreshError:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RefreshError(f"unable to read {context}: {error}", 69) from error


def load_json(path: Path) -> Any:
    try:
        return parse_json_bytes(path.read_bytes(), str(path))
    except RefreshError:
        raise
    except OSError as error:
        raise RefreshError(f"unable to read {path}: {error}", 69) from error


def source_identity(metadata: os.stat_result) -> tuple[int, int, int, int, int]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def read_source_snapshot(path: Path, context: str) -> SourceSnapshot:
    descriptor = -1
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
        )
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise RefreshError(f"{context} is not a regular file: {path}", 69)
        if metadata.st_nlink != 1:
            raise RefreshError(f"{context} must not have multiple hard links: {path}", 69)
        if metadata.st_size > MAXIMUM_SOURCE_SIZE:
            raise RefreshError(f"{context} exceeds the supported size: {path}", 69)
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > MAXIMUM_SOURCE_SIZE:
                raise RefreshError(f"{context} exceeds the supported size: {path}", 69)
            chunks.append(chunk)
        return SourceSnapshot(
            data=b"".join(chunks),
            identity=source_identity(metadata),
        )
    except RefreshError:
        raise
    except OSError as error:
        if error.errno in {errno.ELOOP, errno.ENOTDIR}:
            raise RefreshError(
                f"{context} must not be a symbolic link or special file: {path}",
                69,
            ) from error
        raise RefreshError(f"unable to read {context}: {error}", 69) from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def read_source_bytes(path: Path, context: str) -> bytes:
    return read_source_snapshot(path, context).data


def repository_registry(
    repository: Path,
    expected_bytes: bytes | None = None,
) -> list[str]:
    registry_file = repository / "extras" / "tools-list.sh"
    snapshot = read_source_snapshot(registry_file, "tool registry")
    if expected_bytes is not None and snapshot.data != expected_bytes:
        raise RefreshError(
            "the tool registry changed while it was being read",
            69,
        )

    with tempfile.TemporaryDirectory(prefix="extras-registry.") as directory:
        private_registry = Path(directory) / "tools-list.sh"
        descriptor = os.open(
            private_registry,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC,
            0o600,
        )
        try:
            offset = 0
            while offset < len(snapshot.data):
                written = os.write(descriptor, snapshot.data[offset:])
                if written <= 0:
                    raise RefreshError("unable to copy the authoritative tool registry", 69)
                offset += written
        finally:
            os.close(descriptor)

        result = run_command(
            [
                "bash",
                "-c",
                'source "$1"; printf "%s\\n" "${CLI_TOOLS_LIST[@]}"',
                "refresh-extras",
                str(private_registry),
            ],
            capture=True,
        )
    if result.returncode != 0:
        raise RefreshError("unable to read the authoritative tool registry", 69)
    tools = [
        line.strip()
        for line in result.stdout.decode("utf-8", "replace").splitlines()
        if line.strip()
    ]
    if not tools or len(tools) != len(set(tools)):
        raise RefreshError("the authoritative tool registry is empty or duplicated", 69)
    if any(not TOOL_PATTERN.fullmatch(tool) for tool in tools):
        raise RefreshError("the authoritative tool registry contains an invalid name", 69)
    return tools


def configured_file_selector_pattern(source: str) -> re.Pattern[str]:
    """Compile a bounded archive-member selector.

    A selector is a literal basename or a basename containing ``*`` wildcards.
    The wildcard is converted to a regular expression only after every other
    character has been escaped, so configured values cannot inject regex
    syntax.
    """

    return re.compile(re.escape(source).replace(r"\*", ".*"))


def configured_file_map(value: Any, context: str) -> dict[str, str]:
    if not isinstance(value, dict) or not value:
        raise RefreshError(f"invalid configured file mapping: {context}")
    files: dict[str, str] = {}
    targets: list[str] = []
    for source, target in value.items():
        if (
            not isinstance(source, str)
            or not source
            or source in {".", ".."}
            or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+*-]*", source)
            or not isinstance(target, str)
            or not TARGET_PATTERN.fullmatch(target)
        ):
            raise RefreshError(f"invalid configured file mapping: {context}")
        files[source] = target
        targets.append(target)
    if len(targets) != len(set(targets)):
        raise RefreshError(f"duplicate configured command target: {context}")
    return files


def load_configuration(
    repository: Path,
    data: bytes | None = None,
) -> dict[str, Any]:
    path = repository / "tools" / "extras-refresh-config.json"
    if data is None:
        if not path.is_file() or path.is_symlink():
            raise RefreshError(f"extras refresh configuration is unavailable: {path}", 69)
        data = read_source_bytes(path, "extras refresh configuration")
    configuration = parse_json_bytes(data, "extras refresh configuration")
    if not isinstance(configuration, dict):
        raise RefreshError("the extras refresh configuration is invalid", 69)
    if configuration.get("schema_version") != CONFIG_SCHEMA_VERSION:
        raise RefreshError("the extras refresh configuration schema is unsupported", 69)

    excluded = configuration.get("excluded_rolling_tools")
    if not isinstance(excluded, list) or not excluded or len(excluded) != len(set(excluded)):
        raise RefreshError("the rolling-tool exclusions are invalid", 69)
    if any(not isinstance(tool, str) or not TOOL_PATTERN.fullmatch(tool) for tool in excluded):
        raise RefreshError("the rolling-tool exclusions are invalid", 69)

    patterns = configuration.get("unstable_tag_patterns")
    if not isinstance(patterns, list) or any(
        not isinstance(pattern, str) for pattern in patterns
    ):
        raise RefreshError("the unstable-tag policy is invalid", 69)
    for pattern in patterns:
        try:
            re.compile(pattern)
        except re.error as error:
            raise RefreshError(f"the unstable-tag policy is invalid: {error}") from error

    tools = configuration.get("tools")
    if not isinstance(tools, dict) or not tools:
        raise RefreshError("the extras refresh configuration has no tools", 69)
    for name, tool in tools.items():
        if not isinstance(name, str) or not TOOL_PATTERN.fullmatch(name):
            raise RefreshError(f"invalid configured tool identifier: {name}")
        if not isinstance(tool, dict):
            raise RefreshError(f"invalid refresh configuration: {name}")
        mode = tool.get("mode")
        source = tool.get("source")
        if (
            not isinstance(source, str)
            or not GITHUB_SOURCE_PATTERN.fullmatch(source)
        ):
            raise RefreshError(f"invalid refresh source: {name}")
        assets = tool.get("assets")
        if not isinstance(assets, dict) or not assets:
            raise RefreshError(f"invalid configured assets: {name}")

        if mode == "release":
            if set(assets) != set(ARCHITECTURES):
                raise RefreshError(f"invalid release architectures: {name}")
        elif mode == "commit":
            if set(assets) != {"any"}:
                raise RefreshError(f"invalid commit assets: {name}")
            ref = tool.get("ref")
            commit_path = tool.get("path")
            if not isinstance(ref, str) or not ref:
                raise RefreshError(f"invalid commit ref: {name}")
            if (
                not isinstance(commit_path, str)
                or not commit_path
                or commit_path.startswith("/")
                or "\\" in commit_path
                or any(part in ("", ".", "..") for part in commit_path.split("/"))
            ):
                raise RefreshError(f"invalid commit path: {name}")
        elif mode == "ncdu":
            if source != "yorhel/ncdu" or set(assets) != set(ARCHITECTURES):
                raise RefreshError(f"invalid ncdu source or assets: {name}")
        else:
            raise RefreshError(f"invalid refresh mode for {name}: {mode}")

        for architecture, specification in assets.items():
            context = f"{name}/{architecture}"
            if specification is None:
                if mode != "release":
                    raise RefreshError(f"invalid configured asset: {context}")
                continue
            if not isinstance(specification, dict):
                raise RefreshError(f"invalid configured asset: {context}")
            archive_type = specification.get("type")
            if archive_type not in ARCHIVE_TYPES:
                raise RefreshError(f"invalid configured archive type: {context}")
            files = configured_file_map(specification.get("files"), context)
            if archive_type == "none" and len(files) != 1:
                raise RefreshError(
                    f"a standalone configured asset must declare one file: {context}"
                )
            pattern = specification.get("pattern")
            if mode in {"release", "ncdu"}:
                if not isinstance(pattern, str) or not pattern:
                    raise RefreshError(f"invalid configured asset pattern: {context}")
                try:
                    re.compile(pattern)
                except re.error as error:
                    raise RefreshError(
                        f"invalid configured asset pattern: {context}: {error}"
                    ) from error
            elif pattern is not None:
                raise RefreshError(f"invalid configured asset pattern: {context}")

    configuration["excluded_rolling_tools"] = list(excluded)
    return configuration


def load_manifest(path: Path, data: bytes | None = None) -> dict[str, Any]:
    if data is None:
        data = read_source_bytes(path, "extras manifest")
    manifest = parse_json_bytes(data, "extras manifest")
    if not isinstance(manifest, dict) or manifest.get("schema_version") != SCHEMA_VERSION:
        raise RefreshError("the extras manifest has an unsupported schema", 69)
    if not isinstance(manifest.get("tools"), dict):
        raise RefreshError("the extras manifest has no tools object", 69)
    return manifest


def manifest_text(manifest: dict[str, Any]) -> str:
    return json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"


def show_diff(old_text: str, new_text: str) -> None:
    difference = difflib.unified_diff(
        old_text.splitlines(keepends=True),
        new_text.splitlines(keepends=True),
        fromfile="extras/tools-manifest.json (current)",
        tofile="extras/tools-manifest.json (refreshed)",
    )
    sys.stdout.writelines(difference)


def configured_architectures(tool: dict[str, Any]) -> set[str]:
    if tool.get("mode") == "commit":
        return {"any"}
    if tool.get("mode") == "ncdu":
        return set(ARCHITECTURES)
    assets = tool.get("assets", {})
    return {
        architecture
        for architecture, specification in assets.items()
        if specification is not None
    }


def safe_archive_member(value: str) -> bool:
    if (
        not value
        or "\x00" in value
        or "\\" in value
        or any(ord(character) < 32 or ord(character) == 127 for character in value)
    ):
        return False
    pure = PurePosixPath(value)
    if pure.is_absolute():
        return False
    normalized = value
    while normalized.startswith("./"):
        normalized = normalized[2:]
    return all(part not in ("", ".", "..") for part in normalized.split("/"))


def validate_manifest(
    manifest: dict[str, Any],
    registry: list[str],
    configuration: dict[str, Any],
    *,
    allowed_drift: set[str] | frozenset[str] = frozenset(),
) -> None:
    tools = manifest.get("tools")
    configured_tools = configuration.get("tools", {})
    if not isinstance(tools, dict):
        raise RefreshError("the extras manifest has no tools object")
    if set(tools) != set(registry):
        missing = sorted(set(registry) - set(tools))
        extra = sorted(set(tools) - set(registry))
        raise RefreshError(
            f"manifest and registry differ (missing: {missing}; extra: {extra})"
        )
    if set(configured_tools) != set(registry):
        missing = sorted(set(registry) - set(configured_tools))
        extra = sorted(set(configured_tools) - set(registry))
        raise RefreshError(
            "refresh configuration and registry differ "
            f"(missing: {missing}; extra: {extra})"
        )

    for name, tool in tools.items():
        if not isinstance(tool, dict):
            raise RefreshError(f"manifest entry is invalid: {name}")
        configured = configured_tools.get(name)
        if not isinstance(configured, dict):
            raise RefreshError(f"refresh configuration is invalid: {name}")
        allow_drift = name in allowed_drift

        version = tool.get("version")
        if not isinstance(version, str) or not RELEASE_VERSION_PATTERN.fullmatch(version):
            raise RefreshError(f"manifest version is invalid: {name}")
        if rolling_version(version):
            raise RefreshError(f"manifest version is not pinned: {name}")
        if configured.get("mode") == "commit" and not COMMIT_PATTERN.fullmatch(version):
            raise RefreshError(f"manifest commit version is invalid: {name}")
        description = tool.get("description")
        if (
            not isinstance(description, str)
            or not description
            or len(description) > 100
            or "\n" in description
            or "\r" in description
        ):
            raise RefreshError(f"manifest description is invalid: {name}")
        source = tool.get("source")
        if (
            not isinstance(source, str)
            or not GITHUB_SOURCE_PATTERN.fullmatch(source)
        ):
            raise RefreshError(f"manifest source is invalid: {name}")
        if not allow_drift and source != configured.get("source"):
            raise RefreshError(f"manifest source does not match the configuration: {name}")

        assets = tool.get("assets")
        if not isinstance(assets, dict) or not assets:
            raise RefreshError(f"manifest assets are invalid: {name}")
        expected_architectures = configured_architectures(configured)
        if set(assets) != expected_architectures and not allow_drift:
            raise RefreshError(
                f"manifest architectures do not match the configuration: {name}"
            )

        architecture_urls: dict[str, str] = {}
        architecture_filenames: dict[str, str] = {}
        for architecture, asset in assets.items():
            context = f"{name}/{architecture}"
            if not isinstance(asset, dict):
                raise RefreshError(f"manifest asset is invalid: {context}")
            url = asset.get("url")
            checksum = asset.get("sha256")
            archive_type = asset.get("type")
            files = asset.get("files")
            if not isinstance(url, str):
                raise RefreshError(f"manifest URL is invalid: {context}")
            filename = unquote(PurePosixPath(urlsplit(url).path).name)
            validate_configured_url(
                url,
                mode=str(configured.get("mode", "")),
                source=(
                    source
                    if allow_drift and source != configured.get("source")
                    else str(configured.get("source", ""))
                ),
                version=version,
                context=context,
                filename=filename,
                commit_path=(
                    str(configured.get("path"))
                    if configured.get("mode") == "commit"
                    else None
                ),
            )
            if "/releases/latest/" in url or url.rstrip("/").endswith("/latest"):
                raise RefreshError(f"manifest URL is rolling: {context}")
            if version not in url:
                raise RefreshError(
                    f"manifest URL does not contain its pinned version: {context}"
                )
            if not isinstance(checksum, str) or not SHA256_PATTERN.fullmatch(checksum):
                raise RefreshError(f"manifest checksum is invalid: {context}")
            if archive_type not in ARCHIVE_TYPES:
                raise RefreshError(f"manifest archive type is invalid: {context}")
            if not isinstance(files, dict) or not files:
                raise RefreshError(f"manifest file map is invalid: {context}")

            targets: list[str] = []
            for source_path, target in files.items():
                if (
                    not isinstance(source_path, str)
                    or not isinstance(target, str)
                    or not safe_archive_member(source_path)
                    or not TARGET_PATTERN.fullmatch(target)
                ):
                    raise RefreshError(f"manifest file map is unsafe: {context}")
                targets.append(target)
            if len(targets) != len(set(targets)):
                raise RefreshError(f"manifest file map has duplicate targets: {context}")

            if not filename or filename in {".", ".."}:
                raise RefreshError(f"manifest artifact filename is invalid: {context}")
            if architecture in ARCHITECTURES and not allow_drift:
                existing_architecture = architecture_urls.get(url)
                if existing_architecture is None:
                    existing_architecture = architecture_filenames.get(filename)
                if existing_architecture is not None:
                    raise RefreshError(
                        "manifest architecture assets are not distinct: "
                        f"{name}/{existing_architecture} and {name}/{architecture}"
                    )
                architecture_urls[url] = architecture
                architecture_filenames[filename] = architecture

            specification = configured.get("assets", {}).get(architecture)
            if not isinstance(specification, dict):
                if allow_drift and architecture not in expected_architectures:
                    continue
                raise RefreshError(f"configured asset is invalid: {context}")
            configured_type = specification.get("type")
            configured_files = configured_file_map(
                specification.get("files"),
                context,
            )
            if not allow_drift and archive_type != configured_type:
                raise RefreshError(
                    f"manifest archive type does not match the configuration: {context}"
                )

            manifest_selectors: dict[str, str] = {}
            for source_path, target in files.items():
                if archive_type == "none":
                    selector = source_path
                else:
                    selector = PurePosixPath(
                        normalized_archive_member(source_path)
                    ).name
                if selector in manifest_selectors:
                    raise RefreshError(
                        f"manifest file map has duplicate archive basenames: {context}"
                    )
                manifest_selectors[selector] = target
            if not allow_drift:
                matched_selectors: set[str] = set()
                for configured_source, configured_target in configured_files.items():
                    selector_pattern = configured_file_selector_pattern(
                        configured_source
                    )
                    matches = [
                        selector
                        for selector, target in manifest_selectors.items()
                        if target == configured_target
                        and selector_pattern.fullmatch(selector)
                    ]
                    if len(matches) != 1:
                        raise RefreshError(
                            "manifest file map does not match the configuration: "
                            f"{context}"
                        )
                    matched_selectors.add(matches[0])
                if matched_selectors != set(manifest_selectors):
                    raise RefreshError(
                        f"manifest file map does not match the configuration: {context}"
                    )

            if archive_type == "none":
                if len(files) != 1:
                    raise RefreshError(
                        f"standalone manifest entry must declare one file: {context}"
                    )
                if filename != next(iter(files)):
                    raise RefreshError(
                        f"standalone manifest filename does not match its file: {context}"
                    )
                if not TARGET_PATTERN.fullmatch(filename):
                    raise RefreshError(
                        f"standalone manifest filename is invalid: {context}"
                    )

            pattern = specification.get("pattern")
            if pattern is not None and not allow_drift:
                if not isinstance(pattern, str) or not re.fullmatch(pattern, filename):
                    raise RefreshError(
                        f"manifest asset does not match the configured pattern: {context}"
                    )


def asset_digest(asset: dict[str, Any]) -> str | None:
    digest = asset.get("digest")
    if digest is None:
        return None
    if not isinstance(digest, str):
        raise RefreshError("release asset declares an invalid checksum digest")
    if ":" in digest:
        algorithm, value = digest.split(":", 1)
        if algorithm.lower() != "sha256":
            raise RefreshError(
                f"release asset declares an unsupported checksum algorithm: {algorithm}"
            )
        digest = value
    digest = digest.strip().lower()
    if not SHA256_PATTERN.fullmatch(digest):
        raise RefreshError("release asset declares an invalid checksum digest")
    return digest


def normalized_checksum_filename(value: str) -> str:
    """Return the exact filename as written by a checksum manifest."""

    return value.strip()


def release_assets_collide(first: dict[str, Any], second: dict[str, Any]) -> bool:
    """Return whether two architecture selections identify the same asset."""

    for key in ("name", "browser_download_url"):
        first_value = first.get(key)
        second_value = second.get(key)
        if (
            isinstance(first_value, str)
            and isinstance(second_value, str)
            and first_value
            and first_value == second_value
        ):
            return True
    first_id = first.get("id")
    second_id = second.get("id")
    return (
        first_id is not None
        and second_id is not None
        and first_id == second_id
    )


def checksum_entries(value: str) -> list[tuple[str | None, str]]:
    """Parse checksum manifests into explicit filename/digest pairs.

    The supported forms are the common ``digest  filename`` notation and
    the GNU/BSD ``SHA256 (filename) = digest`` notation. A digest without a
    filename is retained as an unassociated entry and is never attributed to
    an asset implicitly.
    """

    entries: list[tuple[str | None, str]] = []
    for line in value.splitlines():
        stripped = line.strip()
        if not stripped:
            continue

        labeled = re.fullmatch(
            r"(?:SHA256|SHA-256)\s*\((.+)\)\s*=\s*([0-9a-fA-F]{64})",
            stripped,
            re.IGNORECASE,
        )
        if labeled is not None:
            entries.append(
                (
                    normalized_checksum_filename(labeled.group(1)),
                    labeled.group(2).lower(),
                )
            )
            continue

        standard = re.fullmatch(
            r"([0-9a-fA-F]{64})\s+(\*?)(.+)",
            stripped,
        )
        if standard is not None:
            entries.append(
                (
                    normalized_checksum_filename(standard.group(3)),
                    standard.group(1).lower(),
                )
            )
            continue

        plain = re.fullmatch(r"([0-9a-fA-F]{64})", stripped)
        if plain is not None:
            entries.append((None, plain.group(1).lower()))
    return entries


def checksum_digests_for_filename(
    entries: list[tuple[str | None, str]],
    filename: str,
) -> set[str]:
    """Return every digest explicitly associated with one exact filename."""

    return {
        digest
        for referenced_filename, digest in entries
        if referenced_filename == filename
    }


def upstream_checksum(
    release_assets: list[dict[str, Any]],
    candidate: dict[str, Any],
    filename: str,
    sidecar_cache: dict[str, bytes | None],
    *,
    source: str,
    version: str,
) -> tuple[str | None, str]:
    checksum_assets: list[tuple[str, str]] = []
    digest = asset_digest(candidate)
    if digest:
        checksum_assets.append((digest, "release API digest"))

    candidate_url = str(candidate.get("browser_download_url", ""))
    candidate_sidecars = {
        f"{filename}.sha256".lower(),
        f"{filename}.sha256sum".lower(),
        f"{filename}.checksum".lower(),
    }
    generic_sidecars = {
        "sha256.sum",
        "sha256sums.txt",
        "checksum.txt",
        "checksums.txt",
        "checksum.sha256",
        "checksums.sha256",
    }
    for asset in release_assets:
        if not isinstance(asset, dict):
            continue
        name = str(asset.get("name", ""))
        lower_name = name.lower()
        if (
            lower_name not in candidate_sidecars
            and lower_name not in generic_sidecars
        ):
            continue
        url = asset.get("browser_download_url")
        if not isinstance(url, str) or not url.startswith("https://"):
            continue
        validate_configured_url(
            url,
            mode="release",
            source=source,
            version=version,
            context=f"upstream checksum asset {name}",
        )
        if url not in sidecar_cache:
            sidecar_cache[url] = curl_bytes(url)
        text = (sidecar_cache[url] or b"").decode("utf-8", "replace")
        digests = checksum_digests_for_filename(checksum_entries(text), filename)
        if len(digests) > 1:
            raise RefreshError(
                f"upstream checksum asset contains conflicting digests: {name}"
            )
        if not digests:
            if lower_name in generic_sidecars:
                raise RefreshError(
                    f"upstream checksum asset does not contain {filename}: {name}"
                )
            # A candidate-specific sidecar that names another file is not
            # evidence for this asset. It must never supply an unqualified
            # digest; the downloaded bytes are checksummed locally instead.
            continue
        checksum_assets.append(
            (next(iter(digests)), f"upstream checksum asset {name}")
        )

    if candidate_url:
        for suffix in (".sha256", ".sha256sum"):
            url = candidate_url + suffix
            validate_configured_url(
                url,
                mode="release",
                source=source,
                version=version,
                context=f"upstream checksum sidecar {suffix}",
            )
            if url not in sidecar_cache:
                sidecar_cache[url] = curl_bytes(url, optional=True)
            text = sidecar_cache[url]
            if text is None:
                continue
            decoded = text.decode("utf-8", "replace")
            digests = checksum_digests_for_filename(
                checksum_entries(decoded),
                filename,
            )
            if len(digests) > 1:
                raise RefreshError(
                    f"upstream checksum sidecar contains conflicting digests: {suffix}"
                )
            if digests:
                checksum_assets.append(
                    (next(iter(digests)), f"upstream sidecar {suffix}")
                )

    if checksum_assets:
        checksums = {checksum for checksum, _ in checksum_assets}
        if len(checksums) > 1:
            raise RefreshError(
                "upstream checksum metadata contains conflicting digests"
            )
        checksum = next(iter(checksums))
        description = next(
            description for value, description in checksum_assets if value == checksum
        )
        return checksum, description
    return None, "calculated locally"


def normalized_archive_member(value: str) -> str:
    if not value:
        raise RefreshError("release archive contains an empty member name")
    if value.startswith("/"):
        raise RefreshError(f"release archive contains an absolute path: {value}")
    if "\\" in value:
        raise RefreshError(f"release archive contains a backslash path: {value}")
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise RefreshError(
            f"release archive contains a control character in a path: {value}"
        )
    normalized = value.rstrip("/")
    while normalized.startswith("./"):
        normalized = normalized[2:]
    parts = normalized.split("/")
    if not normalized or any(part in ("", ".", "..") for part in parts):
        raise RefreshError(f"release archive contains an unsafe path: {value}")
    return normalized


def validate_archive_limits(member_count: int, total_size: int) -> None:
    if member_count > MAXIMUM_ARCHIVE_MEMBER_COUNT:
        raise RefreshError(
            f"release archive contains more than {MAXIMUM_ARCHIVE_MEMBER_COUNT} members"
        )
    if total_size > MAXIMUM_ARCHIVE_TOTAL_SIZE:
        raise RefreshError("release archive expands beyond the permitted size limit")


def zip_member_is_regular(member: zipfile.ZipInfo) -> bool:
    unix_mode = (member.external_attr >> 16) & 0xFFFF
    if unix_mode == 0:
        return True
    return stat.S_ISREG(unix_mode)


def zip_central_directory_count(path: Path) -> int:
    try:
        file_size = path.stat().st_size
        with path.open("rb") as stream:
            tail_size = min(file_size, 65_557)
            stream.seek(file_size - tail_size)
            tail = stream.read(tail_size)
            eocd_offset = -1
            search_offset = len(tail) - 22
            while search_offset >= 0:
                if tail[search_offset : search_offset + 4] == b"PK\x05\x06":
                    fields = struct.unpack_from("<4s4H2LH", tail, search_offset)
                    comment_length = fields[7]
                    if search_offset + 22 + comment_length == len(tail):
                        eocd_offset = search_offset
                        break
                search_offset -= 1
            if eocd_offset < 0:
                raise RefreshError(f"release archive is not a zip file: {path}")

            fields = struct.unpack_from("<4s4H2LH", tail, eocd_offset)
            entry_count = fields[4]
            central_size = fields[5]
            central_offset = fields[6]
            absolute_eocd = file_size - tail_size + eocd_offset

            if (
                entry_count == 0xFFFF
                or central_size == 0xFFFFFFFF
                or central_offset == 0xFFFFFFFF
            ):
                locator_offset = absolute_eocd - 20
                if locator_offset < 0:
                    raise RefreshError(
                        f"release archive has an invalid ZIP64 directory: {path}"
                    )
                stream.seek(locator_offset)
                locator = stream.read(20)
                if len(locator) != 20 or locator[:4] != b"PK\x06\x07":
                    raise RefreshError(
                        f"release archive has an invalid ZIP64 locator: {path}"
                    )
                zip64_offset = struct.unpack_from("<Q", locator, 8)[0]
                stream.seek(zip64_offset)
                zip64_record = stream.read(56)
                if len(zip64_record) != 56 or zip64_record[:4] != b"PK\x06\x06":
                    raise RefreshError(
                        f"release archive has an invalid ZIP64 directory: {path}"
                    )
                zip64_fields = struct.unpack_from("<4sQHHIIQQQQ", zip64_record)
                entry_count = zip64_fields[7]
                central_size = zip64_fields[8]
                central_offset = zip64_fields[9]

            if entry_count > MAXIMUM_ARCHIVE_MEMBER_COUNT:
                raise RefreshError(
                    f"release archive contains more than "
                    f"{MAXIMUM_ARCHIVE_MEMBER_COUNT} members"
                )

            if central_size > MAXIMUM_ZIP_METADATA_SIZE:
                raise RefreshError(
                    "release archive ZIP metadata exceeds the permitted size limit"
                )

            prefix_size = absolute_eocd - central_size - central_offset
            actual_offset = central_offset + max(prefix_size, 0)
            actual_end = actual_offset + central_size
            if actual_offset < 0 or actual_end > file_size:
                raise RefreshError(
                    f"release archive has an invalid ZIP directory: {path}"
                )

            count = 0
            stream.seek(actual_offset)
            while stream.tell() < actual_end:
                header = stream.read(46)
                if len(header) != 46 or header[:4] != b"PK\x01\x02":
                    raise RefreshError(
                        f"release archive has an invalid ZIP directory: {path}"
                    )
                name_length, extra_length, comment_length = struct.unpack_from(
                    "<HHH",
                    header,
                    28,
                )
                next_position = (
                    stream.tell()
                    + name_length
                    + extra_length
                    + comment_length
                )
                if next_position > actual_end:
                    raise RefreshError(
                        f"release archive has an invalid ZIP directory: {path}"
                    )
                stream.seek(next_position)
                count += 1
                if count > MAXIMUM_ARCHIVE_MEMBER_COUNT:
                    raise RefreshError(
                        f"release archive contains more than "
                        f"{MAXIMUM_ARCHIVE_MEMBER_COUNT} members"
                    )
            return count
    except RefreshError:
        raise
    except (OSError, struct.error) as error:
        raise RefreshError(
            f"unable to inspect release archive {path}: {error}"
        ) from error


def archive_regular_members(path: Path, archive_type: str) -> list[str]:
    members: list[str] = []
    names: set[str] = set()
    total_size = 0
    member_count = 0
    try:
        if archive_type == "tar.gz":
            with bounded_tar_gz(path) as archive:
                for member in archive:
                    member_count += 1
                    if member_count > MAXIMUM_ARCHIVE_MEMBER_COUNT:
                        raise RefreshError(
                            f"release archive contains more than "
                            f"{MAXIMUM_ARCHIVE_MEMBER_COUNT} members"
                        )
                    name = normalized_archive_member(member.name)
                    if name in names:
                        raise RefreshError(
                            f"release archive contains a duplicate path: {name}"
                        )
                    names.add(name)
                    if member.isdir():
                        continue
                    if not member.isreg():
                        raise RefreshError(
                            f"release archive contains a link or special file: {name}"
                        )
                    if getattr(member, "sparse", None):
                        raise RefreshError(
                            f"release archive contains a sparse member: {name}"
                        )
                    if member.size < 0 or member.size > MAXIMUM_ARCHIVE_MEMBER_SIZE:
                        raise RefreshError(
                            f"release archive member is too large: {name}"
                        )
                    total_size += member.size
                    if total_size > MAXIMUM_ARCHIVE_TOTAL_SIZE:
                        raise RefreshError(
                            "release archive expands beyond the permitted size limit"
                        )
                    members.append(name)
        elif archive_type == "zip":
            member_count = zip_central_directory_count(path)
            with zipfile.ZipFile(path) as archive:
                archive_members = archive.infolist()
                if len(archive_members) != member_count:
                    raise RefreshError(
                        f"release archive has an inconsistent ZIP directory: {path}"
                    )
                for member in archive_members:
                    name = normalized_archive_member(member.filename)
                    if name in names:
                        raise RefreshError(
                            f"release archive contains a duplicate path: {name}"
                        )
                    names.add(name)
                    if member.flag_bits & 0x1:
                        raise RefreshError(
                            f"release archive contains an encrypted member: {name}"
                        )
                    if member.is_dir():
                        continue
                    if not zip_member_is_regular(member):
                        raise RefreshError(
                            f"release archive contains a link or special file: {name}"
                        )
                    if member.file_size < 0 or member.file_size > MAXIMUM_ARCHIVE_MEMBER_SIZE:
                        raise RefreshError(
                            f"release archive member is too large: {name}"
                        )
                    total_size += member.file_size
                    if total_size > MAXIMUM_ARCHIVE_TOTAL_SIZE:
                        raise RefreshError(
                            "release archive expands beyond the permitted size limit"
                        )
                    members.append(name)
        else:
            raise RefreshError(f"unsupported release archive type: {archive_type}")
    except RefreshError:
        raise
    except TarGuardError as error:
        raise RefreshError(f"unable to inspect release archive {path}: {error}") from error
    except (OSError, tarfile.TarError, zipfile.BadZipFile) as error:
        raise RefreshError(f"unable to inspect release archive {path}: {error}") from error
    validate_archive_limits(member_count, total_size)
    return members


def refreshed_file_map(
    archive_path: Path,
    archive_type: str,
    configured_files: dict[str, str],
    url: str,
) -> dict[str, str]:
    if archive_type == "none":
        filename = unquote(PurePosixPath(urlsplit(url).path).name)
        if len(configured_files) != 1:
            raise RefreshError(
                "a standalone release asset must declare exactly one file"
            )
        source = next(iter(configured_files))
        if filename != source:
            raise RefreshError(
                f"release asset filename does not match the configured file: {filename}"
            )
        return dict(configured_files)

    members = archive_regular_members(archive_path, archive_type)
    refreshed: dict[str, str] = {}
    for source, target in configured_files.items():
        selector = configured_file_selector_pattern(source)
        candidates = [
            member
            for member in members
            if selector.fullmatch(PurePosixPath(member).name)
        ]
        if not candidates:
            raise RefreshError(
                f"release archive does not contain the configured executable: {source}"
            )
        if len(candidates) != 1:
            raise RefreshError(
                f"release archive contains multiple candidates for {source}"
            )
        refreshed[candidates[0]] = target
    return refreshed


def validate_extracted_archive(
    archive_path: Path,
    archive_type: str,
    files: dict[str, str],
    destination: Path,
) -> None:
    extras_directory = Path(__file__).resolve().parent.parent / "extras"
    extractor_snapshot = read_source_snapshot(
        extras_directory / "archive-extract.py",
        "archive validation extractor",
    )
    guard_snapshot = read_source_snapshot(
        extras_directory / "tar_guard.py",
        "archive validation TAR guard",
    )
    members = sorted(files)
    private_directory: Path | None = None

    def write_private_file(path: Path, data: bytes, context: str) -> None:
        descriptor = os.open(
            path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
            0o700,
        )
        try:
            offset = 0
            while offset < len(data):
                written = os.write(descriptor, data[offset:])
                if written <= 0:
                    raise RefreshError(f"unable to copy {context}", 69)
                offset += written
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

    try:
        private_directory = Path(
            tempfile.mkdtemp(
                prefix=".archive-extract-",
                dir=destination.parent,
            )
        )
        os.chmod(private_directory, 0o700)
        private_extractor = private_directory / "archive-extract.py"
        write_private_file(
            private_extractor,
            extractor_snapshot.data,
            "archive validation extractor",
        )
        write_private_file(
            private_directory / "tar_guard.py",
            guard_snapshot.data,
            "archive validation TAR guard",
        )

        result = run_command(
            [
                "python3",
                str(private_extractor),
                "--archive",
                str(archive_path),
                "--type",
                archive_type,
                "--destination",
                str(destination),
                "--members",
                *members,
            ],
            capture=True,
            timeout=300,
        )
        if result.returncode != 0:
            detail = result.stderr.decode("utf-8", "replace").strip()
            raise RefreshError(
                f"release archive validation failed: {detail or result.returncode}"
            )
    finally:
        if private_directory is not None:
            shutil.rmtree(private_directory, ignore_errors=True)
    for member in members:
        extracted = destination / member
        try:
            metadata = extracted.lstat()
        except OSError as error:
            raise RefreshError(
                f"validated archive member is unavailable: {member}: {error}"
            ) from error
        if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
            raise RefreshError(
                f"validated archive member is not a regular file: {member}"
            )


def github_release_timestamp(release: dict[str, Any]) -> str:
    value = release.get("published_at")
    if not isinstance(value, str) or not value:
        raise RefreshError(
            "GitHub release metadata has no publication timestamp",
            69,
        )
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise RefreshError(
            f"GitHub release metadata has an invalid publication timestamp: {value}",
            69,
        ) from error
    return value


def validate_github_release(release: Any) -> dict[str, Any]:
    if not isinstance(release, dict):
        raise RefreshError("GitHub release metadata contains a non-object", 69)
    for flag in ("draft", "prerelease"):
        if not isinstance(release.get(flag), bool):
            raise RefreshError(
                f"GitHub release metadata has no valid {flag} flag",
                69,
            )
    tag = release.get("tag_name")
    if not isinstance(tag, str) or not tag:
        raise RefreshError("GitHub release metadata has no valid tag", 69)
    assets = release.get("assets")
    if not isinstance(assets, list):
        raise RefreshError(
            f"GitHub release metadata has no valid asset list: {tag}",
            69,
        )
    if not release["draft"]:
        github_release_timestamp(release)
    return release


def github_releases(
    source: str,
    cache: dict[str, list[dict[str, Any]]],
) -> list[dict[str, Any]]:
    if source in cache:
        return cache[source]
    owner, repository = source.split("/", 1)
    releases: list[dict[str, Any]] = []
    seen_release_ids: set[Any] = set()
    for page in range(1, MAXIMUM_GITHUB_RELEASE_PAGES + 1):
        url = (
            f"https://api.github.com/repos/{quote(owner, safe='')}/"
            f"{quote(repository, safe='')}/releases?per_page=100&page={page}"
        )
        value = parse_json_bytes(
            curl_bytes(url) or b"",
            "GitHub release metadata",
        )
        if not isinstance(value, list):
            raise RefreshError("GitHub release metadata is not a list", 69)
        for release in value:
            release = validate_github_release(release)
            identity = release.get("id")
            if identity is None:
                identity = (release.get("tag_name"), release.get("published_at"))
            if identity in seen_release_ids:
                continue
            seen_release_ids.add(identity)
            releases.append(release)
        if len(value) < 100:
            break
        if page == MAXIMUM_GITHUB_RELEASE_PAGES:
            raise RefreshError(
                "GitHub release pagination exceeded the supported page limit",
                69,
            )
    cache[source] = releases
    return releases


def unstable_tag(tag: str, patterns: list[str]) -> bool:
    return any(re.search(pattern, tag, re.IGNORECASE) for pattern in patterns)


def rolling_version(value: str) -> bool:
    return value.strip().lower() in {"master", "main", "head", "latest"}


def version_numbers(value: str) -> tuple[int, ...]:
    numbers = tuple(int(part) for part in re.findall(r"[0-9]+", value))
    return numbers + (0,) * max(0, 8 - len(numbers))


def is_prerelease_version(value: str) -> bool:
    return bool(re.search(r"-[0-9A-Za-z]", value))


def version_is_older(candidate: str, current: str) -> bool:
    candidate_numbers = version_numbers(candidate)
    current_numbers = version_numbers(current)
    if candidate_numbers != current_numbers:
        return candidate_numbers < current_numbers
    candidate_prerelease = is_prerelease_version(candidate)
    current_prerelease = is_prerelease_version(current)
    if candidate_prerelease != current_prerelease:
        return candidate_prerelease
    if candidate_prerelease and candidate != current:
        return candidate.lower() < current.lower()
    return False


def refresh_release_tool(
    name: str,
    tool: dict[str, Any],
    configured: dict[str, Any],
    release_cache: dict[str, list[dict[str, Any]]],
    sidecar_cache: dict[str, bytes | None],
    workspace: Path,
) -> tuple[str, dict[str, Any], list[str]]:
    source = str(configured.get("source", ""))
    releases = github_releases(source, release_cache)
    stable_releases = [
        release
        for release in releases
        if not release["draft"] and not release["prerelease"]
    ]
    stable_releases.sort(
        key=lambda release: (
            version_numbers(str(release["tag_name"])),
            github_release_timestamp(release),
        ),
        reverse=True,
    )
    required_architectures = configured_architectures(configured)
    specifications = configured.get("assets", {})
    skipped_releases: list[str] = []
    current_version = str(tool.get("version", ""))

    for release in stable_releases:
        tag = str(release["tag_name"])
        if not RELEASE_VERSION_PATTERN.fullmatch(tag):
            skipped_releases.append(f"{tag} (invalid tag)")
            continue
        if rolling_version(tag):
            skipped_releases.append(f"{tag} (rolling tag)")
            continue
        if version_is_older(tag, current_version):
            skipped_releases.append(f"{tag} (older than the current pin)")
            continue
        if unstable_tag(tag, configured.get("unstable_tag_patterns", [])):
            skipped_releases.append(f"{tag} (unstable tag)")
            continue

        release_assets = release.get("assets", [])
        if not isinstance(release_assets, list):
            raise RefreshError(f"release asset list is invalid: {name}/{tag}")
        for release_asset in release_assets:
            if not isinstance(release_asset, dict):
                raise RefreshError(f"release asset metadata is invalid: {name}/{tag}")

        selected: dict[str, dict[str, Any]] = {}
        missing: list[str] = []
        for architecture in sorted(required_architectures):
            specification = specifications.get(architecture)
            if not isinstance(specification, dict):
                continue
            pattern = specification.get("pattern")
            if not isinstance(pattern, str):
                raise RefreshError(
                    f"configured release pattern is invalid: {name}/{architecture}"
                )
            matches = [
                asset
                for asset in release_assets
                if re.fullmatch(pattern, str(asset.get("name", "")))
            ]
            if len(matches) > 1:
                raise RefreshError(
                    f"multiple {architecture} assets match {name} in release {tag}"
                )
            if not matches:
                missing.append(architecture)
                continue
            selected[architecture] = matches[0]
        if missing:
            skipped_releases.append(
                f"{tag} (missing {', '.join(missing)} asset)"
            )
            continue

        selected_architectures = sorted(selected)
        for index, first_architecture in enumerate(selected_architectures):
            for second_architecture in selected_architectures[index + 1 :]:
                if release_assets_collide(
                    selected[first_architecture],
                    selected[second_architecture],
                ):
                    raise RefreshError(
                        "the same release asset is selected for multiple "
                        f"architectures: {name}/{first_architecture} and "
                        f"{name}/{second_architecture}"
                    )

        refreshed_assets: dict[str, Any] = {}
        provenance: list[str] = []
        for architecture in sorted(required_architectures):
            specification = specifications.get(architecture)
            if not isinstance(specification, dict):
                raise RefreshError(
                    f"configured release asset is invalid: {name}/{architecture}"
                )
            candidate = selected[architecture]
            asset_name = candidate.get("name")
            url = candidate.get("browser_download_url")
            if (
                not isinstance(asset_name, str)
                or not asset_name
                or not isinstance(url, str)
                or not url.startswith("https://")
            ):
                raise RefreshError(
                    f"release asset URL is invalid: {name}/{architecture}"
                )
            filename = unquote(PurePosixPath(urlsplit(url).path).name)
            if filename != asset_name:
                raise RefreshError(
                    f"release asset URL does not match its filename: {name}/{architecture}"
                )
            validate_configured_url(
                url,
                mode="release",
                source=source,
                version=tag,
                context=f"{name}/{architecture}",
                filename=filename,
            )
            asset_size = candidate.get("size")
            if (
                not isinstance(asset_size, int)
                or isinstance(asset_size, bool)
                or asset_size <= 0
            ):
                raise RefreshError(
                    f"release asset size is invalid: {name}/{architecture}"
                )
            if asset_size > MAXIMUM_ASSET_SIZE:
                raise RefreshError(
                    f"release asset is too large: {name}/{architecture}"
                )
            asset_digest(candidate)

            archive_type = str(specification.get("type", ""))
            configured_files = configured_file_map(
                specification.get("files"),
                f"{name}/{architecture}",
            )
            archive_path = workspace / f"{name}-{architecture}-{filename}"
            curl_file(url, archive_path, expected_size=asset_size)
            calculated = sha256_file(archive_path)
            checksum, source_description = upstream_checksum(
                release_assets,
                candidate,
                filename,
                sidecar_cache,
                source=source,
                version=tag,
            )
            if checksum and checksum != calculated:
                raise RefreshError(
                    f"checksum mismatch for {name}/{architecture}: "
                    f"expected {checksum}, calculated {calculated}"
                )
            final_checksum = checksum or calculated
            files = refreshed_file_map(
                archive_path,
                archive_type,
                configured_files,
                url,
            )
            if archive_type != "none":
                validate_extracted_archive(
                    archive_path,
                    archive_type,
                    files,
                    workspace / f"extracted-{name}-{architecture}",
                )
            refreshed_assets[architecture] = {
                "url": url,
                "sha256": final_checksum,
                "type": archive_type,
                "files": files,
            }
            provenance.append(f"{architecture}: {source_description}")

        refreshed_tool = dict(tool)
        refreshed_tool["version"] = tag
        refreshed_tool["source"] = source
        refreshed_tool["assets"] = refreshed_assets
        if skipped_releases:
            print(
                f"  Skipped newer releases: {'; '.join(skipped_releases)}.",
                file=sys.stderr,
            )
        return tag, refreshed_tool, provenance

    detail = "; ".join(skipped_releases) if skipped_releases else "no stable releases"
    raise RefreshError(
        f"no stable release contains the required architecture assets for {name} "
        f"({detail})",
        69,
    )


def ncdu_release(page: str) -> tuple[str, dict[str, dict[str, str]]]:
    versions: dict[str, dict[str, dict[str, str]]] = {}
    for match in NCDU_HTML_PATTERN.finditer(page):
        filename = match.group("filename")
        details = match.group("details")
        checksum_match = NCDU_SHA256_PATTERN.search(details)
        if checksum_match is None:
            continue
        version_match = NCDU_ASSET_PATTERN.fullmatch(filename)
        if version_match is None:
            continue
        version = version_match.group(1)
        architecture = version_match.group(2)
        versions.setdefault(version, {})[architecture] = {
            "url": f"{NCDU_DOWNLOAD_URL}/{filename}",
            "sha256": checksum_match.group("checksum").lower(),
        }
    complete = {
        version: values
        for version, values in versions.items()
        if all(architecture in values for architecture in ARCHITECTURES)
    }
    if not complete:
        raise RefreshError(
            "the official ncdu download page has no complete binary release", 69
        )
    latest = max(
        complete,
        key=lambda version: tuple(int(part) for part in version.split(".")),
    )
    return latest, complete[latest]


def refresh_ncdu_tool(
    name: str,
    tool: dict[str, Any],
    configured: dict[str, Any],
    workspace: Path,
) -> tuple[str, dict[str, Any], list[str]]:
    page = (curl_bytes(NCDU_DOWNLOAD_URL) or b"").decode("utf-8", "replace")
    version, release_assets = ncdu_release(page)
    current_version = str(tool.get("version", ""))
    if version_is_older(version, current_version):
        raise RefreshError(
            f"the official ncdu release is older than the current pin: {version}"
        )
    specifications = configured.get("assets", {})
    refreshed_assets: dict[str, Any] = {}
    provenance: list[str] = []
    for architecture in ARCHITECTURES:
        release_asset = release_assets[architecture]
        url = release_asset["url"]
        filename = PurePosixPath(urlsplit(url).path).name
        specification = specifications.get(architecture)
        if not isinstance(specification, dict):
            raise RefreshError(f"configured ncdu asset is invalid: {name}/{architecture}")
        pattern = specification.get("pattern")
        if not isinstance(pattern, str) or not re.fullmatch(pattern, filename):
            raise RefreshError(
                f"official ncdu asset does not match the configuration: {name}/{architecture}"
            )
        archive_type = str(specification.get("type", ""))
        configured_files = configured_file_map(
            specification.get("files"),
            f"{name}/{architecture}",
        )
        asset_path = workspace / f"{name}-{architecture}-{filename}"
        curl_file(url, asset_path)
        calculated = sha256_file(asset_path)
        expected = release_asset["sha256"]
        if expected != calculated:
            raise RefreshError(
                f"checksum mismatch for {name}/{architecture}: "
                f"expected {expected}, calculated {calculated}"
            )
        files = refreshed_file_map(
            asset_path,
            archive_type,
            configured_files,
            url,
        )
        if archive_type != "none":
            validate_extracted_archive(
                asset_path,
                archive_type,
                files,
                workspace / f"extracted-{name}-{architecture}",
            )
        refreshed_assets[architecture] = {
            "url": url,
            "sha256": calculated,
            "type": archive_type,
            "files": files,
        }
        provenance.append(f"{architecture}: official ncdu page checksum")
    refreshed_tool = dict(tool)
    refreshed_tool["version"] = version
    refreshed_tool["source"] = str(configured.get("source", "yorhel/ncdu"))
    refreshed_tool["assets"] = refreshed_assets
    return version, refreshed_tool, provenance


def github_commit_comparison_status(
    source: str,
    base: str,
    head: str,
) -> str:
    """Return GitHub's validated ancestry status for two commits."""

    owner, repository = source.split("/", 1)
    url = (
        f"https://api.github.com/repos/{quote(owner, safe='')}/"
        f"{quote(repository, safe='')}/compare/"
        f"{quote(base, safe='')}...{quote(head, safe='')}?per_page=1"
    )
    value = parse_json_bytes(
        curl_bytes(url) or b"",
        "GitHub commit comparison metadata",
    )
    if not isinstance(value, dict):
        raise RefreshError("GitHub commit comparison metadata is invalid", 69)
    status = value.get("status")
    if status not in {"ahead", "behind", "diverged", "identical"}:
        raise RefreshError(
            "GitHub commit comparison metadata has no valid status",
            69,
        )

    base_commit = value.get("base_commit")
    if (
        not isinstance(base_commit, dict)
        or base_commit.get("sha") != base
    ):
        raise RefreshError(
            "GitHub commit comparison metadata has an invalid base commit",
            69,
        )
    ahead_by = value.get("ahead_by")
    behind_by = value.get("behind_by")
    if (
        not isinstance(ahead_by, int)
        or isinstance(ahead_by, bool)
        or ahead_by < 0
        or not isinstance(behind_by, int)
        or isinstance(behind_by, bool)
        or behind_by < 0
    ):
        raise RefreshError(
            "GitHub commit comparison metadata has invalid commit counts",
            69,
        )
    if (
        (status == "ahead" and (behind_by != 0 or ahead_by == 0))
        or (status == "behind" and (ahead_by != 0 or behind_by == 0))
        or (status == "identical" and (ahead_by != 0 or behind_by != 0))
        or (status == "diverged" and (ahead_by == 0 or behind_by == 0))
    ):
        raise RefreshError(
            "GitHub commit comparison metadata has inconsistent commit counts",
            69,
        )
    total_commits = value.get("total_commits")
    if (
        not isinstance(total_commits, int)
        or isinstance(total_commits, bool)
        or total_commits < 0
    ):
        raise RefreshError(
            "GitHub commit comparison metadata has an invalid total count",
            69,
        )
    merge_base = value.get("merge_base_commit")
    if merge_base is not None and (
        not isinstance(merge_base, dict)
        or not isinstance(merge_base.get("sha"), str)
        or not COMMIT_PATTERN.fullmatch(merge_base["sha"])
    ):
        raise RefreshError(
            "GitHub commit comparison metadata has an invalid merge base",
            69,
        )
    head_commit = value.get("head_commit")
    if head_commit is not None and (
        not isinstance(head_commit, dict)
        or head_commit.get("sha") != head
    ):
        raise RefreshError(
            "GitHub commit comparison metadata has an invalid head commit",
            69,
        )
    return str(status)


def refresh_commit_tool(
    name: str,
    tool: dict[str, Any],
    configured: dict[str, Any],
    workspace: Path,
) -> tuple[str, dict[str, Any], list[str]]:
    source = str(configured.get("source", ""))
    ref = str(configured.get("ref", ""))
    commit_path = str(configured.get("path", ""))
    owner, repository = source.split("/", 1)
    api_url = (
        f"https://api.github.com/repos/{quote(owner, safe='')}/"
        f"{quote(repository, safe='')}/commits/{quote(ref, safe='')}"
    )
    value = parse_json_bytes(
        curl_bytes(api_url) or b"",
        "GitHub commit metadata",
    )
    if not isinstance(value, dict):
        raise RefreshError("GitHub commit metadata is invalid", 69)
    commit = value.get("sha")
    if not isinstance(commit, str) or not COMMIT_PATTERN.fullmatch(commit):
        raise RefreshError(f"GitHub commit metadata has no valid SHA: {name}", 69)

    current_commit = str(tool.get("version", ""))
    if not COMMIT_PATTERN.fullmatch(current_commit):
        raise RefreshError(f"current commit pin is invalid: {name}", 69)
    if commit != current_commit:
        comparison = github_commit_comparison_status(
            source,
            current_commit,
            commit,
        )
        if comparison not in {"ahead", "identical"}:
            raise RefreshError(
                f"candidate commit is not newer than the current pin: {name}",
                69,
            )

    encoded_path = "/".join(quote(part, safe="") for part in commit_path.split("/"))
    url = f"https://raw.githubusercontent.com/{source}/{commit}/{encoded_path}"
    filename = PurePosixPath(commit_path).name
    specification = configured.get("assets", {}).get("any")
    if not isinstance(specification, dict):
        raise RefreshError(f"configured commit asset is invalid: {name}")
    archive_type = str(specification.get("type", ""))
    files = configured_file_map(specification.get("files"), f"{name}/any")
    if archive_type != "none":
        raise RefreshError(f"configured commit asset must be standalone: {name}")
    if filename not in files:
        raise RefreshError(
            f"configured commit file does not match the source path: {name}"
        )
    asset_path = workspace / f"{name}-{filename}"
    curl_file(url, asset_path)
    checksum = sha256_file(asset_path)
    refreshed_tool = dict(tool)
    refreshed_tool["version"] = commit
    refreshed_tool["source"] = source
    refreshed_tool["assets"] = {
        "any": {
            "url": url,
            "sha256": checksum,
            "type": archive_type,
            "files": files,
        }
    }
    return commit, refreshed_tool, ["any: calculated locally"]


def select_tools(
    arguments: argparse.Namespace,
    registry: list[str],
    excluded: set[str],
) -> list[str]:
    if arguments.all and arguments.tool:
        raise RefreshError("--all and --tool cannot be used together", 64)
    if not arguments.all and not arguments.tool:
        raise RefreshError("select --tool NAME or --all", 64)

    selected: list[str] = []
    if arguments.all:
        selected = list(registry)
    else:
        for value in arguments.tool:
            for name in value.split(","):
                name = name.strip()
                if name and name not in selected:
                    selected.append(name)

    if not selected:
        raise RefreshError("select --tool NAME or --all", 64)

    rolling = sorted(set(selected) & excluded)
    if rolling:
        raise RefreshError(
            "rolling tools are managed outside the extras manifest: "
            + ", ".join(rolling),
            69,
        )
    unknown = sorted(set(selected) - set(registry))
    if unknown:
        raise RefreshError(f"unknown tool identifier: {', '.join(unknown)}", 69)
    return selected


def copy_regular_file(source: Path, destination: Path, context: str) -> None:
    data = read_source_bytes(source, context)
    descriptor = os.open(
        destination,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
        0o600,
    )
    try:
        offset = 0
        while offset < len(data):
            written = os.write(descriptor, data[offset:])
            if written <= 0:
                raise RefreshError(f"unable to copy {context}", 69)
            offset += written
    finally:
        os.close(descriptor)


def reject_validation_symlinks(root: Path) -> None:
    for directory, names, files in os.walk(root, followlinks=False):
        for name in names + files:
            path = Path(directory) / name
            try:
                metadata = path.lstat()
            except OSError as error:
                raise RefreshError(
                    f"unable to inspect the validation copy: {path}: {error}",
                    69,
                ) from error
            if stat.S_ISLNK(metadata.st_mode):
                raise RefreshError(
                    f"the validation copy contains a symbolic link: {path}",
                    69,
                )
            if not stat.S_ISREG(metadata.st_mode) and not stat.S_ISDIR(metadata.st_mode):
                raise RefreshError(
                    f"the validation copy contains a special file: {path}",
                    69,
                )


def copy_validation_repository(repository: Path, destination: Path) -> None:
    for directory in ("common", "extras", "silverblue", "tools", "workstation", "tests"):
        source = repository / directory
        if source.is_symlink():
            raise RefreshError(
                f"the validation source directory is a symbolic link: {source}",
                69,
            )
        if source.exists():
            shutil.copytree(
                source,
                destination / directory,
                ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
                symlinks=True,
            )
    source_root = Path(__file__).resolve().parent.parent
    (destination / "tools").mkdir(parents=True, exist_ok=True)
    (destination / "extras").mkdir(parents=True, exist_ok=True)
    refresher_source = Path(__file__).resolve()
    if refresher_source.is_file():
        refresher_destination = destination / "tools" / "refresh-extras-manifest.py"
        refresher_destination.unlink(missing_ok=True)
        copy_regular_file(
            refresher_source,
            refresher_destination,
            "extras refresher",
        )
    for helper_name, helper_context in (
        ("archive-extract.py", "archive validation extractor"),
        ("manifest_url.py", "manifest URL validator"),
        ("tar_guard.py", "archive validation TAR guard"),
    ):
        helper_source = source_root / "extras" / helper_name
        if helper_source.is_file():
            helper_destination = destination / "extras" / helper_name
            helper_destination.unlink(missing_ok=True)
            copy_regular_file(
                helper_source,
                helper_destination,
                helper_context,
            )
    for filename in ("fedora-postinstall.sh", "README.md"):
        source = repository / filename
        if source.exists():
            copy_regular_file(
                source,
                destination / filename,
                f"validation input {filename}",
            )
    reject_validation_symlinks(destination)


def run_local_validation(
    repository: Path,
    candidate: dict[str, Any],
) -> None:
    test_file = repository / "tests" / "unit" / "extras.bats"
    if not test_file.exists():
        raise RefreshError(f"extras validation test is unavailable: {test_file}", 69)
    bats = shutil.which("bats")
    if bats is None:
        raise RefreshError("bats is unavailable", 69)

    with tempfile.TemporaryDirectory(prefix="extras-manifest-validation.") as directory:
        validation_repository = Path(directory)
        copy_validation_repository(repository, validation_repository)
        candidate_file = validation_repository / "extras" / "tools-manifest.json"
        candidate_text = manifest_text(candidate)
        candidate_file.write_text(candidate_text, encoding="utf-8")
        expected_file = validation_repository / "candidate-tools-manifest.json"
        expected_file.write_text(candidate_text, encoding="utf-8")
        candidate_test = validation_repository / "tests" / "unit" / "extras-candidate.bats"
        candidate_test.write_text(
            """#!/usr/bin/env bats
@test "the validated candidate manifest is the file under test" {
    run cmp "${CANDIDATE_MANIFEST}" "${EXPECTED_MANIFEST}"
    [ "${status}" -eq 0 ]
    run python3 tools/refresh-extras-manifest.py --repository . --validate
    [ "${status}" -eq 0 ]
}
""",
            encoding="utf-8",
        )

        jq = shutil.which("jq")
        if jq:
            result = run_command([jq, "empty", str(candidate_file)], capture=True)
            if result.returncode != 0:
                detail = result.stderr.decode("utf-8", "replace").strip()
                raise RefreshError(f"manifest JSON validation failed: {detail}")
        else:
            load_manifest(candidate_file)

        result = run_command(
            [
                bats,
                "--print-output-on-failure",
                "tests/unit/extras-candidate.bats",
                "tests/unit/extras.bats",
            ],
            capture=True,
            cwd=validation_repository,
            timeout=1800,
            env={
                **sanitized_environment(),
                "CANDIDATE_MANIFEST": str(candidate_file),
                "EXPECTED_MANIFEST": str(expected_file),
            },
        )
        if result.returncode != 0:
            output = result.stdout.decode("utf-8", "replace")
            error = result.stderr.decode("utf-8", "replace")
            sys.stderr.write(output)
            sys.stderr.write(error)
            raise RefreshError("extras validation tests failed")


@contextmanager
def refresh_lock(path: Path) -> Iterator[None]:
    identity = hashlib.sha256(str(path).encode("utf-8")).hexdigest()[:20]
    # The lock scope belongs to the invoking user, not to HOME or TMPDIR. A
    # caller that changes either environment variable must still contend with
    # the refresher that is already updating the same manifest.
    lock_directory = Path("/tmp") / f"fedora-postinstall-refresh-{os.getuid()}"
    try:
        lock_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        metadata = lock_directory.lstat()
    except OSError as error:
        raise RefreshError(
            f"unable to create the extras refresh lock directory: {error}",
            75,
        ) from error
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or stat.S_IMODE(metadata.st_mode) & 0o077
    ):
        raise RefreshError(
            "the extras refresh lock directory is not private",
            75,
        )
    lock_path = lock_directory / f"fedora-postinstall-extras-{identity}.lock"
    descriptor = -1
    try:
        descriptor = os.open(
            lock_path,
            os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW,
            0o600,
        )
        try:
            metadata = os.fstat(descriptor)
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_nlink != 1
                or metadata.st_uid != os.geteuid()
            ):
                raise RefreshError(
                    "the extras refresh lock is not a private regular file",
                    75,
                )
            os.fchmod(descriptor, 0o600)
        except OSError as error:
            os.close(descriptor)
            descriptor = -1
            raise RefreshError(
                f"unable to open the extras refresh lock: {error}",
                75,
            ) from error
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RefreshError(
                "another extras manifest refresher is already running",
                75,
            ) from error
        yield
    finally:
        if descriptor >= 0:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
            except OSError:
                pass
            os.close(descriptor)


def verify_source_files(
    sources: dict[Path, SourceSnapshot],
    *,
    exclude: set[Path] | None = None,
) -> None:
    excluded = exclude or set()
    for path, original in sources.items():
        if path in excluded:
            continue
        current = read_source_snapshot(path, str(path))
        if (
            current.identity != original.identity
            or current.data != original.data
        ):
            raise RefreshError(
                f"the refresh input changed while the refresh was running: {path}",
                69,
            )


_REFRESH_TEST_FAILPOINTS_FIRED: set[str] = set()


def refresh_test_failpoint(name: str) -> None:
    if os.environ.get("POSTINSTALL_REFRESH_TEST_MODE") != "1":
        return
    configured = {
        value.strip()
        for value in os.environ.get(
            "POSTINSTALL_REFRESH_TEST_FAILPOINT",
            "",
        ).split(",")
        if value.strip()
    }
    if name not in configured or name in _REFRESH_TEST_FAILPOINTS_FIRED:
        return
    _REFRESH_TEST_FAILPOINTS_FIRED.add(name)

    suffix = name.upper()
    target_value = os.environ.get(
        f"POSTINSTALL_REFRESH_TEST_FAILPOINT_TARGET_{suffix}",
        os.environ.get("POSTINSTALL_REFRESH_TEST_FAILPOINT_TARGET", ""),
    )
    if not target_value:
        return
    target = Path(target_value)
    content = os.environ.get(
        f"POSTINSTALL_REFRESH_TEST_FAILPOINT_CONTENT_{suffix}",
        os.environ.get("POSTINSTALL_REFRESH_TEST_FAILPOINT_CONTENT", ""),
    )
    replacement = target.with_name(
        f".{target.name}.refresh-test-{os.getpid()}-{uuid.uuid4().hex}"
    )
    try:
        descriptor = os.open(
            replacement,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC,
            0o600,
        )
        try:
            data = content.encode("utf-8")
            offset = 0
            while offset < len(data):
                written = os.write(descriptor, data[offset:])
                if written <= 0:
                    raise RefreshError("unable to apply the refresher test failpoint", 69)
                offset += written
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        os.replace(replacement, target)
    except RefreshError:
        raise
    except OSError as error:
        try:
            replacement.unlink(missing_ok=True)
        except OSError:
            pass
        raise RefreshError(
            f"unable to apply the refresher test failpoint: {error}",
            69,
        ) from error


def rename_exchange(first: Path, second: Path) -> bool:
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        renameat2 = libc.renameat2
    except (AttributeError, OSError):
        return False
    renameat2.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    renameat2.restype = ctypes.c_int
    result = renameat2(
        -100,
        os.fsencode(first),
        -100,
        os.fsencode(second),
        2,
    )
    if result == 0:
        return True
    error_number = ctypes.get_errno()
    if error_number in {errno.ENOSYS, errno.EINVAL, errno.ENOTSUP}:
        return False
    raise OSError(error_number, os.strerror(error_number))


def fsync_directory(path: Path) -> None:
    directory_descriptor = os.open(
        path,
        os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC,
    )
    try:
        os.fsync(directory_descriptor)
    finally:
        os.close(directory_descriptor)


def manifest_exchange_drift(
    temporary: Path,
    path: Path,
    candidate: bytes,
    candidate_identity: tuple[int, int, int, int, int],
    sources: dict[Path, SourceSnapshot],
) -> str:
    expected = sources.get(path)
    if expected is None:
        return "the tracked extras manifest is not a registered refresh input"

    try:
        previous = read_source_snapshot(temporary, "previous extras manifest")
    except RefreshError as error:
        return str(error)
    if not snapshot_matches_expected(previous, expected):
        return "the extras manifest changed while the refresh was running"

    try:
        verify_source_files(sources, exclude={path})
    except RefreshError as error:
        return str(error)

    try:
        live = read_source_snapshot(path, "candidate extras manifest")
    except RefreshError as error:
        return str(error)
    if (
        live.data != candidate
        or live.identity[:2] != candidate_identity[:2]
    ):
        return "the candidate extras manifest was displaced while it was installed"
    return ""


def rollback_manifest_exchange(
    temporary: Path,
    path: Path,
    candidate: bytes,
    candidate_identity: tuple[int, int, int, int, int],
    expected: SourceSnapshot,
) -> tuple[bool, str]:
    try:
        previous = read_source_snapshot(temporary, "previous extras manifest")
        live = read_source_snapshot(path, "candidate extras manifest")
    except RefreshError as error:
        return False, str(error)
    if not snapshot_matches_expected(previous, expected):
        return (
            False,
            "the previous manifest recovery data changed; it was not restored",
        )
    if (
        live.data != candidate
        or live.identity[:2] != candidate_identity[:2]
    ):
        return (
            False,
            "the candidate manifest changed before it could be rolled back; "
            "the concurrent content was left in place",
        )

    # Recheck both recovery and live inodes immediately before the exchange.
    # This narrows the compare-and-swap window and prevents modified recovery
    # bytes from being transiently installed.
    refresh_test_failpoint("before_rollback_exchange")
    try:
        previous = read_source_snapshot(temporary, "previous extras manifest")
        live = read_source_snapshot(path, "candidate extras manifest")
    except RefreshError as error:
        return False, str(error)
    if not snapshot_matches_expected(previous, expected):
        return (
            False,
            "the previous manifest recovery data changed; it was not restored",
        )
    if (
        live.data != candidate
        or live.identity[:2] != candidate_identity[:2]
    ):
        return (
            False,
            "the candidate manifest changed before it could be rolled back; "
            "the concurrent content was left in place",
        )

    try:
        if not rename_exchange(temporary, path):
            return (
                False,
                "atomic manifest rollback is unavailable on this filesystem",
            )
        displaced = read_source_snapshot(
            temporary,
            "displaced extras manifest",
        )
        restored = read_source_snapshot(path, "restored extras manifest")
    except (OSError, RefreshError) as error:
        return False, str(error)

    if not snapshot_matches_expected(restored, expected):
        # The recovery inode changed after the preflight check. Restore the
        # verified candidate instead of leaving the modified recovery bytes
        # live, and retain the modified bytes for manual recovery.
        try:
            if not rename_exchange(temporary, path):
                return (
                    False,
                    "atomic restoration of the candidate manifest is unavailable",
                )
            restored_candidate = read_source_snapshot(
                path,
                "restored candidate extras manifest",
            )
        except (OSError, RefreshError) as error:
            return False, str(error)
        if (
            restored_candidate.data != candidate
            or restored_candidate.identity[:2] != candidate_identity[:2]
        ):
            return (
                False,
                "the candidate manifest identity changed while modified "
                "recovery data was being rejected; recovery data was retained",
            )
        return (
            False,
            "the previous manifest recovery data changed during rollback; "
            "the candidate was restored and recovery data was retained",
        )

    if (
        displaced.data == candidate
        and displaced.identity[:2] == candidate_identity[:2]
    ):
        try:
            temporary.unlink()
            fsync_directory(path.parent)
        except OSError as error:
            return False, f"unable to finalize the manifest rollback: {error}"
        return True, ""

    # The path changed between the final identity check and the exchange. The
    # first exchange displaced that concurrent content into the recovery file.
    # Exchange it back so the concurrent writer's bytes remain live, while the
    # previous manifest stays available as private recovery data.
    try:
        if not rename_exchange(temporary, path):
            return (
                False,
                "atomic restoration of the concurrent manifest is unavailable",
            )
        concurrent = read_source_snapshot(path, "concurrent extras manifest")
        retained_previous = read_source_snapshot(
            temporary,
            "retained previous extras manifest",
        )
    except (OSError, RefreshError) as error:
        return False, str(error)
    if (
        concurrent.data != displaced.data
        or concurrent.identity[:2] != displaced.identity[:2]
        or not snapshot_matches_expected(retained_previous, expected)
    ):
        return (
            False,
            "the concurrent manifest identity changed during restoration; "
            "recovery data was retained",
        )
    return (
        False,
        "the concurrent manifest content was restored; the previous manifest "
        "was retained as recovery data",
    )


def raise_manifest_drift(
    temporary: Path,
    path: Path,
    candidate: bytes,
    candidate_identity: tuple[int, int, int, int, int],
    expected: SourceSnapshot,
    drift_detail: str,
) -> None:
    refresh_test_failpoint("before_rollback")
    rolled_back, rollback_detail = rollback_manifest_exchange(
        temporary,
        path,
        candidate,
        candidate_identity,
        expected,
    )
    if not rolled_back:
        raise RefreshError(
            f"{drift_detail}; {rollback_detail}; recovery data retained at "
            f"{temporary}",
            69,
        )
    raise RefreshError(drift_detail, 69)


def write_manifest(
    path: Path,
    manifest: dict[str, Any],
    sources: dict[Path, SourceSnapshot],
) -> None:
    candidate = manifest_text(manifest).encode("utf-8")
    expected = sources.get(path)
    if expected is None:
        raise RefreshError("the tracked extras manifest is not a refresh input", 69)
    current = read_source_snapshot(path, "extras manifest")
    if not snapshot_matches_expected(current, expected):
        raise RefreshError(
            "the extras manifest changed while the refresh was running",
            69,
        )
    try:
        metadata = path.lstat()
    except OSError as error:
        raise RefreshError(f"unable to inspect {path}: {error}", 69) from error
    if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise RefreshError("the extras manifest is not a regular file", 69)

    descriptor = -1
    temporary: Path | None = None
    exchanged = False
    try:
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{path.name}.refresh-{os.getpid()}-",
            dir=path.parent,
        )
        temporary = Path(temporary_name)
        os.fchmod(descriptor, stat.S_IMODE(metadata.st_mode))
        offset = 0
        while offset < len(candidate):
            written = os.write(descriptor, candidate[offset:])
            if written <= 0:
                raise RefreshError("unable to write the candidate manifest")
            offset += written
        os.fsync(descriptor)
        candidate_identity = source_identity(os.fstat(descriptor))
        os.close(descriptor)
        descriptor = -1

        verify_source_files(sources)
        refresh_test_failpoint("before_exchange")
        try:
            current = read_source_snapshot(path, "extras manifest")
            staged = read_source_snapshot(temporary, "candidate extras manifest")
        except RefreshError as error:
            raise RefreshError(str(error), 69) from error
        if not snapshot_matches_expected(current, expected):
            raise RefreshError(
                "the extras manifest changed while the refresh was running",
                69,
            )
        if (
            staged.data != candidate
            or staged.identity[:2] != candidate_identity[:2]
        ):
            raise RefreshError(
                "the candidate extras manifest changed before it could be installed",
                69,
            )
        if not rename_exchange(temporary, path):
            raise RefreshError(
                "atomic manifest replacement is unavailable on this filesystem",
                69,
            )
        exchanged = True
        refresh_test_failpoint("after_exchange")
        try:
            fsync_directory(path.parent)
        except OSError as error:
            raise_manifest_drift(
                temporary,
                path,
                candidate,
                candidate_identity,
                expected,
                f"unable to sync the replaced extras manifest: {error}",
            )

        drift_detail = manifest_exchange_drift(
            temporary,
            path,
            candidate,
            candidate_identity,
            sources,
        )
        if drift_detail:
            raise_manifest_drift(
                temporary,
                path,
                candidate,
                candidate_identity,
                expected,
                drift_detail,
            )

        drift_detail = manifest_exchange_drift(
            temporary,
            path,
            candidate,
            candidate_identity,
            sources,
        )
        if drift_detail:
            raise_manifest_drift(
                temporary,
                path,
                candidate,
                candidate_identity,
                expected,
                drift_detail,
            )

        temporary.unlink()
        temporary = None
        fsync_directory(path.parent)
    except OSError as error:
        if descriptor >= 0:
            os.close(descriptor)
        if not exchanged and temporary is not None:
            try:
                temporary.unlink(missing_ok=True)
            except OSError:
                pass
        if exchanged:
            raise RefreshError(
                f"the extras manifest was replaced but could not be finalized: {error}",
                69,
            ) from error
        raise RefreshError(f"unable to write {path}: {error}", 69) from error
    except RefreshError:
        if descriptor >= 0:
            os.close(descriptor)
        if not exchanged and temporary is not None:
            try:
                temporary.unlink(missing_ok=True)
            except OSError:
                pass
        raise


def run_refresh(
    repository: Path,
    arguments: argparse.Namespace,
) -> int:
    registry_file = repository / "extras" / "tools-list.sh"
    configuration_file = repository / "tools" / "extras-refresh-config.json"
    manifest_file = repository / "extras" / "tools-manifest.json"

    registry_snapshot = read_source_snapshot(registry_file, "tool registry")
    configuration_snapshot = read_source_snapshot(
        configuration_file,
        "extras refresh configuration",
    )
    manifest_snapshot = read_source_snapshot(manifest_file, "extras manifest")
    registry_original = registry_snapshot.data
    configuration_original = configuration_snapshot.data
    manifest_original = manifest_snapshot.data
    sources = {
        registry_file: registry_snapshot,
        configuration_file: configuration_snapshot,
        manifest_file: manifest_snapshot,
    }

    registry = repository_registry(repository, registry_original)
    configuration = load_configuration(repository, configuration_original)
    excluded = set(configuration.get("excluded_rolling_tools", []))
    manifest = load_manifest(manifest_file, manifest_original)
    if arguments.validate:
        if arguments.all or arguments.tool:
            raise RefreshError("--validate does not accept tool selections", 64)
        validate_manifest(manifest, registry, configuration)
        verify_source_files(sources)
        print(
            "The tool registry, refresh configuration, and manifest are consistent.",
            file=sys.stderr,
        )
        return 0

    selected = select_tools(arguments, registry, excluded)
    validate_manifest(
        manifest,
        registry,
        configuration,
        allowed_drift=set(selected),
    )
    configured_tools = configuration.get("tools", {})
    refreshed_manifest = json.loads(json.dumps(manifest))
    release_cache: dict[str, list[dict[str, Any]]] = {}
    sidecar_cache: dict[str, bytes | None] = {}
    with tempfile.TemporaryDirectory(prefix="extras-manifest-refresh.") as directory:
        workspace = Path(directory)
        for name in selected:
            tool = manifest.get("tools", {}).get(name)
            configured = configured_tools.get(name)
            if not isinstance(tool, dict) or not isinstance(configured, dict):
                raise RefreshError(f"unknown tool identifier: {name}", 69)
            configured = dict(configured)
            configured["unstable_tag_patterns"] = configuration.get(
                "unstable_tag_patterns",
                [],
            )
            print(f"Refreshing {name}...", file=sys.stderr)
            mode = configured.get("mode")
            if mode == "release":
                version, refreshed_tool, provenance = refresh_release_tool(
                    name,
                    tool,
                    configured,
                    release_cache,
                    sidecar_cache,
                    workspace,
                )
            elif mode == "ncdu":
                version, refreshed_tool, provenance = refresh_ncdu_tool(
                    name,
                    tool,
                    configured,
                    workspace,
                )
            elif mode == "commit":
                version, refreshed_tool, provenance = refresh_commit_tool(
                    name,
                    tool,
                    configured,
                    workspace,
                )
            else:
                raise RefreshError(f"invalid refresh mode for {name}", 69)
            refreshed_manifest["tools"][name] = refreshed_tool
            print(
                f"  {version}: " + "; ".join(provenance),
                file=sys.stderr,
            )

    validate_manifest(refreshed_manifest, registry, configuration)
    candidate_text = manifest_text(refreshed_manifest)
    candidate_bytes = candidate_text.encode("utf-8")
    changed = manifest_original != candidate_bytes
    if changed:
        print("Proposed manifest diff:", file=sys.stderr)
        show_diff(manifest_original.decode("utf-8"), candidate_text)
    else:
        print("The selected manifest entries are already current.", file=sys.stderr)

    run_local_validation(repository, refreshed_manifest)
    verify_source_files(sources)

    if arguments.check:
        if changed:
            print(
                "The extras manifest is out of date; rerun with --write to update it.",
                file=sys.stderr,
            )
            return 1
        print("The extras manifest is current.", file=sys.stderr)
        return 0

    if not arguments.write:
        if changed:
            print(
                "No changes were written; review the diff and rerun with --write.",
                file=sys.stderr,
            )
        else:
            print("No changes were written.", file=sys.stderr)
        return 0

    if changed:
        verify_source_files(sources)
        write_manifest(
            manifest_file,
            refreshed_manifest,
            sources,
        )
        print(
            f"Updated {manifest_file}. Review the committed diff before merging.",
            file=sys.stderr,
        )
    else:
        print("The extras manifest was already current.", file=sys.stderr)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="refresh-extras-manifest",
        description="Refresh pinned release metadata in extras/tools-manifest.json.",
    )
    parser.add_argument(
        "--tool",
        action="append",
        default=[],
        help="tool identifier or comma-separated identifiers (repeatable)",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="refresh every registered extras tool",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="report drift without changing the manifest",
    )
    parser.add_argument(
        "--write",
        action="store_true",
        help="write the validated candidate to the tracked manifest",
    )
    parser.add_argument(
        "--validate",
        action="store_true",
        help="validate registry, configuration, and manifest consistency only",
    )
    parser.add_argument(
        "--repository",
        default=str(Path(__file__).resolve().parent.parent),
        help="repository root (maintainer testing option)",
    )
    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    arguments = parser.parse_args(argv)
    if arguments.check and arguments.write:
        print("refresh: --check and --write cannot be used together", file=sys.stderr)
        return 64
    if arguments.validate and (arguments.check or arguments.write):
        print("refresh: --validate cannot be combined with --check or --write", file=sys.stderr)
        return 64

    try:
        protect_token_process()
    except RefreshError as error:
        return fail(str(error), error.status)

    repository = Path(arguments.repository).expanduser().resolve()
    manifest_file = repository / "extras" / "tools-manifest.json"
    try:
        with refresh_lock(manifest_file):
            return run_refresh(repository, arguments)
    except RefreshError as error:
        return fail(str(error), error.status)
    except OSError as error:
        return fail(f"filesystem operation failed: {error}", 1)
    except (TypeError, ValueError) as error:
        return fail(f"invalid release or manifest data: {error}", 1)
    except KeyboardInterrupt:
        return fail("interrupted", 130)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
