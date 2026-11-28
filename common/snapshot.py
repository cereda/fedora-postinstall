#!/usr/bin/env python3

# SPDX-License-Identifier: MIT

"""Create, inspect, compare, and restore managed-home snapshots."""

from __future__ import annotations

import argparse
import datetime as dt
import errno
import fcntl
import hashlib
import json
import os
import posixpath
import re
import signal
import stat
import sys
import tarfile
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Iterator


SCHEMA_VERSION = 1
ID_PATTERN = re.compile(r"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$")
LABEL_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._ -]{0,119}$")
QUERY_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._ -]{0,127}$")
CONTROL_CHARACTER_PATTERN = re.compile(r"[\x00-\x1f\x7f-\x9f]")
STATE_TIMESTAMP_PATTERN = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"
)
MAXIMUM_METADATA_BYTES = 1024 * 1024
MAXIMUM_MANIFEST_BYTES = 64 * 1024 * 1024
MAXIMUM_STATE_BYTES = 16 * 1024 * 1024
MAXIMUM_RECOVERY_JOURNAL_BYTES = 4 * 1024 * 1024
MAXIMUM_SNAPSHOT_COUNT = 10_000
RECOVERY_JOURNAL_SCHEMA_VERSION = 2
WHOLE_RECOVERY_STATUSES = {
    "prepared",
    "in_progress",
    "recovery_required",
    "committed",
    "recovered",
}
SELECTIVE_RECOVERY_STATUSES = {
    "prepared",
    "in_progress",
    "recovery_required",
    "committed",
    "completed",
    "recovered",
}
SELECTIVE_RECORD_STATUSES = {
    "backup_intent",
    "replace_intent",
    "backed_up",
    "replaced",
    "committed",
    "cleaned",
    "backup_retained",
    "rolled_back",
}
RECOVERY_JOURNAL_PREFIX = ".fedora-postinstall-snapshot-recovery-"
RECOVERY_JOURNAL_SUFFIX = ".json"
MANAGED_ROOT_STATE_KEYS = {
    "workstation": "workstation:workstation/home-configuration.sh:ROOT_DIRECTORY_STRUCTURE",
    "silverblue": "silverblue:silverblue/home-configuration.sh:ROOT_DIRECTORY_STRUCTURE",
}
_FIRED_TEST_FAILPOINTS: set[str] = set()
_PENDING_SNAPSHOT_SIGNAL: int | None = None


class SnapshotError(Exception):
    """An expected snapshot operation failure."""

    def __init__(self, message: str, status: int = 1) -> None:
        super().__init__(message)
        self.status = status


class SnapshotUsageError(SnapshotError):
    """An invalid snapshot command or argument."""

    def __init__(self, message: str) -> None:
        super().__init__(message, 64)


class SnapshotInterrupted(Exception):
    """A termination signal received while a snapshot operation was active."""

    def __init__(self, signal_number: int) -> None:
        super().__init__(f"interrupted by signal {signal_number}")
        self.signal_number = signal_number
        self.status = 128 + signal_number


class SnapshotArgumentParser(argparse.ArgumentParser):
    """Argument parser that reports usage errors with status 64."""

    def error(self, message: str) -> None:
        raise SnapshotUsageError(message)


@dataclass(frozen=True)
class StorageLayout:
    path: Path
    components: tuple[str, ...]


@dataclass
class LoadedSnapshot:
    name: str
    directory_fd: int
    archive_fd: int
    archive_identity: tuple[int, ...]
    metadata_identity: tuple[int, ...]
    manifest_identity: tuple[int, ...]
    metadata: dict[str, Any]
    manifest: dict[str, Any]

    def close(self) -> None:
        for descriptor in (self.archive_fd, self.directory_fd):
            if descriptor >= 0:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
        self.archive_fd = -1
        self.directory_fd = -1


def fail(message: str, status: int = 1) -> int:
    print(f"snapshot: {terminal_safe_text(str(message))}", file=sys.stderr)
    return status


def terminal_safe_text(value: str) -> str:
    value = str(value)
    value = CONTROL_CHARACTER_PATTERN.sub(
        lambda match: f"\\x{ord(match.group(0)):02x}", value
    )
    # argv may contain undecodable bytes represented by surrogate code points.
    # Escaping them prevents a diagnostic from failing while writing to stderr.
    return re.sub(
        r"[\ud800-\udfff]",
        lambda match: f"\\u{ord(match.group(0)):04x}",
        value,
    )


def home_directory() -> Path:
    value = os.environ.get("HOME", "")
    if not value:
        raise SnapshotUsageError("HOME is not set")
    try:
        home = Path(value).resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise SnapshotError(f"unable to resolve the home directory: {error}") from error
    if CONTROL_CHARACTER_PATTERN.search(str(home)):
        raise SnapshotUsageError("HOME contains an unsafe control character")
    return home


def lexical_absolute(path: Path) -> Path:
    return Path(os.path.abspath(os.path.expanduser(str(path))))


def canonical_absolute(path: Path) -> Path:
    return Path(os.path.realpath(lexical_absolute(path)))


def validate_home_path(
    path: Path,
    home: Path,
    *,
    context: str,
    status: int = 1,
) -> Path:
    candidate = lexical_absolute(path)
    if CONTROL_CHARACTER_PATTERN.search(str(candidate)):
        raise SnapshotError(f"{context} contains an unsafe control character", status)
    candidate = canonical_absolute(candidate)
    if CONTROL_CHARACTER_PATTERN.search(str(candidate)):
        raise SnapshotError(f"{context} contains an unsafe control character", status)
    try:
        candidate.relative_to(home)
    except ValueError as error:
        raise SnapshotError(f"{context} is outside the home directory: {candidate}", status) from error
    if candidate == home:
        raise SnapshotError(f"{context} must not be the home directory itself", status)
    return candidate


def home_relative_components(path: Path, home: Path) -> tuple[str, ...]:
    return path.relative_to(home).parts


def storage_layout(home: Path) -> StorageLayout:
    configured = os.environ.get("POSTINSTALL_SNAPSHOT_DIR", "")
    if configured:
        if os.environ.get("POSTINSTALL_SNAPSHOT_TEST_MODE") != "1":
            raise SnapshotUsageError(
                "POSTINSTALL_SNAPSHOT_DIR is available only with POSTINSTALL_SNAPSHOT_TEST_MODE=1"
            )
        path = validate_home_path(
            Path(configured),
            home,
            context="snapshot storage",
            status=64,
        )
        components = home_relative_components(path, home)
        if not components:
            raise SnapshotUsageError("snapshot storage must not be the home directory itself")
        return StorageLayout(path=path, components=components)

    return StorageLayout(
        path=home / ".host" / "backups" / "snapshots",
        components=(".host", "backups", "snapshots"),
    )


def invocation_directory() -> Path:
    configured = os.environ.get("POSTINSTALL_INVOCATION_DIRECTORY", "").strip()
    if configured:
        return lexical_absolute(Path(configured))
    return Path.cwd()


def state_file_path(home: Path) -> Path:
    configured = os.environ.get("POSTINSTALL_STATE_FILE", "").strip()
    if configured:
        candidate = Path(configured)
        if not candidate.is_absolute():
            candidate = invocation_directory() / candidate
        return lexical_absolute(candidate)

    state_root = os.environ.get("XDG_STATE_HOME", "").strip()
    if state_root:
        candidate = Path(state_root)
        if not candidate.is_absolute():
            candidate = invocation_directory() / candidate
        return lexical_absolute(candidate) / "fedora-postinstall" / "state.tsv"
    return home / ".local" / "state" / "fedora-postinstall" / "state.tsv"


def inspect_trusted_state_directory(
    descriptor: int,
    context: str,
    *,
    allow_sticky: bool,
) -> None:
    metadata = os.fstat(descriptor)
    if not stat.S_ISDIR(metadata.st_mode):
        raise SnapshotError(f"runtime state path contains a non-directory component: {context}")
    if metadata.st_uid not in {0, os.geteuid()}:
        raise SnapshotError(
            f"runtime state path is not owned by the current user or root: {context}"
        )
    mode = stat.S_IMODE(metadata.st_mode)
    if mode & 0o022 and not (allow_sticky and mode & stat.S_ISVTX):
        raise SnapshotError(
            f"runtime state path is writable by another user: {context}"
        )


def open_trusted_state_file(path: Path) -> int | None:
    absolute = lexical_absolute(path)
    name = absolute.name
    if not name or name in {".", ".."}:
        raise SnapshotError(f"invalid runtime state file name: {absolute}")

    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    descriptor = os.open(absolute.anchor, flags)
    try:
        inspect_trusted_state_directory(
            descriptor,
            str(absolute.anchor),
            allow_sticky=True,
        )
        for component in absolute.parts[1:-1]:
            if component in {".", ".."}:
                raise SnapshotError(f"unsafe runtime state path: {absolute}")
            try:
                child = os.open(component, flags, dir_fd=descriptor)
            except FileNotFoundError:
                return None
            except OSError as error:
                if error.errno in (errno.ELOOP, errno.ENOTDIR):
                    raise SnapshotError(
                        "runtime state path contains an unsafe symbolic-link or non-directory component"
                    ) from error
                raise SnapshotError(
                    f"unable to inspect the runtime state path: {error}"
                ) from error
            try:
                inspect_trusted_state_directory(
                    child,
                    str(absolute.parent),
                    allow_sticky=True,
                )
            except BaseException:
                os.close(child)
                raise
            os.close(descriptor)
            descriptor = child

        try:
            inspect_trusted_state_directory(
                descriptor,
                str(absolute.parent),
                allow_sticky=False,
            )
            file_descriptor = os.open(
                name,
                os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK,
                dir_fd=descriptor,
            )
        except FileNotFoundError:
            return None
        except OSError as error:
            if error.errno in (errno.ELOOP, errno.ENOTDIR):
                raise SnapshotError(
                    "runtime state path contains an unsafe symbolic-link or non-directory component"
                ) from error
            raise SnapshotError(f"unable to read the runtime state file: {error}") from error
        return file_descriptor
    finally:
        os.close(descriptor)


def discover_managed_root(home: Path) -> Path | None:
    path = state_file_path(home)
    if CONTROL_CHARACTER_PATTERN.search(str(path)):
        raise SnapshotUsageError("runtime state path contains an unsafe control character")

    descriptor = open_trusted_state_file(path)
    if descriptor is None:
        return None

    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise SnapshotError("runtime state file is not a regular file")
        if metadata.st_uid != os.geteuid():
            raise SnapshotError("runtime state file is not owned by the current user")
        if metadata.st_nlink != 1:
            raise SnapshotError("runtime state file must not have multiple hard links")
        if stat.S_IMODE(metadata.st_mode) & 0o022:
            raise SnapshotError("runtime state file is writable by another user")
        if metadata.st_size > MAXIMUM_STATE_BYTES:
            raise SnapshotError("runtime state file exceeds the supported size")

        content = bytearray()
        while len(content) <= MAXIMUM_STATE_BYTES:
            chunk = os.read(descriptor, 64 * 1024)
            if not chunk:
                break
            content.extend(chunk)
        if len(content) > MAXIMUM_STATE_BYTES:
            raise SnapshotError("runtime state file exceeds the supported size")
    finally:
        os.close(descriptor)

    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError as error:
        raise SnapshotError("runtime state file is not valid UTF-8") from error

    flavor = os.environ.get("POSTINSTALL_FLAVOR", "").strip().lower()
    if flavor in {"auto", ""}:
        selected_keys = set(MANAGED_ROOT_STATE_KEYS.values())
    elif flavor in MANAGED_ROOT_STATE_KEYS:
        selected_keys = {MANAGED_ROOT_STATE_KEYS[flavor]}
    else:
        raise SnapshotUsageError(f"invalid Fedora flavor: {flavor}")

    discovered_values: dict[str, Path] = {}
    for line in text.splitlines():
        fields = line.split("\t")
        if len(fields) != 4 or not all(fields):
            raise SnapshotError("runtime state file contains a malformed record")
        record_type, key, value, timestamp = fields
        if record_type not in {"module", "value"}:
            raise SnapshotError("runtime state file contains a malformed record")
        if not STATE_TIMESTAMP_PATTERN.fullmatch(timestamp):
            raise SnapshotError("runtime state file contains a malformed record")
        if record_type != "value" or key not in selected_keys:
            continue

        candidate = Path(value)
        if not candidate.is_absolute():
            # Runtime state is append-only. An invalid newer value must not
            # hide an earlier valid value for the same flavor.
            continue
        try:
            canonical = validate_home_path(
                candidate,
                home,
                context="saved managed root",
                status=1,
            )
        except SnapshotError:
            continue
        # Runtime state is append-only; the latest valid canonical value for
        # each flavor is authoritative.
        discovered_values[key] = canonical

    distinct_values = set(discovered_values.values())
    if len(distinct_values) > 1:
        raise SnapshotError(
            "runtime state contains multiple managed roots; select a flavor to "
            "disambiguate snapshot discovery"
        )
    if not discovered_values:
        return None
    return next(iter(distinct_values))


def managed_root(home: Path, *, require_discovery: bool = False) -> Path:
    configured = os.environ.get("POSTINSTALL_ROOT_DIRECTORY_STRUCTURE", "")
    if configured:
        if os.environ.get("POSTINSTALL_SNAPSHOT_TEST_MODE") != "1":
            raise SnapshotUsageError(
                "POSTINSTALL_ROOT_DIRECTORY_STRUCTURE is available only with "
                "POSTINSTALL_SNAPSHOT_TEST_MODE=1"
            )
        return validate_home_path(
            Path(configured),
            home,
            context="managed root override",
            status=64,
        )

    discovered = discover_managed_root(home)
    if discovered is not None:
        return validate_home_path(
            discovered,
            home,
            context="saved managed root",
            status=1,
        )
    if require_discovery:
        raise SnapshotError(
            "the managed root is unavailable; run the installer to save its "
            "runtime state",
            1,
        )
    return validate_home_path(
        home / ".host",
        home,
        context="managed root",
        status=1,
    )


def storage_relative_to_root(
    root_components: tuple[str, ...],
    storage_components: tuple[str, ...],
) -> tuple[str, ...] | None:
    if storage_components == root_components:
        raise SnapshotError("the snapshot storage directory must not be the managed root")
    if len(storage_components) > len(root_components) and storage_components[
        : len(root_components)
    ] == root_components:
        return storage_components[len(root_components) :]
    if len(root_components) > len(storage_components) and root_components[
        : len(storage_components)
    ] == storage_components:
        raise SnapshotError(
            "the managed root must not be located inside the snapshot storage directory"
        )
    return None


def selected_path_overlaps_storage(
    requested: Iterable[str],
    storage_relative: tuple[str, ...] | None,
) -> str | None:
    if not storage_relative:
        return None
    storage = storage_relative
    for value in requested:
        candidate = tuple(part for part in value.split("/") if part)
        if not candidate:
            continue
        common_length = min(len(candidate), len(storage))
        if candidate[:common_length] != storage[:common_length]:
            continue
        return value
    return None


def path_is_at_or_below(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
    except ValueError:
        return False
    return True


def validate_runtime_control_paths(root: Path, home: Path) -> None:
    candidates: list[tuple[str, Path]] = [
        ("runtime state file", state_file_path(home)),
    ]
    configured_cache = os.environ.get("POSTINSTALL_CACHE_DIR", "").strip()
    if configured_cache:
        candidates.append(("installer cache directory", Path(configured_cache)))
    configured_lock = os.environ.get("POSTINSTALL_LOCK_FILE", "").strip()
    if configured_lock:
        candidates.append(("installer lock file", Path(configured_lock)))

    for description, candidate in candidates:
        absolute = canonical_absolute(candidate)
        if path_is_at_or_below(absolute, root):
            raise SnapshotError(
                f"the {description} must not be located inside the managed root: {absolute}",
                64,
            )


def open_home_directory(home: Path) -> int:
    try:
        descriptor = os.open(
            home,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
        )
    except OSError as error:
        raise SnapshotError(f"unable to open the home directory safely: {error}") from error
    metadata = os.fstat(descriptor)
    if not stat.S_ISDIR(metadata.st_mode):
        os.close(descriptor)
        raise SnapshotError("the home path is not a directory")
    if metadata.st_uid != os.geteuid():
        os.close(descriptor)
        raise SnapshotError("the home directory is not owned by the current user")
    return descriptor


def open_directory_component(
    parent_descriptor: int,
    component: str,
    *,
    create: bool,
    private: bool,
) -> int | None:
    descriptor = -1
    try:
        descriptor = os.open(
            component,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=parent_descriptor,
        )
    except FileNotFoundError:
        if not create:
            return None
        try:
            os.mkdir(component, 0o700, dir_fd=parent_descriptor)
        except FileExistsError:
            pass
        except OSError as error:
            raise SnapshotError(
                f"unable to create directory component '{component}': {error}"
            ) from error
        try:
            descriptor = os.open(
                component,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=parent_descriptor,
            )
        except OSError as error:
            if error.errno in (errno.ELOOP, errno.ENOTDIR):
                raise SnapshotError(
                    f"snapshot path contains an unsafe symbolic-link or non-directory component: {component}"
                ) from error
            raise SnapshotError(
                f"unable to open directory component '{component}': {error}"
            ) from error
    except OSError as error:
        if error.errno in (errno.ELOOP, errno.ENOTDIR):
            raise SnapshotError(
                f"snapshot path contains an unsafe symbolic-link or non-directory component: {component}"
            ) from error
        raise SnapshotError(
            f"unable to open directory component '{component}': {error}"
        ) from error

    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISDIR(metadata.st_mode):
            raise SnapshotError(f"path component is not a directory: {component}")
        if metadata.st_uid != os.geteuid():
            raise SnapshotError(f"path component is not owned by the current user: {component}")
        if private:
            os.fchmod(descriptor, 0o700)
    except BaseException:
        os.close(descriptor)
        raise
    return descriptor


def open_components_from_descriptor(
    base_descriptor: int,
    components: Iterable[str],
    *,
    create: bool = False,
    private: bool = False,
) -> int | None:
    descriptor = os.dup(base_descriptor)
    try:
        for component in components:
            next_descriptor = open_directory_component(
                descriptor,
                component,
                create=create,
                private=private,
            )
            if next_descriptor is None:
                os.close(descriptor)
                return None
            os.close(descriptor)
            descriptor = next_descriptor
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def open_directory_under_home(
    home: Path,
    path: Path,
    *,
    create: bool = False,
    private: bool = False,
) -> int | None:
    components = home_relative_components(path, home)
    home_descriptor = open_home_directory(home)
    try:
        return open_components_from_descriptor(
            home_descriptor,
            components,
            create=create,
            private=private,
        )
    finally:
        os.close(home_descriptor)


def open_storage_directory(
    layout: StorageLayout,
    home: Path,
    *,
    create: bool,
) -> int | None:
    return open_directory_under_home(
        home,
        layout.path,
        create=create,
        private=create,
    )


def validate_entry_name(name: str, context: str = "directory entry") -> str:
    """Require a single, relative directory entry name.

    ``dir_fd``-relative filesystem calls ignore the descriptor when the name
    is absolute. Journal-controlled names therefore must never be allowed to
    contain a path separator or become ``.``/``..``.
    """

    if (
        not isinstance(name, str)
        or not name
        or name in {".", ".."}
        or "/" in name
        or "\\" in name
        or CONTROL_CHARACTER_PATTERN.search(name)
    ):
        raise SnapshotError(f"invalid {context}: {terminal_safe_text(str(name))}")
    return name


def entry_exists_at(parent_descriptor: int, name: str) -> bool:
    validate_entry_name(name)
    try:
        os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        return True
    except FileNotFoundError:
        return False
    except OSError as error:
        raise SnapshotError(f"unable to inspect '{name}': {error}") from error


def decode_mountinfo_path(value: str) -> str:
    return (
        value.replace("\\040", " ")
        .replace("\\011", "\t")
        .replace("\\012", "\n")
        .replace("\\134", "\\")
    )


def mountinfo_path() -> Path:
    configured = os.environ.get("POSTINSTALL_SNAPSHOT_MOUNTINFO", "").strip()
    if configured:
        if os.environ.get("POSTINSTALL_SNAPSHOT_TEST_MODE") != "1":
            raise SnapshotUsageError(
                "POSTINSTALL_SNAPSHOT_MOUNTINFO is available only with "
                "POSTINSTALL_SNAPSHOT_TEST_MODE=1"
            )
        return lexical_absolute(Path(configured))
    return Path("/proc/self/mountinfo")


def read_mount_ids() -> dict[Path, int]:
    mounts: dict[Path, int] = {}
    source = mountinfo_path()
    try:
        with source.open("r", encoding="utf-8") as stream:
            for line in stream:
                fields = line.rstrip("\n").split(" - ", 1)
                if not fields:
                    continue
                mount_fields = fields[0].split()
                if len(mount_fields) < 5:
                    continue
                try:
                    mount_id = int(mount_fields[0])
                except ValueError:
                    continue
                mount_point = Path(decode_mountinfo_path(mount_fields[4]))
                canonical = canonical_absolute(mount_point)
                mounts[canonical] = mount_id
                if mount_point != canonical:
                    mounts[mount_point] = mount_id
    except (OSError, UnicodeError) as error:
        raise SnapshotError(
            f"unable to inspect mounted filesystem boundaries: {error}"
        ) from error
    if not mounts:
        raise SnapshotError("unable to determine mounted filesystem boundaries")
    return mounts


def mount_id_for_path(path: Path, mounts: dict[Path, int]) -> int | None:
    lexical = Path(os.path.abspath(str(path)))
    candidates = [lexical]
    try:
        canonical = canonical_absolute(lexical)
    except (OSError, RuntimeError):
        canonical = lexical
    if canonical != lexical:
        candidates.insert(0, canonical)
    for candidate in candidates:
        current = candidate
        while True:
            if current in mounts:
                return mounts[current]
            if current.parent == current:
                break
            current = current.parent
    return None


def reject_mount_boundary(
    parent_path: Path,
    entry_path: Path,
    mounts: dict[Path, int],
) -> None:
    parent_mount = mount_id_for_path(parent_path, mounts)
    entry_mount = mount_id_for_path(entry_path, mounts)
    if parent_mount is None or entry_mount is None:
        raise SnapshotError(
            "unable to determine the mounted filesystem for "
            f"{terminal_safe_text(str(entry_path))}"
        )
    if parent_mount != entry_mount:
        raise SnapshotError(
            "the managed tree crosses a mounted filesystem boundary: "
            f"{terminal_safe_text(str(entry_path))}"
        )


def reject_mounted_tree(path: Path, mounts: dict[Path, int]) -> None:
    """Reject a path that is, or contains, a mounted filesystem boundary."""

    canonical = canonical_absolute(path)
    path_mount = mount_id_for_path(canonical, mounts)
    parent_mount = mount_id_for_path(canonical.parent, mounts)
    if path_mount is None or parent_mount is None:
        raise SnapshotError(
            "unable to determine the mounted filesystem for "
            f"{terminal_safe_text(str(canonical))}"
        )
    if path_mount != parent_mount:
        raise SnapshotError(
            "the managed path is a mounted filesystem boundary: "
            f"{terminal_safe_text(str(canonical))}"
        )
    for mount_point, mount_id in mounts.items():
        if mount_point == canonical:
            continue
        if not path_is_at_or_below(mount_point, canonical):
            continue
        if mount_id != path_mount:
            raise SnapshotError(
                "the managed tree crosses a mounted filesystem boundary: "
                f"{terminal_safe_text(str(mount_point))}"
            )


def reject_mounted_move(
    source_path: Path,
    destination_parent: Path,
    mounts: dict[Path, int],
) -> None:
    reject_mounted_tree(source_path, mounts)
    reject_mount_boundary(destination_parent, source_path, mounts)


def descriptor_path(descriptor: int) -> Path:
    try:
        value = os.readlink(f"/proc/self/fd/{descriptor}")
    except OSError as error:
        raise SnapshotError(
            f"unable to resolve an open directory path: {error}"
        ) from error
    deleted_suffix = " (deleted)"
    if value.endswith(deleted_suffix):
        value = value[: -len(deleted_suffix)]
    path = Path(value)
    if not path.is_absolute():
        raise SnapshotError("an open directory does not have an absolute path")
    return path


def entry_path_at(parent_descriptor: int, name: str) -> Path:
    return descriptor_path(parent_descriptor) / name


def remove_entry_at(parent_descriptor: int, name: str) -> None:
    validate_entry_name(name)
    mounts = read_mount_ids()
    _remove_entry_at(parent_descriptor, name, mounts)


def _remove_entry_at(
    parent_descriptor: int,
    name: str,
    mounts: dict[Path, int],
) -> None:
    try:
        metadata = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return
    except OSError as error:
        raise SnapshotError(f"unable to inspect '{name}' for removal: {error}") from error

    parent_path = descriptor_path(parent_descriptor)
    entry_path = parent_path / name
    reject_mount_boundary(parent_path, entry_path, mounts)
    if stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode):
        # Scan the complete subtree before deleting anything. A mounted
        # descendant must fail closed without partially deleting its siblings.
        reject_mounted_tree(entry_path, mounts)

    if stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode):
        directory_descriptor = -1
        try:
            directory_descriptor = os.open(
                name,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=parent_descriptor,
            )
            for child_name in os.listdir(directory_descriptor):
                _remove_entry_at(directory_descriptor, child_name, mounts)
            os.close(directory_descriptor)
            directory_descriptor = -1
            os.rmdir(name, dir_fd=parent_descriptor)
            os.fsync(parent_descriptor)
        except OSError as error:
            raise SnapshotError(f"unable to remove '{name}': {error}") from error
        finally:
            if directory_descriptor >= 0:
                os.close(directory_descriptor)
        return

    try:
        os.unlink(name, dir_fd=parent_descriptor)
        os.fsync(parent_descriptor)
    except OSError as error:
        raise SnapshotError(f"unable to remove '{name}': {error}") from error


def create_temporary_directory(
    parent_descriptor: int,
    prefix: str,
) -> tuple[str, int]:
    for _attempt in range(100):
        name = f"{prefix}{uuid.uuid4().hex}"
        try:
            os.mkdir(name, 0o700, dir_fd=parent_descriptor)
        except FileExistsError:
            continue
        except OSError as error:
            raise SnapshotError(f"unable to create a temporary directory: {error}") from error

        descriptor = -1
        try:
            descriptor = os.open(
                name,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=parent_descriptor,
            )
            os.fchmod(descriptor, 0o700)
            return name, descriptor
        except BaseException:
            if descriptor >= 0:
                os.close(descriptor)
            try:
                os.rmdir(name, dir_fd=parent_descriptor)
            except OSError:
                pass
            raise
    raise SnapshotError("unable to allocate a unique temporary directory")


def write_bytes_at(
    directory_descriptor: int,
    name: str,
    data: bytes,
    *,
    mode: int = 0o600,
) -> None:
    temporary_name = f".{name}.tmp-{uuid.uuid4().hex}"
    descriptor = -1
    try:
        descriptor = os.open(
            temporary_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
            mode,
            dir_fd=directory_descriptor,
        )
        os.fchmod(descriptor, mode)
        offset = 0
        while offset < len(data):
            written = os.write(descriptor, data[offset:])
            if written <= 0:
                raise SnapshotError(f"unable to write snapshot file: {name}")
            offset += written
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        os.replace(
            temporary_name,
            name,
            src_dir_fd=directory_descriptor,
            dst_dir_fd=directory_descriptor,
        )
        os.fsync(directory_descriptor)
    except OSError as error:
        raise SnapshotError(f"unable to write snapshot file {name}: {error}") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            os.unlink(temporary_name, dir_fd=directory_descriptor)
        except OSError:
            pass


def replace_entries_at(
    source_parent_descriptor: int,
    source_name: str,
    destination_parent_descriptor: int,
    destination_name: str,
    context: str,
) -> None:
    """Rename entries and durably persist both affected parent directories."""

    validate_entry_name(source_name, "source directory entry")
    validate_entry_name(destination_name, "destination directory entry")
    try:
        os.replace(
            source_name,
            destination_name,
            src_dir_fd=source_parent_descriptor,
            dst_dir_fd=destination_parent_descriptor,
        )
    except OSError as error:
        raise SnapshotError(f"unable to {context}: {error}") from error
    descriptors = [source_parent_descriptor]
    if destination_parent_descriptor != source_parent_descriptor:
        descriptors.append(destination_parent_descriptor)
    for descriptor in descriptors:
        try:
            os.fsync(descriptor)
        except OSError as error:
            raise SnapshotError(f"unable to persist {context}: {error}") from error


def recovery_journal_name(transaction_id: str) -> str:
    return f"{RECOVERY_JOURNAL_PREFIX}{transaction_id}{RECOVERY_JOURNAL_SUFFIX}"


def recovery_journal_path(home: Path, transaction_id: str) -> Path:
    return home / recovery_journal_name(transaction_id)


def recovery_journal_paths(home: Path) -> list[Path]:
    try:
        return sorted(home.glob(f"{RECOVERY_JOURNAL_PREFIX}*{RECOVERY_JOURNAL_SUFFIX}"))
    except OSError as error:
        raise SnapshotError(f"unable to list snapshot recovery journals: {error}") from error


def read_recovery_journal(path: Path) -> dict[str, Any]:
    parent = path.parent
    name = path.name
    try:
        parent_descriptor = os.open(
            parent,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
        )
    except OSError as error:
        raise SnapshotError(f"unable to open snapshot recovery journal: {error}") from error
    try:
        data, _identity = read_regular_bytes_at(
            parent_descriptor,
            name,
            "snapshot recovery journal",
            maximum_bytes=MAXIMUM_RECOVERY_JOURNAL_BYTES,
        )
    finally:
        os.close(parent_descriptor)
    journal = parse_json_bytes(data, "snapshot recovery journal")
    if journal.get("schema_version") != RECOVERY_JOURNAL_SCHEMA_VERSION:
        raise SnapshotError("unsupported snapshot recovery journal schema")
    transaction_id = journal.get("transaction_id")
    if not isinstance(transaction_id, str) or not re.fullmatch(
        r"[0-9a-f]{32}", transaction_id
    ):
        raise SnapshotError("snapshot recovery journal has an invalid transaction ID")
    if path.name != recovery_journal_name(transaction_id):
        raise SnapshotError("snapshot recovery journal name does not match its transaction")
    kind = journal.get("kind")
    if kind not in {"whole", "selective"}:
        raise SnapshotError("snapshot recovery journal has an invalid transaction kind")
    status = journal.get("status")
    allowed_statuses = (
        WHOLE_RECOVERY_STATUSES
        if kind == "whole"
        else SELECTIVE_RECOVERY_STATUSES
    )
    if status not in allowed_statuses:
        raise SnapshotError("snapshot recovery journal has an invalid status")
    validate_recovery_journal_fields(journal)
    return journal


def write_recovery_journal(home: Path, journal: dict[str, Any]) -> Path:
    transaction_id = journal.get("transaction_id")
    if not isinstance(transaction_id, str) or not re.fullmatch(
        r"[0-9a-f]{32}", transaction_id
    ):
        raise SnapshotError("cannot write a snapshot recovery journal without a valid ID")
    path = recovery_journal_path(home, transaction_id)
    data = json.dumps(journal, indent=2, sort_keys=True).encode("utf-8") + b"\n"
    home_descriptor = open_home_directory(home)
    try:
        write_bytes_at(home_descriptor, path.name, data)
    finally:
        os.close(home_descriptor)
    return path


def update_recovery_journal(
    home: Path,
    journal: dict[str, Any],
    *,
    status: str | None = None,
    phase: str | None = None,
    **fields: Any,
) -> Path:
    if status is not None:
        journal["status"] = status
    if phase is not None:
        journal["phase"] = phase
    journal.update(fields)
    journal["updated_at"] = dt.datetime.now(dt.timezone.utc).replace(
        microsecond=0
    ).isoformat().replace("+00:00", "Z")
    return write_recovery_journal(home, journal)


def file_identity(descriptor: int) -> tuple[int, ...]:
    metadata = os.fstat(descriptor)
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def open_regular_file_at(
    directory_descriptor: int,
    name: str,
    context: str,
) -> tuple[int, tuple[int, ...]]:
    descriptor = -1
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=directory_descriptor,
        )
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise SnapshotError(f"{context} is not a regular file")
        if metadata.st_uid != os.geteuid():
            raise SnapshotError(f"{context} is not owned by the current user")
        return descriptor, file_identity(descriptor)
    except SnapshotError:
        if descriptor >= 0:
            os.close(descriptor)
        raise
    except OSError as error:
        if descriptor >= 0:
            os.close(descriptor)
        if error.errno in (errno.ELOOP, errno.ENOTDIR):
            raise SnapshotError(f"{context} must not be a symbolic link") from error
        raise SnapshotError(f"unable to open {context}: {error}") from error


def read_regular_bytes_at(
    directory_descriptor: int,
    name: str,
    context: str,
    *,
    maximum_bytes: int | None = None,
) -> tuple[bytes, tuple[int, ...]]:
    descriptor, identity = open_regular_file_at(directory_descriptor, name, context)
    try:
        if maximum_bytes is not None and os.fstat(descriptor).st_size > maximum_bytes:
            raise SnapshotError(f"{context} is too large to validate safely")
        chunks: list[bytes] = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks), identity
    except OSError as error:
        raise SnapshotError(f"unable to read {context}: {error}") from error
    finally:
        os.close(descriptor)


def verify_path_identity_at(
    directory_descriptor: int,
    name: str,
    expected_identity: tuple[int, ...],
    context: str,
) -> None:
    descriptor, current_identity = open_regular_file_at(
        directory_descriptor,
        name,
        context,
    )
    os.close(descriptor)
    if current_identity != expected_identity:
        raise SnapshotError(f"{context} identity changed during the operation")


def sha256_fd(descriptor: int) -> str:
    digest = hashlib.sha256()
    offset = 0
    try:
        while True:
            chunk = os.pread(descriptor, 1024 * 1024, offset)
            if not chunk:
                break
            digest.update(chunk)
            offset += len(chunk)
    except OSError as error:
        raise SnapshotError(f"unable to hash snapshot file: {error}") from error
    return digest.hexdigest()


def reject_duplicate_json_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise SnapshotError(f"duplicate JSON key in snapshot metadata: {key}")
        value[key] = item
    return value


def parse_json_bytes(data: bytes, context: str) -> dict[str, Any]:
    try:
        value = json.loads(
            data.decode("utf-8"),
            object_pairs_hook=reject_duplicate_json_keys,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError) as error:
        raise SnapshotError(f"unable to read {context}: {error}") from error
    if not isinstance(value, dict):
        raise SnapshotError(f"invalid snapshot metadata object: {context}")
    return value


def is_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def validate_relative_path(value: str, *, status: int = 1) -> str:
    if not isinstance(value, str) or not value:
        raise SnapshotError("snapshot paths must not be empty", status)
    if "\x00" in value or "\\" in value:
        raise SnapshotError(f"unsafe snapshot path: {terminal_safe_text(value)}", status)
    if CONTROL_CHARACTER_PATTERN.search(value):
        raise SnapshotError(f"unsafe snapshot path: {terminal_safe_text(value)}", status)
    if value.startswith("/"):
        raise SnapshotError(f"unsafe snapshot path: {terminal_safe_text(value)}", status)
    if any(component in ("", ".", "..") for component in value.split("/")):
        raise SnapshotError(f"unsafe snapshot path: {terminal_safe_text(value)}", status)
    return value


def safe_symlink_target(relative: str, target: str, *, status: int = 1) -> str:
    if (
        not isinstance(target, str)
        or not target
        or "\x00" in target
        or target.startswith("/")
        or "\\" in target
        or CONTROL_CHARACTER_PATTERN.search(target)
    ):
        raise SnapshotError(
            f"unsafe symbolic link target for {terminal_safe_text(relative)}: "
            f"{terminal_safe_text(str(target))}",
            status,
        )
    normalized = posixpath.normpath(posixpath.join(posixpath.dirname(relative), target))
    if normalized == ".." or normalized.startswith("../"):
        raise SnapshotError(
            f"symbolic link escapes the managed root: {terminal_safe_text(relative)}",
            status,
        )
    return target


def validate_manifest_entries(entries: Any, *, status: int = 1) -> dict[str, Any]:
    if not isinstance(entries, dict):
        raise SnapshotError("snapshot manifest entries are invalid", status)

    for relative, entry in entries.items():
        if not isinstance(relative, str):
            raise SnapshotError("snapshot manifest contains an invalid path", status)
        validate_relative_path(relative, status=status)
        if not isinstance(entry, dict):
            raise SnapshotError(f"snapshot manifest entry is invalid: {relative}", status)
        entry_type = entry.get("type")
        if entry_type not in {"directory", "file", "symlink"}:
            raise SnapshotError(f"snapshot manifest entry is invalid: {relative}", status)
        mode = entry.get("mode")
        if not is_integer(mode) or mode < 0 or mode > 0o7777:
            raise SnapshotError(f"snapshot manifest entry has an invalid mode: {relative}", status)
        if entry_type == "file":
            size = entry.get("size")
            if not is_integer(size) or size < 0:
                raise SnapshotError(f"snapshot manifest file size is invalid: {relative}", status)
            checksum = entry.get("sha256")
            if not isinstance(checksum, str) or not re.fullmatch(r"[0-9a-f]{64}", checksum):
                raise SnapshotError(f"snapshot manifest file checksum is invalid: {relative}", status)
        elif entry_type == "symlink":
            target = entry.get("target")
            if not isinstance(target, str):
                raise SnapshotError(f"snapshot manifest link target is invalid: {relative}", status)
            safe_symlink_target(relative, target, status=status)

    for relative in sorted(entries, key=lambda item: (item.count("/"), item)):
        parts = relative.split("/")
        for index in range(1, len(parts)):
            ancestor = "/".join(parts[:index])
            ancestor_entry = entries.get(ancestor)
            if not isinstance(ancestor_entry, dict) or ancestor_entry.get("type") != "directory":
                raise SnapshotError(
                    f"snapshot manifest contains an invalid path hierarchy: {relative}",
                    status,
                )
    return entries


def validate_snapshot_metadata(
    metadata: dict[str, Any],
    directory_name: str,
    manifest: dict[str, Any],
    home: Path,
) -> None:
    if metadata.get("schema_version") != SCHEMA_VERSION:
        raise SnapshotError(f"unsupported snapshot metadata schema: {directory_name}")

    snapshot_id = metadata.get("id")
    if not isinstance(snapshot_id, str) or not ID_PATTERN.fullmatch(snapshot_id):
        raise SnapshotError(f"snapshot identifier is invalid: {directory_name}")
    if snapshot_id != directory_name:
        raise SnapshotError(f"snapshot identifier does not match its directory: {directory_name}")

    label = metadata.get("label", "")
    if not isinstance(label, str) or (label and not LABEL_PATTERN.fullmatch(label)):
        raise SnapshotError(f"snapshot label is invalid: {directory_name}")

    created_at = metadata.get("created_at")
    if not isinstance(created_at, str):
        raise SnapshotError(f"snapshot creation time is invalid: {directory_name}")
    try:
        dt.datetime.strptime(created_at, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as error:
        raise SnapshotError(f"snapshot creation time is invalid: {directory_name}") from error

    root = metadata.get("root")
    if not isinstance(root, str) or not root:
        raise SnapshotError(f"snapshot managed root is invalid: {directory_name}")
    validate_home_path(Path(root), home, context="snapshot managed root")

    if metadata.get("archive") != "snapshot.tar.gz":
        raise SnapshotError(f"snapshot archive name is invalid: {directory_name}")
    if metadata.get("manifest") != "manifest.json":
        raise SnapshotError(f"snapshot manifest name is invalid: {directory_name}")

    for checksum_name in ("archive_sha256", "manifest_sha256"):
        checksum = metadata.get(checksum_name)
        if not isinstance(checksum, str) or not re.fullmatch(r"[0-9a-f]{64}", checksum):
            raise SnapshotError(f"snapshot {checksum_name} is invalid: {directory_name}")

    file_count = metadata.get("file_count")
    total_bytes = metadata.get("total_bytes")
    if not is_integer(file_count) or file_count < 0:
        raise SnapshotError(f"snapshot file count is invalid: {directory_name}")
    if not is_integer(total_bytes) or total_bytes < 0:
        raise SnapshotError(f"snapshot byte count is invalid: {directory_name}")

    warnings = metadata.get("warnings", [])
    if not isinstance(warnings, list) or not all(
        isinstance(warning, str) and not CONTROL_CHARACTER_PATTERN.search(warning)
        for warning in warnings
    ):
        raise SnapshotError(f"snapshot warnings are invalid: {directory_name}")

    entries = validate_manifest_entries(manifest.get("entries"))
    actual_file_count = sum(
        1 for entry in entries.values() if entry.get("type") == "file"
    )
    actual_total_bytes = sum(
        int(entry.get("size", 0))
        for entry in entries.values()
        if entry.get("type") == "file"
    )
    if file_count != actual_file_count:
        raise SnapshotError(f"snapshot file count does not match its manifest: {directory_name}")
    if total_bytes != actual_total_bytes:
        raise SnapshotError(f"snapshot byte count does not match its manifest: {directory_name}")


def archive_manifest_from_fd(descriptor: int) -> dict[str, Any]:
    entries: dict[str, Any] = {}
    try:
        os.lseek(descriptor, 0, os.SEEK_SET)
        stream = os.fdopen(os.dup(descriptor), "rb")
        try:
            with tarfile.open(fileobj=stream, mode="r:gz") as bundle:
                for member in bundle.getmembers():
                    relative = validate_relative_path(member.name)
                    if relative in entries:
                        raise SnapshotError(f"duplicate path in snapshot archive: {relative}")
                    if member.isdir():
                        entries[relative] = {
                            "type": "directory",
                            "mode": stat.S_IMODE(member.mode),
                        }
                    elif member.isreg():
                        extracted = bundle.extractfile(member)
                        if extracted is None:
                            raise SnapshotError(f"unable to read archived file: {relative}")
                        digest = hashlib.sha256()
                        size = 0
                        for chunk in iter(lambda: extracted.read(1024 * 1024), b""):
                            digest.update(chunk)
                            size += len(chunk)
                        entries[relative] = {
                            "type": "file",
                            "mode": stat.S_IMODE(member.mode),
                            "size": size,
                            "sha256": digest.hexdigest(),
                        }
                    elif member.issym():
                        target = safe_symlink_target(relative, member.linkname)
                        entries[relative] = {
                            "type": "symlink",
                            "mode": stat.S_IMODE(member.mode),
                            "target": target,
                        }
                    else:
                        raise SnapshotError(f"unsupported archive member type: {relative}")
        finally:
            stream.close()
    except SnapshotError:
        raise
    except (OSError, tarfile.TarError) as error:
        raise SnapshotError(f"unable to validate the snapshot archive: {error}") from error
    validate_manifest_entries(entries)
    return {"schema_version": SCHEMA_VERSION, "entries": entries}


def verify_archive_fd(
    descriptor: int,
    expected_identity: tuple[int, ...],
    metadata: dict[str, Any],
    manifest: dict[str, Any],
) -> None:
    if file_identity(descriptor) != expected_identity:
        raise SnapshotError("snapshot archive identity changed during the operation")
    if sha256_fd(descriptor) != metadata.get("archive_sha256"):
        raise SnapshotError("snapshot archive checksum does not match")
    actual = archive_manifest_from_fd(descriptor)
    if actual.get("entries") != manifest.get("entries"):
        raise SnapshotError("snapshot contents do not match its manifest")


def archive_directory(
    source_descriptor: int,
    bundle: tarfile.TarFile,
    relative_prefix: str,
    excluded_prefix: str | None,
    mounts: dict[Path, int],
) -> None:
    try:
        names = sorted(os.listdir(source_descriptor))
    except OSError as error:
        raise SnapshotError(f"unable to read the managed directory: {error}") from error

    for name in names:
        relative = f"{relative_prefix}/{name}" if relative_prefix else name
        if excluded_prefix and (
            relative == excluded_prefix or relative.startswith(excluded_prefix + "/")
        ):
            continue
        entry_path = descriptor_path(source_descriptor) / name
        reject_mounted_tree(entry_path, mounts)
        try:
            metadata = os.stat(name, dir_fd=source_descriptor, follow_symlinks=False)
        except OSError as error:
            raise SnapshotError(
                f"unable to inspect {terminal_safe_text(relative)} while creating the snapshot: {error}"
            ) from error

        if stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode):
            info = tarfile.TarInfo(relative)
            info.type = tarfile.DIRTYPE
            info.mode = stat.S_IMODE(metadata.st_mode)
            info.mtime = int(metadata.st_mtime)
            bundle.addfile(info)
            child_descriptor = -1
            try:
                child_descriptor = os.open(
                    name,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                    dir_fd=source_descriptor,
                )
                archive_directory(
                    child_descriptor,
                    bundle,
                    relative,
                    excluded_prefix,
                    mounts,
                )
            finally:
                if child_descriptor >= 0:
                    os.close(child_descriptor)
        elif stat.S_ISREG(metadata.st_mode):
            source_file = -1
            try:
                source_file = os.open(
                    name,
                    os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
                    dir_fd=source_descriptor,
                )
                source_metadata = os.fstat(source_file)
                if not stat.S_ISREG(source_metadata.st_mode):
                    raise SnapshotError(
                        f"unsupported file type in managed directory: {terminal_safe_text(relative)}"
                    )
                info = tarfile.TarInfo(relative)
                info.type = tarfile.REGTYPE
                info.mode = stat.S_IMODE(source_metadata.st_mode)
                info.size = source_metadata.st_size
                info.mtime = int(source_metadata.st_mtime)
                source_stream = os.fdopen(source_file, "rb", closefd=False)
                try:
                    bundle.addfile(info, source_stream)
                finally:
                    source_stream.close()
            finally:
                if source_file >= 0:
                    os.close(source_file)
        elif stat.S_ISLNK(metadata.st_mode):
            try:
                target = os.readlink(name, dir_fd=source_descriptor)
            except OSError as error:
                raise SnapshotError(
                    f"unable to read symbolic link {terminal_safe_text(relative)}: {error}"
                ) from error
            safe_symlink_target(relative, target)
            info = tarfile.TarInfo(relative)
            info.type = tarfile.SYMTYPE
            info.linkname = target
            info.mode = stat.S_IMODE(metadata.st_mode)
            info.mtime = int(metadata.st_mtime)
            bundle.addfile(info)
        else:
            raise SnapshotError(
                f"unsupported file type in managed directory: {terminal_safe_text(relative)}"
            )


def create_archive(
    root_descriptor: int,
    archive_descriptor: int,
    excluded_prefix: str | None,
    mounts: dict[Path, int],
) -> None:
    try:
        stream = os.fdopen(os.dup(archive_descriptor), "w+b")
        try:
            with tarfile.open(fileobj=stream, mode="w:gz", format=tarfile.PAX_FORMAT) as bundle:
                archive_directory(
                    root_descriptor,
                    bundle,
                    "",
                    excluded_prefix,
                    mounts,
                )
            stream.flush()
            os.fsync(stream.fileno())
        finally:
            stream.close()
    except SnapshotError:
        raise
    except (OSError, tarfile.TarError) as error:
        raise SnapshotError(f"unable to create the snapshot archive: {error}") from error


def trigger_test_failpoint(name: str, *, target: str | None = None) -> None:
    if os.environ.get("POSTINSTALL_SNAPSHOT_TEST_MODE") != "1":
        return
    configured_failpoints = {
        value.strip()
        for value in os.environ.get(
            "POSTINSTALL_SNAPSHOT_TEST_FAILPOINT",
            "",
        ).split(",")
        if value.strip()
    }
    if name not in configured_failpoints:
        return
    expected_target = os.environ.get("POSTINSTALL_SNAPSHOT_TEST_FAILPOINT_TARGET", "")
    if expected_target and expected_target != (target or ""):
        return
    if name in _FIRED_TEST_FAILPOINTS:
        return
    _FIRED_TEST_FAILPOINTS.add(name)

    kind = os.environ.get("POSTINSTALL_SNAPSHOT_TEST_FAILPOINT_KIND", "exception")
    if kind == "keyboard_interrupt":
        raise KeyboardInterrupt()
    if kind == "signal":
        raise SnapshotInterrupted(signal.SIGTERM)
    if kind == "exit":
        os._exit(75)
    if kind == "pause":
        ready = os.environ.get("POSTINSTALL_SNAPSHOT_TEST_FAILPOINT_READY", "")
        release = os.environ.get("POSTINSTALL_SNAPSHOT_TEST_FAILPOINT_RELEASE", "")
        if not ready or not release:
            raise SnapshotError("snapshot test pause failpoint is missing its coordination files")
        Path(ready).write_text("ready\n", encoding="utf-8")
        import time

        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            if Path(release).exists():
                return
            time.sleep(0.01)
        raise SnapshotError("snapshot test pause failpoint timed out")
    raise SnapshotError(f"injected snapshot test failure at {name}")


def create_snapshot(label: str | None) -> int:
    home = home_directory()
    root = managed_root(home, require_discovery=True)
    recovery_messages = recover_pending_transactions(home, root)
    validate_runtime_control_paths(root, home)
    layout = storage_layout(home)
    root_components = home_relative_components(root, home)
    storage_components = layout.components
    storage_relative = storage_relative_to_root(root_components, storage_components)

    mounts = read_mount_ids()
    reject_mounted_tree(root, mounts)
    root_descriptor = open_directory_under_home(home, root, create=False)
    if root_descriptor is None:
        raise SnapshotError(f"managed root does not exist: {root}")
    storage_descriptor = open_storage_directory(layout, home, create=True)
    if storage_descriptor is None:
        os.close(root_descriptor)
        raise SnapshotError(f"unable to prepare snapshot storage: {layout.path}")

    normalized_label = ""
    if label is not None:
        normalized_label = label.strip()
        if not LABEL_PATTERN.fullmatch(normalized_label):
            os.close(root_descriptor)
            os.close(storage_descriptor)
            raise SnapshotUsageError(
                "snapshot labels must start with an alphanumeric character and contain only letters, digits, dots, underscores, hyphens, or spaces"
            )

    created = dt.datetime.now(dt.timezone.utc)
    snapshot_id = f"{created.strftime('%Y%m%dT%H%M%SZ')}-{uuid.uuid4().hex[:8]}"
    temporary_name = ""
    temporary_descriptor = -1
    archive_descriptor = -1
    published = False

    try:
        temporary_name, temporary_descriptor = create_temporary_directory(
            storage_descriptor,
            ".creating-",
        )
        archive_descriptor = os.open(
            "snapshot.tar.gz",
            os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
            0o600,
            dir_fd=temporary_descriptor,
        )
        os.fchmod(archive_descriptor, 0o600)

        excluded_prefix = "/".join(storage_relative) if storage_relative else None
        create_archive(
            root_descriptor,
            archive_descriptor,
            excluded_prefix,
            mounts,
        )
        manifest = archive_manifest_from_fd(archive_descriptor)
        reject_archived_storage_paths(manifest["entries"], storage_relative)
        archive_hash = sha256_fd(archive_descriptor)
        total_bytes = sum(
            int(entry.get("size", 0))
            for entry in manifest["entries"].values()
            if entry.get("type") == "file"
        )
        metadata = {
            "schema_version": SCHEMA_VERSION,
            "id": snapshot_id,
            "label": normalized_label,
            "created_at": created.replace(microsecond=0).isoformat().replace("+00:00", "Z"),
            "root": str(root),
            "file_count": sum(
                1
                for entry in manifest["entries"].values()
                if entry.get("type") == "file"
            ),
            "total_bytes": total_bytes,
            "archive": "snapshot.tar.gz",
            "archive_sha256": archive_hash,
            "manifest": "manifest.json",
            "manifest_sha256": "",
            "warnings": [],
        }
        manifest_data = json.dumps(manifest, indent=2, sort_keys=True).encode("utf-8") + b"\n"
        metadata["manifest_sha256"] = hashlib.sha256(manifest_data).hexdigest()
        write_bytes_at(temporary_descriptor, "manifest.json", manifest_data)
        write_bytes_at(
            temporary_descriptor,
            "metadata.json",
            json.dumps(metadata, indent=2, sort_keys=True).encode("utf-8") + b"\n",
        )
        os.fsync(temporary_descriptor)

        replace_entries_at(
            storage_descriptor,
            temporary_name,
            storage_descriptor,
            snapshot_id,
            "publish snapshot",
        )
        published = True
        temporary_name = ""

        for message in recovery_messages:
            print(f"warning: {message}", file=sys.stderr)
        print(f"Created snapshot {snapshot_id} ({root}).")
        sys.stdout.flush()
        return 0
    except BaseException as error:
        cleanup_failures: list[str] = []
        if published:
            # Publication is the commit point. A later stdout or fsync
            # failure must not delete the already published snapshot.
            pass
        elif temporary_name:
            try:
                remove_entry_at(storage_descriptor, temporary_name)
                temporary_name = ""
            except BaseException as cleanup_error:
                cleanup_failures.append(
                    f"temporary snapshot data could not be removed safely: {cleanup_error}"
                )
        if cleanup_failures:
            raise SnapshotError(
                "snapshot creation failed and cleanup was incomplete: "
                + "; ".join(cleanup_failures)
            ) from error
        raise
    finally:
        if archive_descriptor >= 0:
            os.close(archive_descriptor)
        if temporary_descriptor >= 0:
            os.close(temporary_descriptor)
        if temporary_name:
            try:
                remove_entry_at(storage_descriptor, temporary_name)
            except SnapshotError:
                pass
        os.close(root_descriptor)
        os.close(storage_descriptor)


def reject_archived_storage_paths(
    entries: dict[str, Any],
    storage_relative: tuple[str, ...] | None,
) -> None:
    if not storage_relative:
        return
    relative_storage = "/".join(storage_relative)
    for relative in entries:
        if relative == relative_storage or relative.startswith(relative_storage + "/"):
            raise SnapshotError(
                "snapshot contents overlap the snapshot storage directory"
            )


def enumerate_snapshot_directories(storage_descriptor: int) -> Iterator[tuple[str, int]]:
    """Yield snapshot directories without retaining an open descriptor per item."""

    try:
        names = sorted(os.listdir(storage_descriptor))
    except OSError as error:
        raise SnapshotError(f"unable to list snapshots: {error}") from error
    if len(names) > MAXIMUM_SNAPSHOT_COUNT:
        raise SnapshotError(
            f"snapshot storage contains more than {MAXIMUM_SNAPSHOT_COUNT} entries"
        )

    for name in names:
        if name.startswith("."):
            continue
        try:
            metadata = os.stat(
                name,
                dir_fd=storage_descriptor,
                follow_symlinks=False,
            )
            if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
                continue
            descriptor = os.open(
                name,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=storage_descriptor,
            )
        except OSError:
            continue
        yield name, descriptor


def load_snapshot_directory(name: str, directory_descriptor: int) -> LoadedSnapshot:
    archive_descriptor = -1
    try:
        metadata_data, metadata_identity = read_regular_bytes_at(
            directory_descriptor,
            "metadata.json",
            "snapshot metadata",
            maximum_bytes=MAXIMUM_METADATA_BYTES,
        )
        manifest_data, manifest_identity = read_regular_bytes_at(
            directory_descriptor,
            "manifest.json",
            "snapshot manifest",
            maximum_bytes=MAXIMUM_MANIFEST_BYTES,
        )
        metadata = parse_json_bytes(metadata_data, "snapshot metadata")
        manifest = parse_json_bytes(manifest_data, "snapshot manifest")
        if manifest.get("schema_version") != SCHEMA_VERSION:
            raise SnapshotError(f"unsupported snapshot manifest schema: {name}")
        home = home_directory()
        validate_snapshot_metadata(metadata, name, manifest, home)

        archive_descriptor, archive_identity = open_regular_file_at(
            directory_descriptor,
            "snapshot.tar.gz",
            "snapshot archive",
        )
        if sha256_fd(archive_descriptor) != metadata.get("archive_sha256"):
            raise SnapshotError(f"snapshot archive checksum does not match: {name}")
        if hashlib.sha256(manifest_data).hexdigest() != metadata.get("manifest_sha256"):
            raise SnapshotError(f"snapshot manifest checksum does not match: {name}")
        actual = archive_manifest_from_fd(archive_descriptor)
        if actual.get("entries") != manifest.get("entries"):
            raise SnapshotError(f"snapshot contents do not match its manifest: {name}")
        verify_path_identity_at(
            directory_descriptor,
            "metadata.json",
            metadata_identity,
            "snapshot metadata",
        )
        verify_path_identity_at(
            directory_descriptor,
            "manifest.json",
            manifest_identity,
            "snapshot manifest",
        )
        verify_path_identity_at(
            directory_descriptor,
            "snapshot.tar.gz",
            archive_identity,
            "snapshot archive",
        )

        return LoadedSnapshot(
            name=name,
            directory_fd=directory_descriptor,
            archive_fd=archive_descriptor,
            archive_identity=archive_identity,
            metadata_identity=metadata_identity,
            manifest_identity=manifest_identity,
            metadata=metadata,
            manifest=manifest,
        )
    except BaseException:
        if archive_descriptor >= 0:
            os.close(archive_descriptor)
        raise


def close_loaded_snapshot(snapshot: LoadedSnapshot) -> None:
    snapshot.close()


def load_snapshot(snapshot_id: str, storage_descriptor: int) -> LoadedSnapshot:
    if not QUERY_PATTERN.fullmatch(snapshot_id):
        raise SnapshotUsageError(
            f"invalid snapshot identifier or label: {terminal_safe_text(snapshot_id)}"
        )

    labels: list[LoadedSnapshot] = []
    ambiguous_label = False

    try:
        for name, directory_descriptor in enumerate_snapshot_directories(storage_descriptor):
            try:
                loaded = load_snapshot_directory(name, directory_descriptor)
            except SnapshotError as error:
                os.close(directory_descriptor)
                if name == snapshot_id:
                    raise error
                continue

            if name == snapshot_id:
                for label_match in labels:
                    label_match.close()
                return loaded
            if loaded.metadata.get("label") == snapshot_id:
                if len(labels) == 1:
                    ambiguous_label = True
                    for label_match in labels:
                        label_match.close()
                    labels.clear()
                    loaded.close()
                elif not ambiguous_label:
                    labels.append(loaded)
                    continue
                else:
                    loaded.close()
                    continue
            else:
                loaded.close()

        if ambiguous_label:
            raise SnapshotError(
                f"snapshot label is ambiguous: {terminal_safe_text(snapshot_id)}"
            )
        if len(labels) == 1:
            return labels.pop()
        raise SnapshotError(f"snapshot was not found: {terminal_safe_text(snapshot_id)}")
    finally:
        for loaded in labels:
            if loaded.directory_fd >= 0:
                loaded.close()


def snapshot_context_error(
    snapshot: LoadedSnapshot,
    home: Path,
    root: Path,
    storage_relative: tuple[str, ...] | None,
) -> None:
    metadata_root = validate_home_path(
        Path(snapshot.metadata["root"]),
        home,
        context="snapshot managed root",
    )
    if metadata_root != root:
        raise SnapshotError(
            "snapshot managed root does not match the currently configured managed root"
        )
    reject_archived_storage_paths(
        snapshot.manifest.get("entries", {}),
        storage_relative,
    )


@contextmanager
def optional_snapshot_list_lock() -> Iterator[None]:
    if os.environ.get("POSTINSTALL_SNAPSHOT_LIST_LOCK") != "1":
        yield
        return
    configured = os.environ.get("POSTINSTALL_LOCK_FILE", "").strip()
    if not configured:
        raise SnapshotError("the snapshot list lock path is unavailable", 75)
    path = lexical_absolute(Path(configured))
    parent = path.parent
    descriptor = os.open(
        parent.anchor,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
    )
    lock_descriptor = -1
    try:
        inspect_trusted_state_directory(
            descriptor,
            str(parent.anchor),
            allow_sticky=True,
        )
        for component in parent.parts[1:]:
            if component in {"", ".", ".."}:
                raise SnapshotError("invalid snapshot list lock path")
            try:
                child = os.open(
                    component,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                    dir_fd=descriptor,
                )
            except FileNotFoundError:
                try:
                    os.mkdir(component, 0o700, dir_fd=descriptor)
                except FileExistsError:
                    pass
                child = os.open(
                    component,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                    dir_fd=descriptor,
                )
            inspect_trusted_state_directory(
                child,
                str(parent),
                allow_sticky=True,
            )
            os.close(descriptor)
            descriptor = child
        lock_descriptor = os.open(
            path.name,
            os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC,
            0o600,
            dir_fd=descriptor,
        )
        metadata = os.fstat(lock_descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid():
            raise SnapshotError("the snapshot list lock path is unsafe")
        os.fchmod(lock_descriptor, 0o600)
        try:
            fcntl.flock(
                lock_descriptor,
                fcntl.LOCK_EX | fcntl.LOCK_NB,
            )
        except OSError as error:
            if error.errno in (errno.EACCES, errno.EAGAIN):
                raise SnapshotError(
                    "another installer is already running",
                    75,
                ) from error
            raise SnapshotError(f"unable to acquire the snapshot list lock: {error}") from error
        yield
    finally:
        if lock_descriptor >= 0:
            os.close(lock_descriptor)
        os.close(descriptor)


def report_recovery_artifacts(home: Path) -> None:
    status = snapshot_recovery_status(home)
    for transaction in status.get("transactions", []):
        transaction_status = transaction.get("status")
        if transaction_status not in {
            "prepared",
            "in_progress",
            "recovery_required",
            "invalid",
        } and not (
            transaction.get("kind") == "selective"
            and transaction_status == "committed"
        ):
            continue
        journal = terminal_safe_text(str(transaction.get("journal", "unknown")))
        print(
            f"warning: snapshot recovery artifact requires attention at {journal}; "
            "run 'snapshot recover' to finalize recovery",
            file=sys.stderr,
        )


def list_snapshots() -> int:
    home = home_directory()
    with optional_snapshot_list_lock():
        report_recovery_artifacts(home)
        layout = storage_layout(home)
        storage_descriptor = open_storage_directory(layout, home, create=False)
        if storage_descriptor is None:
            print("No snapshots found.")
            return 0

        found_snapshot = False
        try:
            for name, directory_descriptor in enumerate_snapshot_directories(storage_descriptor):
                snapshot: LoadedSnapshot | None = None
                try:
                    snapshot = load_snapshot_directory(name, directory_descriptor)
                except SnapshotError as error:
                    safe_name = terminal_safe_text(name)
                    print(
                        f"warning: skipping invalid snapshot {safe_name}: "
                        f"{terminal_safe_text(str(error))}",
                        file=sys.stderr,
                    )
                    os.close(directory_descriptor)
                    continue

                if not found_snapshot:
                    print(f"{'ID':<32} {'CREATED':<21} {'FILES':>8}  LABEL")
                    found_snapshot = True
                metadata = snapshot.metadata
                print(
                    f"{metadata['id']:<32} {metadata['created_at']:<21} "
                    f"{metadata['file_count']:>8}  {metadata.get('label', '')}"
                )
                snapshot.close()

            if not found_snapshot:
                print("No snapshots found.")
            return 0
        finally:
            os.close(storage_descriptor)


def changed_entries(
    old: dict[str, Any],
    new: dict[str, Any],
) -> tuple[list[str], list[str], list[str]]:
    old_entries = old.get("entries", {})
    new_entries = new.get("entries", {})
    added = sorted(set(new_entries) - set(old_entries))
    removed = sorted(set(old_entries) - set(new_entries))
    changed = sorted(
        path
        for path in set(old_entries) & set(new_entries)
        if old_entries[path] != new_entries[path]
    )
    return added, removed, changed


def diff_snapshots(first: str, second: str) -> int:
    home = home_directory()
    with optional_snapshot_list_lock():
        report_recovery_artifacts(home)
        layout = storage_layout(home)
        storage_descriptor = open_storage_directory(layout, home, create=False)
        if storage_descriptor is None:
            raise SnapshotError("snapshot storage does not exist")

        first_snapshot: LoadedSnapshot | None = None
        second_snapshot: LoadedSnapshot | None = None
        try:
            first_snapshot = load_snapshot(first, storage_descriptor)
            second_snapshot = load_snapshot(second, storage_descriptor)
            first_root = validate_home_path(
                Path(first_snapshot.metadata["root"]),
                home,
                context="snapshot managed root",
            )
            second_root = validate_home_path(
                Path(second_snapshot.metadata["root"]),
                home,
                context="snapshot managed root",
            )
            if first_root != second_root:
                raise SnapshotError("snapshot managed roots do not match")
            added, removed, changed = changed_entries(
                first_snapshot.manifest,
                second_snapshot.manifest,
            )
            if not added and not removed and not changed:
                print("Snapshots are identical.")
                return 0
            for path in added:
                print(f"added\t{path}")
            for path in removed:
                print(f"removed\t{path}")
            for path in changed:
                print(f"changed\t{path}")
            print(
                f"Summary: {len(added)} added, {len(removed)} removed, "
                f"{len(changed)} changed."
            )
            return 0
        finally:
            if first_snapshot is not None:
                first_snapshot.close()
            if second_snapshot is not None:
                second_snapshot.close()
            os.close(storage_descriptor)


def open_nofollow_parent(
    base_descriptor: int,
    relative: str,
    *,
    create_parents: bool = False,
) -> tuple[int, str, list[tuple[int, str, str, tuple[int, int]]]]:
    parts = relative.split("/")
    if not parts or not parts[-1]:
        raise SnapshotError(f"invalid snapshot path: {terminal_safe_text(relative)}")
    descriptor = os.dup(base_descriptor)
    created: list[tuple[int, str, str, tuple[int, int]]] = []
    parent_parts: list[str] = []
    try:
        for component in parts[:-1]:
            try:
                next_descriptor = os.open(
                    component,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                    dir_fd=descriptor,
                )
            except FileNotFoundError:
                if not create_parents:
                    raise SnapshotError(
                        f"snapshot restore parent directory is missing: {relative}"
                    ) from None
                try:
                    os.mkdir(component, 0o700, dir_fd=descriptor)
                    created_parent_parts = [*parent_parts, component]
                    try:
                        metadata = os.stat(
                            component,
                            dir_fd=descriptor,
                            follow_symlinks=False,
                        )
                    except OSError:
                        try:
                            os.rmdir(component, dir_fd=descriptor)
                        except OSError:
                            pass
                        raise
                    created.append(
                        (
                            os.dup(descriptor),
                            component,
                            "/".join(created_parent_parts),
                            (metadata.st_dev, metadata.st_ino),
                        )
                    )
                except FileExistsError:
                    pass
                try:
                    next_descriptor = os.open(
                        component,
                        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                        dir_fd=descriptor,
                    )
                except OSError as error:
                    if error.errno in (errno.ELOOP, errno.ENOTDIR):
                        raise SnapshotError(
                            f"snapshot path contains an unsafe symbolic-link ancestor: {relative}"
                        ) from error
                    raise SnapshotError(
                        f"unable to open snapshot restore parent: {relative}"
                    ) from error
            except OSError as error:
                if error.errno in (errno.ELOOP, errno.ENOTDIR):
                    raise SnapshotError(
                        f"snapshot path contains an unsafe symbolic-link ancestor: {relative}"
                    ) from error
                raise SnapshotError(
                    f"unable to open snapshot restore parent: {relative}"
                ) from error
            os.close(descriptor)
            descriptor = next_descriptor
            parent_parts.append(component)
        return descriptor, parts[-1], created
    except BaseException:
        os.close(descriptor)
        for created_parent, created_name, _created_path, _identity in reversed(created):
            try:
                os.rmdir(created_name, dir_fd=created_parent)
            except OSError:
                pass
            try:
                os.close(created_parent)
            except OSError:
                pass
        raise


def close_created_directories(
    created: list[tuple[int, str, str, tuple[int, int]]],
) -> None:
    for descriptor, _name, _created_path, _identity in created:
        try:
            os.close(descriptor)
        except OSError:
            pass


def remove_created_parent_directories(
    root_descriptor: int,
    records: list[dict[str, Any]],
) -> list[str]:
    """Remove empty parent directories created by a rolled-back restore."""

    created: dict[str, tuple[int, int]] = {}
    for record in records:
        values = record.get("created_parents")
        if not isinstance(values, list):
            continue
        for value in values:
            if not isinstance(value, dict):
                continue
            path = value.get("path")
            device = value.get("device")
            inode = value.get("inode")
            if (
                not isinstance(path, str)
                or not is_integer(device)
                or not is_integer(inode)
                or device < 0
                or inode < 0
            ):
                continue
            try:
                validate_relative_path(path, status=1)
            except SnapshotError:
                continue
            created[path] = (device, inode)

    failures: list[str] = []
    for path, identity in sorted(
        created.items(),
        key=lambda item: (item[0].count("/"), item[0]),
        reverse=True,
    ):
        try:
            parent_descriptor, name, _created = open_nofollow_parent(
                root_descriptor,
                path,
                create_parents=False,
            )
        except SnapshotError as error:
            if "parent directory is missing" not in str(error):
                failures.append(f"unable to inspect created parent '{path}': {error}")
            continue
        try:
            try:
                metadata = os.stat(
                    name,
                    dir_fd=parent_descriptor,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                continue
            if (
                not stat.S_ISDIR(metadata.st_mode)
                or (metadata.st_dev, metadata.st_ino) != identity
            ):
                # A concurrent writer replaced the directory. Preserve it
                # instead of removing content that the restore did not create.
                continue
            try:
                os.rmdir(name, dir_fd=parent_descriptor)
                os.fsync(parent_descriptor)
            except OSError as error:
                if error.errno not in (errno.ENOTEMPTY, errno.EEXIST):
                    failures.append(
                        f"unable to remove created parent '{path}': {error}"
                    )
        finally:
            os.close(parent_descriptor)
    return failures


def verify_loaded_snapshot_files(snapshot: LoadedSnapshot) -> None:
    verify_path_identity_at(
        snapshot.directory_fd,
        "metadata.json",
        snapshot.metadata_identity,
        "snapshot metadata",
    )
    verify_path_identity_at(
        snapshot.directory_fd,
        "manifest.json",
        snapshot.manifest_identity,
        "snapshot manifest",
    )
    verify_path_identity_at(
        snapshot.directory_fd,
        "snapshot.tar.gz",
        snapshot.archive_identity,
        "snapshot archive",
    )
    verify_archive_fd(
        snapshot.archive_fd,
        snapshot.archive_identity,
        snapshot.metadata,
        snapshot.manifest,
    )


def extract_snapshot(
    snapshot: LoadedSnapshot,
    destination_descriptor: int,
    selected: set[str] | None = None,
) -> None:
    trigger_test_failpoint("before_extraction")
    verify_loaded_snapshot_files(snapshot)
    entries = snapshot.manifest.get("entries", {})
    selected_paths = set(entries)
    if selected is not None:
        missing = sorted(selected - set(entries))
        if missing:
            raise SnapshotError(
                f"requested path is not present in the snapshot: {terminal_safe_text(missing[0])}"
            )
        selected_paths = {
            path
            for path in entries
            if any(path == item or path.startswith(item + "/") for item in selected)
        }

    directory_modes: list[tuple[str, int]] = []
    try:
        os.lseek(snapshot.archive_fd, 0, os.SEEK_SET)
        stream = os.fdopen(os.dup(snapshot.archive_fd), "rb")
        try:
            with tarfile.open(fileobj=stream, mode="r:gz") as bundle:
                members = {member.name: member for member in bundle.getmembers()}
                for relative in sorted(
                    selected_paths,
                    key=lambda item: (item.count("/"), item),
                ):
                    entry = entries[relative]
                    target_parent, target_name, created = open_nofollow_parent(
                        destination_descriptor,
                        relative,
                        create_parents=True,
                    )
                    try:
                        if entry.get("type") == "directory":
                            try:
                                os.mkdir(
                                    target_name,
                                    0o700,
                                    dir_fd=target_parent,
                                )
                            except FileExistsError:
                                child_descriptor = os.open(
                                    target_name,
                                    os.O_RDONLY
                                    | os.O_DIRECTORY
                                    | os.O_NOFOLLOW
                                    | os.O_CLOEXEC,
                                    dir_fd=target_parent,
                                )
                                os.close(child_descriptor)
                            directory_modes.append(
                                (relative, int(entry.get("mode", 0o700)) & 0o777)
                            )
                            continue

                        member = members.get(relative)
                        if member is None:
                            raise SnapshotError(f"archived member is missing: {relative}")

                        if entry.get("type") == "symlink":
                            if not member.issym():
                                raise SnapshotError(f"archived symbolic link is missing: {relative}")
                            link_target = safe_symlink_target(
                                relative,
                                str(entry.get("target", "")),
                            )
                            temporary_name = f".{target_name}.restore-{uuid.uuid4().hex}"
                            try:
                                os.symlink(
                                    link_target,
                                    temporary_name,
                                    dir_fd=target_parent,
                                )
                                replace_entries_at(
                                    target_parent,
                                    temporary_name,
                                    target_parent,
                                    target_name,
                                    "restore symbolic link",
                                )
                            except OSError as error:
                                try:
                                    os.unlink(temporary_name, dir_fd=target_parent)
                                except OSError:
                                    pass
                                raise SnapshotError(
                                    f"unable to restore symbolic link into the managed directory: {error}"
                                ) from error
                            continue

                        if entry.get("type") != "file" or not member.isreg():
                            raise SnapshotError(f"unsupported manifest entry: {relative}")
                        extracted = bundle.extractfile(member)
                        if extracted is None:
                            raise SnapshotError(f"unable to read archived file: {relative}")

                        temporary_name = f".{target_name}.restore-{uuid.uuid4().hex}"
                        target_descriptor = -1
                        digest = hashlib.sha256()
                        size = 0
                        try:
                            target_descriptor = os.open(
                                temporary_name,
                                os.O_WRONLY
                                | os.O_CREAT
                                | os.O_EXCL
                                | os.O_NOFOLLOW
                                | os.O_CLOEXEC,
                                0o600,
                                dir_fd=target_parent,
                            )
                            while True:
                                chunk = extracted.read(1024 * 1024)
                                if not chunk:
                                    break
                                digest.update(chunk)
                                size += len(chunk)
                                offset = 0
                                while offset < len(chunk):
                                    written = os.write(target_descriptor, chunk[offset:])
                                    if written <= 0:
                                        raise SnapshotError("unable to restore archived file")
                                    offset += written
                            if size != entry.get("size"):
                                raise SnapshotError(
                                    f"archived file size does not match its manifest: {relative}"
                                )
                            if digest.hexdigest() != entry.get("sha256"):
                                raise SnapshotError(
                                    f"archived file checksum does not match its manifest: {relative}"
                                )
                            os.fchmod(
                                target_descriptor,
                                int(entry.get("mode", 0o600)) & 0o777,
                            )
                            os.fsync(target_descriptor)
                            os.close(target_descriptor)
                            target_descriptor = -1
                            replace_entries_at(
                                target_parent,
                                temporary_name,
                                target_parent,
                                target_name,
                                "restore archived file",
                            )
                        finally:
                            if target_descriptor >= 0:
                                os.close(target_descriptor)
                            try:
                                os.unlink(temporary_name, dir_fd=target_parent)
                            except OSError:
                                pass
                    finally:
                        os.close(target_parent)
                        close_created_directories(created)
        finally:
            stream.close()
    except SnapshotError:
        raise
    except (OSError, tarfile.TarError) as error:
        raise SnapshotError(f"unable to extract the snapshot: {error}") from error

    for relative, mode in sorted(
        directory_modes,
        key=lambda item: (item[0].count("/"), item[0]),
        reverse=True,
    ):
        target_parent, target_name, _created = open_nofollow_parent(
            destination_descriptor,
            relative,
            create_parents=False,
        )
        try:
            child_descriptor = os.open(
                target_name,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=target_parent,
            )
            try:
                os.fchmod(child_descriptor, mode)
            finally:
                os.close(child_descriptor)
        finally:
            os.close(target_parent)


def selected_paths(arguments: list[str]) -> set[str]:
    selected: set[str] = set()
    for argument in arguments:
        selected.add(validate_relative_path(argument, status=64))
    return selected


def collapse_requested_paths(paths: set[str]) -> list[str]:
    ordered = sorted(paths)
    collapsed: list[str] = []
    for path in ordered:
        if any(path == existing or path.startswith(existing + "/") for existing in collapsed):
            continue
        collapsed.append(path)
    return collapsed


def selective_restore(
    home: Path,
    snapshot: LoadedSnapshot,
    root: Path,
    root_descriptor: int,
    requested: set[str],
) -> list[str]:
    paths = collapse_requested_paths(requested)
    stage_name, stage_descriptor = create_temporary_directory(
        root_descriptor,
        ".snapshot-selective-",
    )
    records: list[dict[str, Any]] = []
    warnings: list[str] = []
    committed = False
    failed = False
    preserve_stage = False
    journal: dict[str, Any] | None = None
    journal_path: Path | None = None

    try:
        mounts = read_mount_ids()
        for relative in paths:
            target_path = root.joinpath(*relative.split("/"))
            reject_mount_boundary(root, target_path, mounts)
            reject_mounted_tree(target_path, mounts)
        extract_snapshot(snapshot, stage_descriptor, set(paths))

        transaction_id = uuid.uuid4().hex
        journal = {
            "schema_version": RECOVERY_JOURNAL_SCHEMA_VERSION,
            "transaction_id": transaction_id,
            "kind": "selective",
            "status": "prepared",
            "phase": "prepared",
            "created_at": dt.datetime.now(dt.timezone.utc).replace(
                microsecond=0
            ).isoformat().replace("+00:00", "Z"),
            "root": str(root),
            "snapshot_id": snapshot.name,
            "stage_name": stage_name,
            "records": records,
        }
        journal_path = write_recovery_journal(home, journal)

        with blocked_snapshot_signals():
            try:
                update_recovery_journal(
                    home,
                    journal,
                    status="in_progress",
                    phase="replacing",
                )
                for relative in paths:
                    source_parent, source_name, source_created = open_nofollow_parent(
                        stage_descriptor,
                        relative,
                        create_parents=False,
                    )
                    target_parent: int | None = None
                    target_created: list[
                        tuple[int, str, str, tuple[int, int]]
                    ] = []
                    record: dict[str, Any] | None = None
                    try:
                        target_parent, target_name, target_created = open_nofollow_parent(
                            root_descriptor,
                            relative,
                            create_parents=True,
                        )
                        backup_name = f".{target_name}.snapshot-restore-backup-{uuid.uuid4().hex}"
                        had_old = entry_exists_at(target_parent, target_name)
                        record = {
                            "relative": relative,
                            "target_name": target_name,
                            "backup_name": backup_name,
                            "backup_path": str(
                                root.joinpath(*relative.split("/")[:-1], backup_name)
                                if "/" in relative
                                else root / backup_name
                            ),
                            "had_old": had_old,
                            "created_parents": [
                                {
                                    "path": created_path,
                                    "device": identity[0],
                                    "inode": identity[1],
                                }
                                for _descriptor, _name, created_path, identity
                                in target_created
                            ],
                            "status": "backup_intent",
                        }
                        records.append(record)
                        update_recovery_journal(
                            home,
                            journal,
                            phase="backup_intent",
                        )

                        target_path = root.joinpath(*relative.split("/"))
                        reject_mount_boundary(root, target_path, mounts)
                        reject_mounted_tree(target_path, mounts)
                        if had_old:
                            replace_entries_at(
                                target_parent,
                                target_name,
                                target_parent,
                                backup_name,
                                "preserve the selective restore target",
                            )
                            record["status"] = "backed_up"
                            update_recovery_journal(
                                home,
                                journal,
                                phase="backed_up",
                            )
                        replace_entries_at(
                            source_parent,
                            source_name,
                            target_parent,
                            target_name,
                            "replace the selective restore target",
                        )
                        record["status"] = "replaced"
                        update_recovery_journal(
                            home,
                            journal,
                            phase="replaced",
                        )
                        trigger_test_failpoint(
                            "after_selective_commit",
                            target=relative,
                        )
                    finally:
                        os.close(source_parent)
                        close_created_directories(source_created)
                        if target_parent is not None:
                            os.close(target_parent)
                        close_created_directories(target_created)

                raise_pending_snapshot_signal()

                # This durable update is the selective transaction's commit
                # point. Backup disposal happens only after it succeeds.
                update_recovery_journal(
                    home,
                    journal,
                    status="committed",
                    phase="committed",
                )
                committed = True
                trigger_test_failpoint("after_selective_commit_point")

                trigger_test_failpoint("before_selective_cleanup")
                for record in records:
                    if not record["had_old"]:
                        record["status"] = "committed"
                        continue
                    target_parent, target_name, _created = open_nofollow_parent(
                        root_descriptor,
                        record["relative"],
                        create_parents=False,
                    )
                    try:
                        try:
                            remove_entry_at(target_parent, record["backup_name"])
                            record["status"] = "cleaned"
                        except SnapshotError as error:
                            retained = entry_path_at(
                                target_parent,
                                record["backup_name"],
                            )
                            record["status"] = "backup_retained"
                            warnings.append(
                                "unable to remove the selective restore backup for "
                                f"'{record['relative']}' at {retained}: {error}"
                            )
                    finally:
                        os.close(target_parent)
                update_recovery_journal(
                    home,
                    journal,
                    status="committed",
                    phase="cleanup",
                    warnings=warnings,
                )
                raise_pending_snapshot_signal()
            except BaseException as error:
                failed = True
                committed_on_disk = committed
                if journal_path is not None and journal is not None:
                    try:
                        committed_on_disk = (
                            read_recovery_journal(journal_path).get("status")
                            in {"committed", "completed"}
                        )
                    except SnapshotError:
                        committed_on_disk = committed
                if committed_on_disk:
                    if journal is not None:
                        update_recovery_journal(
                            home,
                            journal,
                            status="committed",
                            phase="committed",
                            recovery_error=str(error),
                        )
                    if isinstance(error, SnapshotInterrupted):
                        raise SnapshotError(
                            "snapshot restore committed before interruption; "
                            f"the recovery journal was retained at {journal_path}",
                            error.status,
                        ) from error
                    raise SnapshotError(
                        "snapshot restore committed but backup cleanup was incomplete; "
                        f"the recovery journal was retained at {journal_path}: {error}"
                    ) from error

                rollback_failures: list[str] = []
                with blocked_snapshot_signals():
                    for record in reversed(records):
                        target_parent, target_name, _created = open_nofollow_parent(
                            root_descriptor,
                            record["relative"],
                            create_parents=False,
                        )
                        try:
                            backup_exists = entry_exists_at(
                                target_parent,
                                record["backup_name"],
                            )
                            if backup_exists:
                                if entry_exists_at(target_parent, target_name):
                                    remove_entry_at(target_parent, target_name)
                                replace_entries_at(
                                    target_parent,
                                    record["backup_name"],
                                    target_parent,
                                    target_name,
                                    "roll back selective snapshot restore",
                                )
                                record["status"] = "rolled_back"
                            elif not record["had_old"] and entry_exists_at(
                                target_parent,
                                target_name,
                            ):
                                remove_entry_at(target_parent, target_name)
                                record["status"] = "rolled_back"
                            elif record["had_old"] and record["status"] in {
                                "backed_up",
                                "replace_intent",
                                "replaced",
                            }:
                                raise SnapshotError(
                                    "selective restore recovery data is missing"
                                )
                        except BaseException as rollback_error:
                            rollback_failures.append(
                                f"unable to roll back '{record['relative']}': "
                                f"{rollback_error}"
                            )
                        finally:
                            os.close(target_parent)

                rollback_failures.extend(
                    remove_created_parent_directories(root_descriptor, records)
                )
                pending = pending_snapshot_signal()
                if rollback_failures:
                    preserve_stage = True
                    if journal is not None:
                        update_recovery_journal(
                            home,
                            journal,
                            status="recovery_required",
                            phase="recovery_required",
                            recovery_error="; ".join(rollback_failures),
                        )
                    raise SnapshotError(
                        "selective snapshot restore failed and rollback was incomplete; "
                        "complete backup and recovery data were preserved: "
                        + "; ".join(rollback_failures)
                    ) from error
                if journal is not None:
                    update_recovery_journal(
                        home,
                        journal,
                        status="recovered",
                        phase="recovered",
                    )
                if pending is not None:
                    if pending == signal.SIGTERM:
                        raise SnapshotInterrupted(signal.SIGTERM) from error
                    if pending == signal.SIGINT:
                        raise KeyboardInterrupt() from error
                    if pending == signal.SIGHUP:
                        raise SnapshotInterrupted(signal.SIGHUP) from error
                raise
        return warnings
    finally:
        if not preserve_stage:
            try:
                remove_entry_at(root_descriptor, stage_name)
            except SnapshotError as error:
                warning = (
                    "unable to remove the selective restore staging directory "
                    f"at {entry_path_at(root_descriptor, stage_name)}: {error}"
                )
                warnings.append(warning)
                if failed:
                    print(f"warning: {warning}", file=sys.stderr)
                    if journal_path is not None and journal is not None:
                        update_recovery_journal(
                            home,
                            journal,
                            status="recovery_required",
                            phase="cleanup",
                            warnings=warnings,
                        )
        try:
            if not failed and journal_path is not None and journal is not None:
                cleanup_failed = bool(warnings)
                cleanup_status = "committed" if cleanup_failed else "completed"
                update_recovery_journal(
                    home,
                    journal,
                    status=cleanup_status,
                    phase=cleanup_status,
                    warnings=warnings,
                )
                warnings.append(f"Recovery journal retained at {journal_path}.")
                if cleanup_failed:
                    raise SnapshotError(
                        "snapshot restore committed but cleanup was incomplete: "
                        + "; ".join(warnings)
                    )
        finally:
            os.close(stage_descriptor)


def open_child_directory(parent_descriptor: int, name: str) -> int:
    validate_entry_name(name, "directory component")
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=parent_descriptor,
        )
    except OSError as error:
        if error.errno in (errno.ELOOP, errno.ENOTDIR):
            raise SnapshotError(
                f"snapshot path contains an unsafe symbolic-link component: {name}"
            ) from error
        raise SnapshotError(f"unable to open directory '{name}': {error}") from error
    metadata = os.fstat(descriptor)
    if not stat.S_ISDIR(metadata.st_mode):
        os.close(descriptor)
        raise SnapshotError(f"path component is not a directory: {name}")
    return descriptor


def recover_nested_storage(
    root_parent_descriptor: int,
    root_name: str,
    storage_relative: tuple[str, ...],
    preserved_storage_name: str,
) -> bool:
    """Move storage back out of a partially restored managed root.

    During a whole-tree restore the snapshot storage directory can be nested
    below the managed root. If the transaction fails after that directory was
    relocated into the replacement root, it must be moved out again before
    the previous root is restored. Otherwise the rollback would discard the
    only remaining copy of the snapshot store.
    """

    if not entry_exists_at(root_parent_descriptor, root_name):
        return False
    current_root_descriptor = open_child_directory(root_parent_descriptor, root_name)
    try:
        nested_parent = open_components_from_descriptor(
            current_root_descriptor,
            storage_relative[:-1],
            create=False,
            private=False,
        )
    finally:
        os.close(current_root_descriptor)
    if nested_parent is None:
        return False
    try:
        if not entry_exists_at(nested_parent, storage_relative[-1]):
            return False
        if entry_exists_at(root_parent_descriptor, preserved_storage_name):
            raise SnapshotError(
                "snapshot storage exists in both the preserved and replacement locations"
            )
        os.replace(
            storage_relative[-1],
            preserved_storage_name,
            src_dir_fd=nested_parent,
            dst_dir_fd=root_parent_descriptor,
        )
        return True
    finally:
        os.close(nested_parent)


def set_directory_mode(
    parent_descriptor: int,
    name: str,
    mode: int,
) -> None:
    descriptor = open_child_directory(parent_descriptor, name)
    try:
        os.fchmod(descriptor, mode)
    finally:
        os.close(descriptor)


@contextmanager
def blocked_snapshot_signals() -> Iterator[None]:
    if not hasattr(signal, "pthread_sigmask"):
        yield
        return
    blocked = {signal.SIGINT, signal.SIGTERM, signal.SIGHUP}
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
    try:
        yield
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


def pending_snapshot_signal() -> int | None:
    if _PENDING_SNAPSHOT_SIGNAL is not None:
        return _PENDING_SNAPSHOT_SIGNAL
    if not hasattr(signal, "sigpending"):
        return None
    pending = signal.sigpending()
    if signal.SIGTERM in pending:
        return signal.SIGTERM
    if signal.SIGINT in pending:
        return signal.SIGINT
    if signal.SIGHUP in pending:
        return signal.SIGHUP
    return None


def raise_pending_snapshot_signal() -> None:
    signal_number = pending_snapshot_signal()
    if signal_number == signal.SIGTERM:
        raise SnapshotInterrupted(signal.SIGTERM)
    if signal_number == signal.SIGINT:
        raise KeyboardInterrupt()
    if signal_number == signal.SIGHUP:
        raise SnapshotInterrupted(signal.SIGHUP)


def validate_journal_entry_name(value: Any, context: str) -> str:
    if not isinstance(value, str):
        raise SnapshotError(f"snapshot recovery journal has an invalid {context}")
    try:
        return validate_entry_name(value, context)
    except SnapshotError as error:
        raise SnapshotError(
            f"snapshot recovery journal has an invalid {context}"
        ) from error


def validate_journal_pattern(
    value: Any,
    pattern: re.Pattern[str],
    context: str,
) -> str:
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise SnapshotError(f"snapshot recovery journal has an invalid {context}")
    return value


def validate_recovery_journal_fields(journal: dict[str, Any]) -> None:
    """Validate journal-controlled names and state before any recovery action."""

    root_value = journal.get("root")
    if (
        not isinstance(root_value, str)
        or not root_value
        or CONTROL_CHARACTER_PATTERN.search(root_value)
    ):
        raise SnapshotError("snapshot recovery journal has an invalid managed root")
    root = Path(root_value)
    if not root.is_absolute() or not root.name:
        raise SnapshotError("snapshot recovery journal has an invalid managed root")
    root_name = root.name

    snapshot_id = journal.get("snapshot_id")
    if not isinstance(snapshot_id, str) or ID_PATTERN.fullmatch(snapshot_id) is None:
        raise SnapshotError("snapshot recovery journal has an invalid snapshot identifier")

    kind = journal.get("kind")
    if kind == "selective":
        validate_journal_pattern(
            journal.get("stage_name"),
            re.compile(r"^\.snapshot-selective-[0-9a-f]{32}$"),
            "staging name",
        )
        records = journal.get("records")
        if not isinstance(records, list):
            raise SnapshotError(
                "snapshot recovery journal has invalid restore records"
            )
        for record in records:
            if not isinstance(record, dict):
                raise SnapshotError(
                    "snapshot recovery journal has an invalid restore record"
                )
            relative = record.get("relative")
            if not isinstance(relative, str):
                raise SnapshotError(
                    "snapshot recovery journal has an invalid restore path"
                )
            validate_relative_path(relative, status=1)
            target_name = validate_journal_entry_name(
                record.get("target_name"),
                "target name",
            )
            if relative.split("/")[-1] != target_name:
                raise SnapshotError(
                    "snapshot recovery journal has an invalid restore target"
                )
            validate_journal_pattern(
                record.get("backup_name"),
                re.compile(
                    rf"^\.{re.escape(target_name)}\.snapshot-restore-backup-"
                    r"[0-9a-f]{32}$"
                ),
                "backup name",
            )
            if not isinstance(record.get("had_old"), bool):
                raise SnapshotError(
                    "snapshot recovery journal has an invalid prior-target state"
                )
            if record.get("status") not in SELECTIVE_RECORD_STATUSES:
                raise SnapshotError(
                    "snapshot recovery journal has an invalid restore-record status"
                )
            created_parents = record.get("created_parents")
            if not isinstance(created_parents, list):
                raise SnapshotError(
                    "snapshot recovery journal has invalid created-parent records"
                )
            for created_parent in created_parents:
                if not isinstance(created_parent, dict):
                    raise SnapshotError(
                        "snapshot recovery journal has invalid created-parent records"
                    )
                path = created_parent.get("path")
                device = created_parent.get("device")
                inode = created_parent.get("inode")
                if not isinstance(path, str):
                    raise SnapshotError(
                        "snapshot recovery journal has invalid created-parent records"
                    )
                validate_relative_path(path, status=1)
                if (
                    not is_integer(device)
                    or not is_integer(inode)
                    or device < 0
                    or inode < 0
                ):
                    raise SnapshotError(
                        "snapshot recovery journal has invalid created-parent records"
                    )
        if journal.get("status") == "completed" and any(
            isinstance(record, dict)
            and record.get("status") == "backup_retained"
            for record in records
        ):
            raise SnapshotError(
                "snapshot recovery journal has an incomplete selective cleanup"
            )
        return

    if kind != "whole":
        raise SnapshotError("snapshot recovery journal has an invalid transaction kind")

    validate_journal_pattern(
        journal.get("stage_name"),
        re.compile(rf"^\.{re.escape(root_name)}\.snapshot-stage-[0-9a-f]{{32}}$"),
        "staging name",
    )
    root_existed = journal.get("root_existed")
    if not isinstance(root_existed, bool):
        raise SnapshotError("snapshot recovery journal has an invalid root state")
    backup_name = journal.get("backup_name")
    if root_existed:
        validate_journal_pattern(
            backup_name,
            re.compile(
                rf"^\.{re.escape(root_name)}\.pre-snapshot-restore-"
                rf"{re.escape(snapshot_id)}-[0-9a-f]{{8}}$"
            ),
            "backup name",
        )
    elif backup_name is not None:
        raise SnapshotError("snapshot recovery journal has an invalid backup name")

    storage_relative = journal.get("storage_relative")
    if not isinstance(storage_relative, list):
        raise SnapshotError("snapshot recovery journal has an invalid storage path")
    for component in storage_relative:
        if (
            not isinstance(component, str)
            or not component
            or component in {".", ".."}
            or "/" in component
            or "\\" in component
            or CONTROL_CHARACTER_PATTERN.search(component)
        ):
            raise SnapshotError("snapshot recovery journal has an invalid storage path")

    preserved_storage_name = journal.get("preserved_storage_name")
    if storage_relative:
        validate_journal_pattern(
            preserved_storage_name,
            re.compile(
                rf"^\.{re.escape(root_name)}\.snapshot-storage-[0-9a-f]{{32}}$"
            ),
            "preserved storage name",
        )
    elif preserved_storage_name is not None:
        raise SnapshotError(
            "snapshot recovery journal has an invalid preserved storage name"
        )

    failed_root_name = journal.get("failed_root_name")
    if failed_root_name is not None:
        validate_journal_pattern(
            failed_root_name,
            re.compile(
                rf"^\.{re.escape(root_name)}\.failed-snapshot-restore-"
                r"[0-9a-f]{32}$"
            ),
            "failed root name",
        )

    storage_path = journal.get("storage_path")
    if (
        not isinstance(storage_path, str)
        or not Path(storage_path).is_absolute()
        or CONTROL_CHARACTER_PATTERN.search(storage_path)
    ):
        raise SnapshotError("snapshot recovery journal has an invalid storage path")


def journal_path_under_home(home: Path, value: Any, context: str) -> Path:
    if not isinstance(value, str) or not value:
        raise SnapshotError(f"snapshot recovery journal has an invalid {context}")
    candidate = Path(value)
    if not candidate.is_absolute():
        raise SnapshotError(f"snapshot recovery journal has an invalid {context}")
    canonical = canonical_absolute(candidate)
    if canonical == home:
        raise SnapshotError(
            f"snapshot recovery journal {context} must not be the home directory"
        )
    if not path_is_at_or_below(canonical, home):
        raise SnapshotError(
            f"snapshot recovery journal {context} is outside the home directory"
        )
    return canonical


def journal_relative_components(value: Any, context: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not value:
        raise SnapshotError(f"snapshot recovery journal has an invalid {context}")
    components: list[str] = []
    for component in value:
        if not isinstance(component, str) or not component:
            raise SnapshotError(f"snapshot recovery journal has an invalid {context}")
        if (
            component in {".", ".."}
            or "/" in component
            or "\\" in component
            or CONTROL_CHARACTER_PATTERN.search(component)
        ):
            raise SnapshotError(f"snapshot recovery journal has an invalid {context}")
        components.append(component)
    return tuple(components)


def nested_storage_parent(
    root_descriptor: int,
    storage_relative: tuple[str, ...],
    *,
    create: bool,
) -> int | None:
    if not storage_relative:
        return None
    if len(storage_relative) == 1:
        return os.dup(root_descriptor)
    return open_components_from_descriptor(
        root_descriptor,
        storage_relative[:-1],
        create=create,
        private=create,
    )


def move_nested_storage_to_preserved(
    root_parent_descriptor: int,
    root_descriptor: int,
    storage_relative: tuple[str, ...],
    preserved_storage_name: str,
) -> bool:
    nested_parent = nested_storage_parent(
        root_descriptor,
        storage_relative,
        create=False,
    )
    if nested_parent is None:
        return False
    try:
        if not entry_exists_at(nested_parent, storage_relative[-1]):
            return False
        if entry_exists_at(root_parent_descriptor, preserved_storage_name):
            raise SnapshotError(
                "snapshot storage exists in both preserved and replacement locations"
            )
        replace_entries_at(
            nested_parent,
            storage_relative[-1],
            root_parent_descriptor,
            preserved_storage_name,
            "recover relocated snapshot storage",
        )
        return True
    finally:
        os.close(nested_parent)


def recovery_artifact_paths(journal: dict[str, Any]) -> list[str]:
    artifacts: list[str] = []

    def add_artifact(value: Any) -> None:
        if isinstance(value, str) and value:
            safe_value = terminal_safe_text(value)
            if safe_value not in artifacts:
                artifacts.append(safe_value)

    for key in (
        "root",
        "backup_path",
        "failed_root_path",
        "preserved_storage_path",
        "stage_path",
    ):
        add_artifact(journal.get(key))

    root_value = journal.get("root")
    root = Path(root_value) if isinstance(root_value, str) and root_value else None
    kind = journal.get("kind")

    def safe_entry_name(value: Any) -> str | None:
        try:
            return validate_journal_entry_name(value, "artifact name")
        except SnapshotError:
            return None

    if root is not None:
        if kind == "selective":
            stage_name = safe_entry_name(journal.get("stage_name"))
            if stage_name is not None:
                add_artifact(str(root / stage_name))
        elif kind == "whole":
            base = root.parent
            for key in (
                "stage_name",
                "backup_name",
                "preserved_storage_name",
                "failed_root_name",
            ):
                name = safe_entry_name(journal.get(key))
                if name is not None:
                    add_artifact(str(base / name))

    records = journal.get("records")
    if isinstance(records, list):
        for record in records:
            if not isinstance(record, dict):
                continue
            for key in ("backup_path", "recovery_path"):
                add_artifact(record.get(key))
            if root is None or kind != "selective":
                continue
            relative = record.get("relative")
            backup_name = safe_entry_name(record.get("backup_name"))
            if not isinstance(relative, str) or backup_name is None:
                continue
            try:
                validate_relative_path(relative, status=1)
            except SnapshotError:
                continue
            parent = root.joinpath(*relative.split("/")[:-1])
            add_artifact(str(parent / backup_name))
    return artifacts


def recover_whole_transaction(
    home: Path,
    journal: dict[str, Any],
    journal_path: Path,
    expected_root: Path,
) -> list[str]:
    root = journal_path_under_home(home, journal.get("root"), "managed root")
    if root != expected_root:
        raise SnapshotError(
            "snapshot recovery journal managed root does not match the configured managed root"
        )
    storage_path = journal_path_under_home(
        home,
        journal.get("storage_path"),
        "storage path",
    )
    storage_relative = (
        journal_relative_components(
            journal.get("storage_relative"),
            "storage path",
        )
        if isinstance(journal.get("storage_relative"), list)
        and journal.get("storage_relative")
        else tuple()
    )
    if storage_relative and storage_path != root.joinpath(*storage_relative):
        raise SnapshotError("snapshot recovery journal has inconsistent storage paths")

    root_existed = journal.get("root_existed")
    if not isinstance(root_existed, bool):
        raise SnapshotError("snapshot recovery journal has an invalid root state")

    backup_value = journal.get("backup_name")
    preserved_storage_value = journal.get("preserved_storage_name")
    failed_root_value = journal.get("failed_root_name")

    if root_existed:
        backup_name = validate_journal_entry_name(backup_value, "backup name")
    elif backup_value is None:
        backup_name = None
    else:
        raise SnapshotError("snapshot recovery journal has an invalid backup name")

    if storage_relative:
        preserved_storage_name = validate_journal_entry_name(
            preserved_storage_value,
            "preserved storage name",
        )
    elif preserved_storage_value is None:
        preserved_storage_name = None
    else:
        raise SnapshotError(
            "snapshot recovery journal has an invalid preserved storage name"
        )

    if failed_root_value is None:
        failed_root_name = None
    else:
        failed_root_name = validate_journal_entry_name(
            failed_root_value,
            "failed root name",
        )
    stage_name = validate_journal_entry_name(
        journal.get("stage_name"),
        "staging name",
    )
    snapshot_id = validate_journal_entry_name(
        journal.get("snapshot_id"),
        "snapshot identifier",
    )

    root_parent_descriptor = open_directory_under_home(
        home,
        root.parent,
        create=False,
    )
    if root_parent_descriptor is None:
        raise SnapshotError("snapshot recovery journal managed-root parent is missing")
    warnings: list[str] = []
    try:
        mounts = read_mount_ids()
        root_exists = entry_exists_at(root_parent_descriptor, root.name)
        backup_exists = (
            backup_name is not None
            and entry_exists_at(root_parent_descriptor, backup_name)
        )
        had_backup = backup_exists
        preserved_exists = (
            preserved_storage_name is not None
            and entry_exists_at(root_parent_descriptor, preserved_storage_name)
        )
        current_root_descriptor: int | None = None
        backup_root_descriptor: int | None = None
        try:
            if root_exists:
                current_root_descriptor = open_child_directory(
                    root_parent_descriptor,
                    root.name,
                )
                reject_mounted_tree(root, mounts)
            if backup_exists:
                backup_root_descriptor = open_child_directory(
                    root_parent_descriptor,
                    backup_name,
                )
                reject_mounted_tree(root.parent / backup_name, mounts)

            nested_locations: list[str] = []
            if preserved_exists:
                nested_locations.append("preserved")
            if current_root_descriptor is not None and storage_relative:
                nested_parent = nested_storage_parent(
                    current_root_descriptor,
                    storage_relative,
                    create=False,
                )
                if nested_parent is not None:
                    try:
                        if entry_exists_at(nested_parent, storage_relative[-1]):
                            nested_locations.append("current")
                    finally:
                        os.close(nested_parent)
            if backup_root_descriptor is not None and storage_relative:
                nested_parent = nested_storage_parent(
                    backup_root_descriptor,
                    storage_relative,
                    create=False,
                )
                if nested_parent is not None:
                    try:
                        if entry_exists_at(nested_parent, storage_relative[-1]):
                            nested_locations.append("backup")
                    finally:
                        os.close(nested_parent)
            if len(nested_locations) > 1:
                raise SnapshotError(
                    "snapshot storage recovery found multiple preserved copies; "
                    "manual recovery is required"
                )

            if (
                current_root_descriptor is not None
                and nested_locations == ["current"]
                and (had_backup or not root_existed)
            ):
                moved = move_nested_storage_to_preserved(
                    root_parent_descriptor,
                    current_root_descriptor,
                    storage_relative,
                    preserved_storage_name,
                )
                if moved:
                    nested_locations = ["preserved"]
                    preserved_exists = True

            if backup_exists:
                trigger_test_failpoint("fail_root_rollback")
                if root_exists:
                    if failed_root_name is None:
                        failed_root_name = (
                            f".{root.name}.failed-snapshot-restore-"
                            f"{journal['transaction_id']}"
                        )
                    update_recovery_journal(
                        home,
                        journal,
                        failed_root_name=failed_root_name,
                        phase="failed_root_intent",
                    )
                    replace_entries_at(
                        root_parent_descriptor,
                        root.name,
                        root_parent_descriptor,
                        failed_root_name,
                        "preserve the failed restored root",
                    )
                    root_exists = False
                    trigger_test_failpoint("after_failed_root_rename")
                replace_entries_at(
                    root_parent_descriptor,
                    backup_name,
                    root_parent_descriptor,
                    root.name,
                    "restore the previous managed root",
                )
                root_exists = True
                backup_exists = False
            elif root_existed and not root_exists:
                raise SnapshotError(
                    "the previous managed root is missing; manual recovery is required"
                )
            elif not root_existed and root_exists:
                if failed_root_name is None:
                    failed_root_name = (
                        f".{root.name}.failed-snapshot-restore-"
                        f"{journal['transaction_id']}"
                    )
                update_recovery_journal(
                    home,
                    journal,
                    failed_root_name=failed_root_name,
                    phase="failed_root_intent",
                )
                replace_entries_at(
                    root_parent_descriptor,
                    root.name,
                    root_parent_descriptor,
                    failed_root_name,
                    "preserve the failed restored root",
                )
                root_exists = False
                trigger_test_failpoint("after_failed_root_rename")

            if storage_relative and not root_exists:
                raise SnapshotError(
                    "the recovered managed root is required to restore nested snapshot storage"
                )

            if storage_relative:
                # If the old root was never replaced, its nested storage is
                # already in the correct location. Otherwise the store was
                # extracted from the replacement root into the preserved
                # sibling before the old root was restored.
                if (
                    not had_backup
                    and nested_locations == ["current"]
                    and root_exists
                ):
                    storage_in_original = True
                else:
                    storage_in_original = False
                if not storage_in_original:
                    if not preserved_exists:
                        if nested_locations == ["backup"]:
                            nested_parent = nested_storage_parent(
                                backup_root_descriptor,
                                storage_relative,
                                create=False,
                            ) if backup_root_descriptor is not None else None
                            if nested_parent is None:
                                raise SnapshotError(
                                    "snapshot storage recovery data is missing"
                                )
                            try:
                                replace_entries_at(
                                    nested_parent,
                                    storage_relative[-1],
                                    root_parent_descriptor,
                                    preserved_storage_name,
                                    "preserve snapshot storage",
                                )
                            finally:
                                os.close(nested_parent)
                            preserved_exists = True
                        else:
                            raise SnapshotError(
                                "snapshot storage recovery data is missing"
                            )
                    trigger_test_failpoint("fail_storage_rollback")
                    restored_root_descriptor = open_child_directory(
                        root_parent_descriptor,
                        root.name,
                    )
                    try:
                        destination_parent = nested_storage_parent(
                            restored_root_descriptor,
                            storage_relative,
                            create=True,
                        )
                        if destination_parent is None:
                            raise SnapshotError(
                                "unable to prepare the recovered snapshot storage parent"
                            )
                        try:
                            if entry_exists_at(
                                destination_parent,
                                storage_relative[-1],
                            ):
                                raise SnapshotError(
                                    "the recovered managed root already contains snapshot storage"
                                )
                            replace_entries_at(
                                root_parent_descriptor,
                                preserved_storage_name,
                                destination_parent,
                                storage_relative[-1],
                                "restore snapshot storage",
                            )
                        finally:
                            os.close(destination_parent)
                    finally:
                        os.close(restored_root_descriptor)
                    preserved_exists = False
            else:
                storage_descriptor = open_directory_under_home(
                    home,
                    storage_path,
                    create=False,
                )
                if storage_descriptor is None:
                    raise SnapshotError("snapshot storage recovery data is missing")
                os.close(storage_descriptor)

            # Positively confirm the recovered root (when one existed) and the
            # snapshot store before any failed replacement root is recursively
            # removed. A root that did not exist before the transaction must
            # remain absent after rollback.
            if root_exists:
                recovered_root_descriptor = open_child_directory(
                    root_parent_descriptor,
                    root.name,
                )
                os.close(recovered_root_descriptor)
            elif root_existed:
                raise SnapshotError(
                    "the recovered managed root could not be confirmed"
                )

            recovered_storage_descriptor = open_directory_under_home(
                home,
                storage_path,
                create=False,
            )
            if recovered_storage_descriptor is None:
                raise SnapshotError(
                    "recovered snapshot storage could not be confirmed"
                )
            try:
                if not entry_exists_at(
                    recovered_storage_descriptor,
                    snapshot_id,
                ):
                    raise SnapshotError(
                        "the recovered snapshot store does not contain the expected snapshot"
                    )
            finally:
                os.close(recovered_storage_descriptor)

            if entry_exists_at(root_parent_descriptor, stage_name):
                try:
                    remove_entry_at(root_parent_descriptor, stage_name)
                except SnapshotError as cleanup_error:
                    warnings.append(
                        "snapshot recovery completed, but the staging directory "
                        f"could not be removed: {cleanup_error}"
                    )

            failed_root_path: str | None = None
            if failed_root_name is not None and entry_exists_at(
                root_parent_descriptor,
                failed_root_name,
            ):
                failed_root_path = str(root.parent / failed_root_name)
                try:
                    remove_entry_at(root_parent_descriptor, failed_root_name)
                    failed_root_path = None
                except SnapshotError as cleanup_error:
                    warnings.append(
                        "the recovered root is safe, but the failed replacement root "
                        f"could not be removed at {failed_root_path}: {cleanup_error}"
                    )
        finally:
            if current_root_descriptor is not None:
                os.close(current_root_descriptor)
            if backup_root_descriptor is not None:
                os.close(backup_root_descriptor)

        cleanup_status = "recovery_required" if warnings else "recovered"
        update_recovery_journal(
            home,
            journal,
            status=cleanup_status,
            phase=cleanup_status,
            backup_path=str(root.parent / backup_name) if backup_exists else None,
            failed_root_path=failed_root_path,
            preserved_storage_path=(
                str(root.parent / preserved_storage_name)
                if preserved_exists
                else None
            ),
            warnings=warnings,
        )
        if warnings:
            raise SnapshotError(
                "snapshot recovery completed, but cleanup is incomplete: "
                + "; ".join(warnings)
            )
        return warnings
    finally:
        os.close(root_parent_descriptor)


def finalize_committed_selective_transaction(
    home: Path,
    journal: dict[str, Any],
    journal_path: Path,
    expected_root: Path,
) -> list[str]:
    """Finish cleanup for a selective restore that reached its commit point.

    A committed selective restore must never be rolled back: the restored
    content is already the authoritative result. Recovery only removes the
    retained per-path backups and staging directory, then closes the durable
    journal as completed.
    """

    root = journal_path_under_home(home, journal.get("root"), "managed root")
    if root != expected_root:
        raise SnapshotError(
            "snapshot recovery journal managed root does not match the configured managed root"
        )
    root_descriptor = open_directory_under_home(home, root, create=False)
    if root_descriptor is None:
        raise SnapshotError("snapshot recovery journal managed root is missing")
    records = journal.get("records")
    if not isinstance(records, list):
        os.close(root_descriptor)
        raise SnapshotError("snapshot recovery journal has invalid restore records")
    warnings: list[str] = []
    try:
        for record in records:
            if not isinstance(record, dict):
                raise SnapshotError("snapshot recovery journal has an invalid restore record")
            relative = record.get("relative")
            if not isinstance(relative, str):
                raise SnapshotError("snapshot recovery journal has an invalid restore path")
            validate_relative_path(relative, status=1)
            backup_name = validate_journal_entry_name(
                record.get("backup_name"),
                "backup name",
            )
            target_parent, _target_name, _created = open_nofollow_parent(
                root_descriptor,
                relative,
                create_parents=False,
            )
            try:
                if not entry_exists_at(target_parent, backup_name):
                    record["status"] = "cleaned"
                    continue
                try:
                    remove_entry_at(target_parent, backup_name)
                    record["status"] = "cleaned"
                except SnapshotError as error:
                    retained = entry_path_at(target_parent, backup_name)
                    record["status"] = "backup_retained"
                    warnings.append(
                        "unable to remove the committed selective restore backup for "
                        f"'{relative}' at {retained}: {error}"
                    )
            finally:
                os.close(target_parent)

        stage_name = validate_journal_entry_name(
            journal.get("stage_name"),
            "staging name",
        )
        if entry_exists_at(root_descriptor, stage_name):
            try:
                remove_entry_at(root_descriptor, stage_name)
            except SnapshotError as cleanup_error:
                warnings.append(
                    "the committed selective restore could not remove its staging "
                    f"directory: {cleanup_error}"
                )

        update_recovery_journal(
            home,
            journal,
            status="committed" if warnings else "completed",
            phase="committed" if warnings else "completed",
            warnings=warnings,
        )
        if warnings:
            raise SnapshotError(
                "the selective snapshot restore is committed, but recovery cleanup "
                "is incomplete: " + "; ".join(warnings)
            )
        return warnings
    finally:
        os.close(root_descriptor)


def recover_selective_transaction(
    home: Path,
    journal: dict[str, Any],
    journal_path: Path,
    expected_root: Path,
) -> list[str]:
    root = journal_path_under_home(home, journal.get("root"), "managed root")
    if root != expected_root:
        raise SnapshotError(
            "snapshot recovery journal managed root does not match the configured managed root"
        )
    root_descriptor = open_directory_under_home(home, root, create=False)
    if root_descriptor is None:
        raise SnapshotError("snapshot recovery journal managed root is missing")
    records = journal.get("records")
    if not isinstance(records, list):
        os.close(root_descriptor)
        raise SnapshotError("snapshot recovery journal has invalid restore records")
    warnings: list[str] = []
    try:
        for record in reversed(records):
            if not isinstance(record, dict):
                raise SnapshotError("snapshot recovery journal has an invalid restore record")
            relative = record.get("relative")
            if not isinstance(relative, str):
                raise SnapshotError("snapshot recovery journal has an invalid restore path")
            validate_relative_path(relative, status=1)
            backup_name = validate_journal_entry_name(
                record.get("backup_name"),
                "backup name",
            )
            target_parent, target_name, _created = open_nofollow_parent(
                root_descriptor,
                relative,
                create_parents=False,
            )
            try:
                had_old = record.get("had_old")
                backup_exists = entry_exists_at(target_parent, backup_name)
                if backup_exists:
                    if entry_exists_at(target_parent, target_name):
                        remove_entry_at(target_parent, target_name)
                    replace_entries_at(
                        target_parent,
                        backup_name,
                        target_parent,
                        target_name,
                        "roll back selective snapshot restore",
                    )
                elif not had_old and entry_exists_at(target_parent, target_name):
                    remove_entry_at(target_parent, target_name)
                elif had_old and record.get("status") in {
                    "backed_up",
                    "replace_intent",
                    "replaced",
                }:
                    raise SnapshotError(
                        "selective restore recovery data is missing; manual recovery is required"
                    )
            finally:
                os.close(target_parent)

        created_parent_failures = remove_created_parent_directories(
            root_descriptor,
            records,
        )
        if created_parent_failures:
            raise SnapshotError(
                "unable to remove selective restore parent directories: "
                + "; ".join(created_parent_failures)
            )

        stage_name = validate_journal_entry_name(
            journal.get("stage_name"),
            "staging name",
        )
        if entry_exists_at(root_descriptor, stage_name):
            try:
                remove_entry_at(root_descriptor, stage_name)
            except SnapshotError as cleanup_error:
                warnings.append(
                    "selective restore was rolled back, but its staging directory "
                    f"could not be removed: {cleanup_error}"
                )
        cleanup_status = "recovery_required" if warnings else "recovered"
        update_recovery_journal(
            home,
            journal,
            status=cleanup_status,
            phase=cleanup_status,
            warnings=warnings,
        )
        if warnings:
            raise SnapshotError(
                "snapshot recovery completed, but cleanup is incomplete: "
                + "; ".join(warnings)
            )
        return warnings
    finally:
        os.close(root_descriptor)


def pending_recovery_transactions(home: Path) -> list[tuple[Path, dict[str, Any]]]:
    pending: list[tuple[Path, dict[str, Any]]] = []
    for path in recovery_journal_paths(home):
        journal = read_recovery_journal(path)
        status = journal.get("status")
        if status in {"prepared", "in_progress", "recovery_required"} or (
            journal.get("kind") == "selective" and status == "committed"
        ):
            pending.append((path, journal))
    return pending


def recover_pending_transactions(
    home: Path,
    expected_root: Path | None = None,
) -> list[str]:
    messages: list[str] = []
    if expected_root is None:
        expected_root = managed_root(home, require_discovery=False)
    for path, journal in pending_recovery_transactions(home):
        kind = journal.get("kind")
        committed_selective = kind == "selective" and journal.get("status") == "committed"
        try:
            if kind == "whole":
                warnings = recover_whole_transaction(
                    home,
                    journal,
                    path,
                    expected_root,
                )
            elif kind == "selective":
                if committed_selective:
                    warnings = finalize_committed_selective_transaction(
                        home,
                        journal,
                        path,
                        expected_root,
                    )
                else:
                    warnings = recover_selective_transaction(
                        home,
                        journal,
                        path,
                        expected_root,
                    )
            else:
                raise SnapshotError("snapshot recovery journal has an invalid kind")
        except BaseException as error:
            update_recovery_journal(
                home,
                journal,
                status="committed" if committed_selective else "recovery_required",
                phase="committed" if committed_selective else "recovery_required",
                recovery_error=str(error),
            )
            raise SnapshotError(
                "snapshot recovery could not complete; the recovery journal and all "
                f"available copies were preserved at {path}: {error}"
            ) from error
        messages.append(f"Recovered pending snapshot transaction from {path}.")
        messages.extend(warnings)
    return messages


def snapshot_recovery_status(home: Path) -> dict[str, Any]:
    transactions: list[dict[str, Any]] = []
    attention = False
    expected_root: Path | None = None
    expected_root_error: str | None = None
    try:
        expected_root = managed_root(home, require_discovery=False)
    except SnapshotError as error:
        expected_root_error = str(error)
    for path in recovery_journal_paths(home):
        try:
            journal = read_recovery_journal(path)
        except SnapshotError as error:
            attention = True
            transactions.append(
                {
                    "journal": str(path),
                    "status": "invalid",
                    "kind": "unknown",
                    "message": str(error),
                    "artifacts": [str(path)],
                }
            )
            continue
        status = str(journal.get("status", "unknown"))
        message = journal.get("recovery_error")
        if expected_root_error is not None:
            message = expected_root_error
            if status in {"prepared", "in_progress", "recovery_required"} or (
                journal.get("kind") == "selective" and status == "committed"
            ):
                status = "invalid"
        elif expected_root is not None:
            try:
                journal_root = journal_path_under_home(
                    home,
                    journal.get("root"),
                    "managed root",
                )
            except SnapshotError as error:
                journal_root = None
                message = str(error)
            if journal_root is not None and journal_root != expected_root:
                status = "invalid"
                message = (
                    "snapshot recovery journal managed root does not match the "
                    "configured managed root"
                )
        if status in {"prepared", "in_progress", "recovery_required", "invalid"} or (
            journal.get("kind") == "selective" and status == "committed"
        ):
            attention = True
        transactions.append(
            {
                "journal": str(path),
                "transaction_id": journal.get("transaction_id"),
                "kind": journal.get("kind"),
                "status": status,
                "phase": journal.get("phase"),
                "root": journal.get("root"),
                "snapshot_id": journal.get("snapshot_id"),
                "message": message,
                "artifacts": [str(path), *recovery_artifact_paths(journal)],
            }
        )
    return {
        "status": "attention" if attention else "ok",
        "transactions": transactions,
    }


def restore_whole_tree(
    snapshot: LoadedSnapshot,
    home: Path,
    root: Path,
    root_components: tuple[str, ...],
    storage_components: tuple[str, ...],
) -> tuple[Path | None, list[str]]:
    storage_relative = storage_relative_to_root(root_components, storage_components)
    storage_path = home.joinpath(*storage_components)
    root_parent_descriptor = open_directory_under_home(home, root.parent, create=True)
    if root_parent_descriptor is None:
        raise SnapshotError(f"unable to prepare the managed root parent: {root.parent}")
    root_name = root.name
    stage_name = ""
    stage_descriptor = -1
    backup_name: str | None = None
    preserved_storage_name: str | None = None
    storage_parent_descriptor = -1
    root_existed = False
    committed = False
    journal: dict[str, Any] | None = None
    journal_path: Path | None = None
    warnings: list[str] = []

    try:
        mounts = read_mount_ids()
        reject_mounted_tree(root, mounts)
        stage_name, stage_descriptor = create_temporary_directory(
            root_parent_descriptor,
            f".{root_name}.snapshot-stage-",
        )
        root_existed = entry_exists_at(root_parent_descriptor, root_name)
        extract_snapshot(snapshot, stage_descriptor)

        transaction_id = uuid.uuid4().hex
        if root_existed:
            backup_name = (
                f".{root_name}.pre-snapshot-restore-{snapshot.name}-"
                f"{uuid.uuid4().hex[:8]}"
            )
        if storage_relative is not None:
            preserved_storage_name = (
                f".{root_name}.snapshot-storage-{uuid.uuid4().hex}"
            )
        journal = {
            "schema_version": RECOVERY_JOURNAL_SCHEMA_VERSION,
            "transaction_id": transaction_id,
            "kind": "whole",
            "status": "prepared",
            "phase": "prepared",
            "created_at": dt.datetime.now(dt.timezone.utc).replace(
                microsecond=0
            ).isoformat().replace("+00:00", "Z"),
            "root": str(root),
            "root_existed": root_existed,
            "storage_path": str(storage_path),
            "storage_relative": list(storage_relative) if storage_relative else [],
            "snapshot_id": snapshot.name,
            "stage_name": stage_name,
            "backup_name": backup_name,
            "preserved_storage_name": preserved_storage_name,
            "failed_root_name": None,
        }
        journal_path = write_recovery_journal(home, journal)

        with blocked_snapshot_signals():
            try:
                update_recovery_journal(
                    home,
                    journal,
                    status="in_progress",
                    phase="storage_move_intent",
                )
                if storage_relative is not None:
                    storage_parent = home.joinpath(*storage_components[:-1])
                    storage_parent_descriptor = open_directory_under_home(
                        home,
                        storage_parent,
                        create=False,
                        private=True,
                    )
                    if storage_parent_descriptor is None:
                        raise SnapshotError("snapshot storage parent is missing")
                    reject_mounted_tree(storage_path, mounts)
                    reject_mount_boundary(storage_parent, storage_path, mounts)
                    trigger_test_failpoint("before_storage_move")
                    replace_entries_at(
                        storage_parent_descriptor,
                        storage_components[-1],
                        root_parent_descriptor,
                        preserved_storage_name,
                        "preserve snapshot storage",
                    )
                    trigger_test_failpoint("after_storage_move")
                    update_recovery_journal(
                        home,
                        journal,
                        phase="storage_moved",
                    )

                if root_existed:
                    update_recovery_journal(
                        home,
                        journal,
                        phase="root_backup_intent",
                    )
                    trigger_test_failpoint("before_root_backup")
                    replace_entries_at(
                        root_parent_descriptor,
                        root_name,
                        root_parent_descriptor,
                        backup_name,
                        "preserve the previous managed root",
                    )
                    trigger_test_failpoint("after_root_backup")
                    update_recovery_journal(
                        home,
                        journal,
                        phase="root_backed_up",
                    )

                update_recovery_journal(
                    home,
                    journal,
                    phase="root_replacement_intent",
                )
                trigger_test_failpoint("before_root_replacement")
                replace_entries_at(
                    root_parent_descriptor,
                    stage_name,
                    root_parent_descriptor,
                    root_name,
                    "replace the managed root",
                )
                stage_name = ""
                trigger_test_failpoint("after_root_replacement")
                update_recovery_journal(
                    home,
                    journal,
                    phase="root_replaced",
                )

                if storage_relative is not None:
                    new_root_descriptor = open_child_directory(
                        root_parent_descriptor,
                        root_name,
                    )
                    try:
                        destination_parent = nested_storage_parent(
                            new_root_descriptor,
                            storage_relative,
                            create=True,
                        )
                        if destination_parent is None:
                            raise SnapshotError(
                                "unable to prepare nested snapshot storage"
                            )
                        try:
                            reject_mount_boundary(
                                root.parent,
                                storage_path,
                                mounts,
                            )
                            update_recovery_journal(
                                home,
                                journal,
                                phase="storage_relocation_intent",
                            )
                            trigger_test_failpoint("before_storage_relocation")
                            replace_entries_at(
                                root_parent_descriptor,
                                preserved_storage_name,
                                destination_parent,
                                storage_relative[-1],
                                "relocate snapshot storage",
                            )
                            trigger_test_failpoint("after_storage_relocation")
                        finally:
                            os.close(destination_parent)
                    finally:
                        os.close(new_root_descriptor)
                    update_recovery_journal(
                        home,
                        journal,
                        phase="storage_relocated",
                    )

                if backup_name is not None and entry_exists_at(
                    root_parent_descriptor,
                    backup_name,
                ):
                    set_directory_mode(root_parent_descriptor, backup_name, 0o700)
                raise_pending_snapshot_signal()

                # This durable journal update is the whole-tree commit point.
                # Once it is written, recovery must never roll the root back.
                update_recovery_journal(
                    home,
                    journal,
                    status="committed",
                    phase="committed",
                    backup_path=(
                        str(root.parent / backup_name)
                        if backup_name is not None
                        else None
                    ),
                )
                committed = True
                trigger_test_failpoint("after_commit")
                raise_pending_snapshot_signal()
            except BaseException as error:
                committed_on_disk = committed
                if journal_path is not None and journal is not None:
                    try:
                        committed_on_disk = (
                            read_recovery_journal(journal_path).get("status")
                            == "committed"
                        )
                    except SnapshotError:
                        committed_on_disk = committed
                if committed_on_disk:
                    update_recovery_journal(
                        home,
                        journal,
                        status="committed",
                        phase="committed",
                        recovery_error=str(error),
                    )
                    if isinstance(error, SnapshotInterrupted):
                        raise SnapshotError(
                            "snapshot restore committed before interruption; "
                            f"the recovery journal was retained at {journal_path}",
                            error.status,
                        ) from error
                    raise SnapshotError(
                        "snapshot restore committed but a post-commit operation failed; "
                        f"the recovery journal was retained at {journal_path}: {error}"
                    ) from error

                try:
                    recovery_warnings = recover_whole_transaction(
                        home,
                        journal,
                        journal_path,
                        root,
                    )
                    warnings.extend(recovery_warnings)
                except BaseException as recovery_error:
                    if journal is not None:
                        update_recovery_journal(
                            home,
                            journal,
                            status="recovery_required",
                            phase="recovery_required",
                            recovery_error=str(recovery_error),
                        )
                    artifacts = recovery_artifact_paths(journal or {})
                    artifact_detail = ""
                    if artifacts:
                        artifact_detail = "; recovery data retained at " + ", ".join(
                            artifacts
                        )
                    raise SnapshotError(
                        "snapshot restore failed and rollback was incomplete; "
                        "durable recovery could not "
                        f"complete{artifact_detail}: {recovery_error}"
                    ) from error
                if isinstance(error, (SnapshotError, SnapshotInterrupted, KeyboardInterrupt)):
                    raise
                raise SnapshotError(f"unable to restore snapshot: {error}") from error
    finally:
        if stage_descriptor >= 0:
            os.close(stage_descriptor)
        if stage_name:
            try:
                remove_entry_at(root_parent_descriptor, stage_name)
            except SnapshotError:
                pass
        if storage_parent_descriptor >= 0:
            os.close(storage_parent_descriptor)
        os.close(root_parent_descriptor)

    if not committed:
        raise SnapshotError("snapshot restore did not reach a commit point")
    backup_path = root.parent / backup_name if backup_name is not None else None
    if journal_path is not None:
        warnings.append(f"Recovery journal retained at {journal_path}.")
    return backup_path, warnings


def restore_snapshot(snapshot_id: str, paths: list[str], assume_yes: bool) -> int:
    if not assume_yes:
        raise SnapshotUsageError("snapshot restore requires explicit confirmation")

    home = home_directory()
    root = managed_root(home, require_discovery=True)
    recovery_messages = recover_pending_transactions(home, root)
    validate_runtime_control_paths(root, home)
    layout = storage_layout(home)
    root_components = home_relative_components(root, home)
    storage_components = layout.components
    storage_relative = storage_relative_to_root(root_components, storage_components)
    storage_descriptor = open_storage_directory(layout, home, create=False)
    if storage_descriptor is None:
        raise SnapshotError(f"snapshot storage does not exist: {layout.path}")

    snapshot: LoadedSnapshot | None = None
    try:
        snapshot = load_snapshot(snapshot_id, storage_descriptor)
        trigger_test_failpoint("after_snapshot_load")
        snapshot_context_error(snapshot, home, root, storage_relative)
        requested = selected_paths(paths)
        storage_overlap = selected_path_overlaps_storage(requested, storage_relative)
        if storage_overlap is not None:
            raise SnapshotError(
                "the selected snapshot path overlaps the snapshot storage directory: "
                f"{terminal_safe_text(storage_overlap)}",
                64,
            )
        if requested:
            root_descriptor = open_directory_under_home(home, root, create=True)
            if root_descriptor is None:
                raise SnapshotError(f"unable to prepare the managed root: {root}")
            try:
                warnings = selective_restore(
                    home,
                    snapshot,
                    root,
                    root_descriptor,
                    requested,
                )
            finally:
                os.close(root_descriptor)
            for message in recovery_messages:
                print(f"warning: {message}", file=sys.stderr)
            print(
                f"Restored selected paths from snapshot {snapshot.name} into {root}."
            )
            sys.stdout.flush()
            for warning in warnings:
                print(f"warning: {warning}", file=sys.stderr)
            return 0

        backup_path, warnings = restore_whole_tree(
            snapshot,
            home,
            root,
            root_components,
            storage_components,
        )
        for message in recovery_messages:
            print(f"warning: {message}", file=sys.stderr)
        print(f"Restored snapshot {snapshot.name} into {root}.")
        if backup_path is not None:
            print(f"Previous managed directory retained at {backup_path}.")
        sys.stdout.flush()
        for warning in warnings:
            print(f"warning: {warning}", file=sys.stderr)
        return 0
    finally:
        if snapshot is not None:
            snapshot.close()
        os.close(storage_descriptor)


def recover_snapshots() -> int:
    home = home_directory()
    messages = recover_pending_transactions(home)
    if not messages:
        print("No pending snapshot recovery transactions.")
        return 0
    for message in messages:
        print(message)
    return 0


def recovery_status_output() -> int:
    home = home_directory()
    print(json.dumps(snapshot_recovery_status(home), indent=2, sort_keys=True))
    return 0


def preflight_snapshot() -> int:
    home = home_directory()
    root = managed_root(home, require_discovery=True)
    validate_runtime_control_paths(root, home)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = SnapshotArgumentParser(prog="snapshot")
    subparsers = parser.add_subparsers(dest="command", required=True)

    create = subparsers.add_parser("create")
    create.add_argument("label", nargs="?")

    subparsers.add_parser("list")
    subparsers.add_parser("preflight")
    subparsers.add_parser("recover")
    subparsers.add_parser("recovery-status")

    diff = subparsers.add_parser("diff")
    diff.add_argument("first")
    diff.add_argument("second")

    restore = subparsers.add_parser("restore")
    restore.add_argument("snapshot")
    restore.add_argument("--path", action="append", default=[])
    restore.add_argument("--yes", action="store_true")
    return parser


def snapshot_signal_handler(signal_number: int, _frame: Any) -> None:
    global _PENDING_SNAPSHOT_SIGNAL
    if _PENDING_SNAPSHOT_SIGNAL is None:
        _PENDING_SNAPSHOT_SIGNAL = signal_number


def main(argv: list[str]) -> int:
    global _PENDING_SNAPSHOT_SIGNAL
    _PENDING_SNAPSHOT_SIGNAL = None
    previous_sigterm = signal.getsignal(signal.SIGTERM)
    previous_sighup = signal.getsignal(signal.SIGHUP)
    previous_sigint = signal.getsignal(signal.SIGINT)
    signal.signal(signal.SIGTERM, snapshot_signal_handler)
    signal.signal(signal.SIGHUP, snapshot_signal_handler)
    signal.signal(signal.SIGINT, snapshot_signal_handler)
    try:
        parser = build_parser()
        try:
            arguments = parser.parse_args(argv)
        except SnapshotUsageError as error:
            parser.print_usage(sys.stderr)
            return fail(str(error), 64)
        try:
            if arguments.command == "create":
                return create_snapshot(arguments.label)
            if arguments.command == "list":
                return list_snapshots()
            if arguments.command == "preflight":
                return preflight_snapshot()
            if arguments.command == "recover":
                return recover_snapshots()
            if arguments.command == "recovery-status":
                return recovery_status_output()
            if arguments.command == "diff":
                return diff_snapshots(arguments.first, arguments.second)
            if arguments.command == "restore":
                return restore_snapshot(arguments.snapshot, arguments.path, arguments.yes)
        except SnapshotInterrupted as error:
            return fail(f"interrupted by signal {error.signal_number}", error.status)
        except SnapshotError as error:
            return fail(str(error), getattr(error, "status", 1))
        except BrokenPipeError:
            # Publication already completed before stdout is written. Redirect
            # the closed stream so interpreter shutdown cannot report a second
            # broken-pipe error or trigger any snapshot cleanup.
            try:
                devnull = os.open(os.devnull, os.O_WRONLY)
                os.dup2(devnull, sys.stdout.fileno())
                os.close(devnull)
            except OSError:
                pass
            return 141
        except OSError as error:
            return fail(f"filesystem operation failed: {error}", 1)
        except (TypeError, ValueError) as error:
            return fail(f"invalid snapshot data: {error}", 1)
        except KeyboardInterrupt:
            return fail("interrupted", 130)
        return fail("unknown snapshot operation", 64)
    finally:
        signal.signal(signal.SIGTERM, previous_sigterm)
        signal.signal(signal.SIGHUP, previous_sighup)
        signal.signal(signal.SIGINT, previous_sigint)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
