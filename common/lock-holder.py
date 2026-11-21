#!/usr/bin/env python3

# SPDX-License-Identifier: MIT

import ctypes
import errno
import os
import secrets
import select
import signal
import stat
import sys
import time
from dataclasses import dataclass
from enum import Enum
from typing import Callable


STATUS_SCHEMA_VERSION = 3
STATUS_LINE_COUNT = 12
DECISION_COMMITTED = "committed"
DECISION_CANCELLED = "cancelled"
DECISION_UNKNOWN = "unknown"
DECISION_RESOLUTION_ATTEMPTS = 20
DECISION_RESOLUTION_DELAY = 0.01
CANCELLATION_REQUESTED = False
CANCELLATION_ABORT_REQUESTED = False
CANCELLATION_DECISION_STATE = DECISION_UNKNOWN
WATCHDOG_CANCELLATION_REQUESTED = False
WATCHDOG_DECISION_STATE = DECISION_UNKNOWN
DECISION_PATH: str | None = None
RENAME_NOREPLACE = 1
_RENAMEAT2 = None


def fail(message: str) -> None:
    print(f"lock-holder: {message}", file=sys.stderr)
    raise SystemExit(1)


class DecisionPublicationError(OSError):
    """The decision was published, but its directory sync failed."""

    def __init__(self, decision: str, cause: BaseException) -> None:
        if isinstance(cause, OSError):
            super().__init__(cause.errno, cause.strerror, cause.filename)
        else:
            super().__init__(str(cause))
        self.decision = decision
        self.cause = cause


def renameat2(
    source_parent: int,
    source_name: str,
    destination_parent: int,
    destination_name: str,
    flags: int,
) -> None:
    """Perform a Linux renameat2 operation without following path components."""
    global _RENAMEAT2

    if _RENAMEAT2 is None:
        try:
            libc = ctypes.CDLL(None, use_errno=True)
            function = libc.renameat2
        except (AttributeError, OSError) as error:
            raise OSError(
                errno.ENOSYS,
                "renameat2 is unavailable",
            ) from error
        function.argtypes = [
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        ]
        function.restype = ctypes.c_int
        _RENAMEAT2 = function

    result = _RENAMEAT2(
        source_parent,
        os.fsencode(source_name),
        destination_parent,
        os.fsencode(destination_name),
        flags,
    )
    if result != 0:
        error_number = ctypes.get_errno()
        raise OSError(
            error_number,
            os.strerror(error_number),
            f"{source_name} -> {destination_name}",
        )


def rename_noreplace(
    source_parent: int,
    source_name: str,
    destination_parent: int,
    destination_name: str,
) -> None:
    renameat2(
        source_parent,
        source_name,
        destination_parent,
        destination_name,
        RENAME_NOREPLACE,
    )


def write_all(descriptor: int, content: bytes) -> None:
    offset = 0
    while offset < len(content):
        written = os.write(descriptor, content[offset:])
        if written <= 0:
            raise OSError(errno.EIO, "unable to write the lock decision")
        offset += written


def open_decision_parent(path: str) -> tuple[int, str]:
    """Open the decision directory without following path components."""
    absolute = os.path.abspath(path)
    name = os.path.basename(absolute)
    parent_path = os.path.dirname(absolute)
    if not name or not parent_path or name in {".", ".."}:
        raise OSError(errno.EINVAL, f"invalid lock decision path: {path}")

    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
    components = [component for component in parent_path.split(os.sep) if component]
    descriptor = os.open(os.sep, flags)
    try:
        for component in components:
            if component in {".", ".."}:
                raise OSError(errno.EINVAL, f"invalid lock decision path: {path}")
            try:
                metadata = os.stat(
                    component,
                    dir_fd=descriptor,
                    follow_symlinks=False,
                )
            except FileNotFoundError as error:
                raise OSError(
                    errno.ENOENT,
                    f"lock decision directory does not exist: {parent_path}",
                ) from error
            if stat.S_ISLNK(metadata.st_mode):
                raise OSError(
                    errno.ELOOP,
                    f"lock decision directory must not contain symbolic links: {parent_path}",
                )
            try:
                child = os.open(component, flags, dir_fd=descriptor)
            except OSError as error:
                if error.errno == errno.ELOOP:
                    raise OSError(
                        errno.ELOOP,
                        f"lock decision directory must not contain symbolic links: {parent_path}",
                    ) from error
                raise
            try:
                metadata = os.fstat(child)
                mode = stat.S_IMODE(metadata.st_mode)
                if metadata.st_uid not in {0, os.geteuid()}:
                    raise OSError(
                        errno.EPERM,
                        f"lock decision directory is not owned by the current user or root: {parent_path}",
                    )
                if mode & 0o022 and not (mode & stat.S_ISVTX):
                    raise OSError(
                        errno.EPERM,
                        f"lock decision directory is writable by another user: {parent_path}",
                    )
            except BaseException:
                os.close(child)
                raise
            os.close(descriptor)
            descriptor = child

        metadata = os.fstat(descriptor)
        mode = stat.S_IMODE(metadata.st_mode)
        if metadata.st_uid != os.geteuid():
            raise OSError(
                errno.EPERM,
                f"lock decision directory is not owned by the current user: {parent_path}",
            )
        if mode & 0o022:
            raise OSError(
                errno.EPERM,
                f"lock decision directory is writable by another user: {parent_path}",
            )
        return descriptor, name
    except BaseException:
        os.close(descriptor)
        raise


def read_decision_from_parent(parent: int, name: str) -> str:
    """Read a decision while holding its directory entry open.

    The returned state is always one of committed, cancelled, or unknown.
    Unknown deliberately covers a missing, malformed, or temporarily unreadable
    entry so callers cannot mistake an inspection failure for cancellation.
    """
    descriptor = -1
    try:
        try:
            descriptor = os.open(
                name,
                os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
                dir_fd=parent,
            )
        except OSError:
            return DECISION_UNKNOWN

        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or metadata.st_uid != os.geteuid()
            or stat.S_IMODE(metadata.st_mode) & 0o022
        ):
            return DECISION_UNKNOWN

        chunks: list[bytes] = []
        total = 0
        while total < 64:
            chunk = os.read(descriptor, 64 - total)
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        content = b"".join(chunks)
        if content == b"committed":
            return DECISION_COMMITTED
        if content == b"cancelled":
            return DECISION_CANCELLED
        return DECISION_UNKNOWN
    except OSError:
        return DECISION_UNKNOWN
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def read_decision(path: str) -> str:
    """Read and validate an atomically published lock decision."""
    try:
        parent, name = open_decision_parent(path)
    except OSError:
        return DECISION_UNKNOWN

    try:
        return read_decision_from_parent(parent, name)
    finally:
        os.close(parent)


def claim_decision(path: str, value: str) -> tuple[bool, str]:
    """Publish one complete decision as the single atomic winner.

    A private O_EXCL file is written and synced before it is published with
    RENAME_NOREPLACE. Contenders therefore never observe an empty or partially
    written decision, and exactly one publication can win.
    """
    if value not in {DECISION_COMMITTED, DECISION_CANCELLED}:
        raise ValueError(f"invalid lock decision: {value}")

    parent, name = open_decision_parent(path)
    temporary_name = ""
    descriptor = -1
    try:
        flags = (
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | os.O_CLOEXEC
            | os.O_NOFOLLOW
            | os.O_NONBLOCK
        )
        for _ in range(100):
            candidate = f"{name}.{os.getpid()}.{secrets.token_hex(16)}.tmp"
            try:
                descriptor = os.open(candidate, flags, 0o600, dir_fd=parent)
                temporary_name = candidate
                break
            except FileExistsError:
                continue
        if descriptor < 0:
            raise OSError(errno.EEXIST, "unable to create a lock decision candidate")

        write_all(descriptor, value.encode("ascii"))
        os.fchmod(descriptor, 0o600)
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1

        try:
            rename_noreplace(parent, temporary_name, parent, name)
        except FileExistsError:
            existing = read_decision_from_parent(parent, name)
            return False, existing
        try:
            os.fsync(parent)
        except OSError as error:
            # The successful rename is the publication point. A directory
            # fsync failure does not undo it, so the caller must continue to
            # treat this value as authoritative even if a later read fails.
            raise DecisionPublicationError(value, error) from error
        return True, value
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary_name:
            try:
                os.unlink(temporary_name, dir_fd=parent)
            except OSError:
                pass
        os.close(parent)


class MonitoringUnavailable(RuntimeError):
    pass


class AcquisitionCancelled(RuntimeError):
    pass


class AcquisitionDecisionUnknown(RuntimeError):
    """The decision could not be read or safely classified."""


class ProcessInspectionUnavailable(RuntimeError):
    """A process could not be inspected because of a transient failure."""


class ProcessObservation(Enum):
    ALIVE = "alive"
    EXITED = "exited"
    REPLACED = "replaced"
    STOPPED = "stopped"
    UNKNOWN = "unknown"


@dataclass(frozen=True)
class ProcessIdentity:
    start_time: int
    boot_id: str


@dataclass(frozen=True)
class LockStatus:
    installer_process_id: int
    installer_identity: ProcessIdentity
    wrapper_process_id: int
    wrapper_identity: ProcessIdentity
    supervisor_process_id: int
    supervisor_identity: ProcessIdentity
    worker_process_id: int
    worker_identity: ProcessIdentity
    watchdog_process_id: int
    watchdog_identity: ProcessIdentity


@dataclass
class MonitoredProcess:
    label: str
    process_id: int
    descriptor: int = -1
    identity: ProcessIdentity | None = None
    exited: bool = False
    pidfd_attempted: bool = False


def resolve_cancellation_decision(path: str | None) -> str:
    """Resolve the decision as committed, cancelled, or unknown.

    Both the ordinary helpers and the watchdog use this protocol. A single
    decision path is shared by commit and cancellation, so ``renameat2``
    decides the winner even when the signals arrive concurrently. An existing
    entry that cannot be read remains unknown; it is never inferred to be a
    cancellation request.
    """
    if not path:
        return DECISION_UNKNOWN

    for _ in range(DECISION_RESOLUTION_ATTEMPTS):
        decision = read_decision(path)
        if decision in {DECISION_COMMITTED, DECISION_CANCELLED}:
            return decision

        try:
            created, decision = claim_decision(path, DECISION_CANCELLED)
        except DecisionPublicationError as error:
            return error.decision
        except (OSError, ValueError):
            time.sleep(DECISION_RESOLUTION_DELAY)
            continue

        if created:
            return DECISION_CANCELLED
        if decision in {DECISION_COMMITTED, DECISION_CANCELLED}:
            return decision

        # The entry exists but could not be classified. Retry briefly in case
        # the failure was transient, then preserve the unknown state.
        time.sleep(DECISION_RESOLUTION_DELAY)

    return DECISION_UNKNOWN


def cancellation_decision_requested(path: str | None) -> bool:
    """Return true only when the authoritative decision is ``cancelled``.

    This compatibility helper intentionally does not collapse an unknown
    decision into cancellation. Callers that need to distinguish all three
    states should use :func:`resolve_cancellation_decision` directly.
    """
    return resolve_cancellation_decision(path) == DECISION_CANCELLED


def request_cancellation(_signal_number: int, _frame: object) -> None:
    global CANCELLATION_ABORT_REQUESTED
    global CANCELLATION_DECISION_STATE
    global CANCELLATION_REQUESTED

    # USR2 is an acquisition-only cancellation signal. Cancellation and commit
    # publish to the same decision path, so only one side can win. A committed
    # decision is checked first so every later USR2 is harmless. An unknown
    # state aborts conservatively but remains distinct from cancellation.
    CANCELLATION_DECISION_STATE = resolve_cancellation_decision(DECISION_PATH)
    CANCELLATION_REQUESTED = (
        CANCELLATION_DECISION_STATE == DECISION_CANCELLED
    )
    CANCELLATION_ABORT_REQUESTED = (
        CANCELLATION_DECISION_STATE != DECISION_COMMITTED
    )


def request_watchdog_cancellation(_signal_number: int, _frame: object) -> None:
    global WATCHDOG_CANCELLATION_REQUESTED
    global WATCHDOG_DECISION_STATE

    # The watchdog observes the same atomic decision as the other helpers, but
    # it must never turn cancellation into an exception: the watchdog retains
    # the locked descriptor until the installer has actually terminated.
    WATCHDOG_DECISION_STATE = resolve_cancellation_decision(DECISION_PATH)
    WATCHDOG_CANCELLATION_REQUESTED = (
        WATCHDOG_DECISION_STATE == DECISION_CANCELLED
    )


def configure_signal_handlers(allow_cancellation: bool) -> None:
    # The installer owns shutdown policy. The lock processes must survive a
    # group-directed TERM/HUP/INT long enough for installer cleanup to finish.
    for signal_number in (
        signal.SIGINT,
        signal.SIGTERM,
        signal.SIGHUP,
        signal.SIGUSR1,
    ):
        signal.signal(signal_number, signal.SIG_IGN)

    if allow_cancellation:
        signal.signal(signal.SIGUSR2, request_cancellation)
    else:
        signal.signal(signal.SIGUSR2, signal.SIG_IGN)


def find_lock_descriptor(path: str) -> int:
    absolute = os.path.abspath(path)
    try:
        path_metadata = os.lstat(absolute)
    except OSError as error:
        fail(str(error))

    if stat.S_ISLNK(path_metadata.st_mode):
        fail(f"lock path must not be a symbolic link: {path}")
    if not stat.S_ISREG(path_metadata.st_mode):
        fail(f"lock path is not a regular file: {path}")
    if path_metadata.st_nlink != 1:
        fail(f"lock path has multiple hard links: {path}")
    if path_metadata.st_uid != os.geteuid():
        fail(f"lock path is not owned by the current user: {path}")

    candidates = []
    for entry in os.listdir("/proc/self/fd"):
        try:
            descriptor = int(entry)
            metadata = os.fstat(descriptor)
        except (OSError, ValueError):
            continue
        if metadata.st_dev != path_metadata.st_dev or metadata.st_ino != path_metadata.st_ino:
            continue
        if not stat.S_ISREG(metadata.st_mode):
            continue
        candidates.append(descriptor)

    if len(candidates) != 1:
        fail(f"unable to identify the acquired lock descriptor: {path}")

    descriptor = candidates[0]
    metadata = os.fstat(descriptor)
    if metadata.st_nlink != 1:
        fail(f"lock path has multiple hard links: {path}")
    if metadata.st_uid != os.geteuid():
        fail(f"lock path is not owned by the current user: {path}")

    os.fchmod(descriptor, 0o600)
    try:
        current_metadata = os.lstat(absolute)
    except OSError as error:
        fail(str(error))
    if stat.S_ISLNK(current_metadata.st_mode):
        fail(f"lock path must not be a symbolic link: {path}")
    if current_metadata.st_dev != metadata.st_dev or current_metadata.st_ino != metadata.st_ino:
        fail(f"lock path changed while it was being acquired: {path}")
    return descriptor


def write_status(path: str, content: str) -> None:
    absolute = os.path.abspath(path)
    name = os.path.basename(absolute)
    parent_path = os.path.dirname(absolute)
    if not name or not parent_path:
        fail(f"invalid lock status path: {path}")

    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
    try:
        parent = os.open(parent_path, flags)
    except OSError as error:
        if error.errno == errno.ELOOP:
            fail(f"lock status directory must not be a symbolic link: {parent_path}")
        fail(str(error))

    descriptor = -1
    temporary_name = f".{name}.{os.getpid()}.tmp"
    try:
        metadata = os.fstat(parent)
        mode = stat.S_IMODE(metadata.st_mode)
        if metadata.st_uid != os.geteuid():
            fail(f"lock status directory is not owned by the current user: {parent_path}")
        if mode & 0o022:
            fail(f"lock status directory is writable by another user: {parent_path}")

        file_flags = (
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | os.O_CLOEXEC
            | os.O_NOFOLLOW
            | os.O_NONBLOCK
        )
        try:
            descriptor = os.open(temporary_name, file_flags, 0o600, dir_fd=parent)
        except OSError as error:
            if error.errno == errno.ELOOP:
                fail(f"lock status path must not be a symbolic link: {path}")
            fail(str(error))

        payload = content.encode("utf-8")
        offset = 0
        while offset < len(payload):
            offset += os.write(descriptor, payload[offset:])
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        os.replace(temporary_name, name, src_dir_fd=parent, dst_dir_fd=parent)
        os.fsync(parent)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            os.unlink(temporary_name, dir_fd=parent)
        except FileNotFoundError:
            pass
        os.close(parent)


def remove_status(path: str) -> None:
    absolute = os.path.abspath(path)
    name = os.path.basename(absolute)
    parent_path = os.path.dirname(absolute)
    if not name or not parent_path:
        return

    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
    try:
        parent = os.open(parent_path, flags)
    except OSError:
        return

    try:
        try:
            metadata = os.stat(name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            return
        if not stat.S_ISREG(metadata.st_mode):
            return
        if metadata.st_nlink != 1 or metadata.st_uid != os.geteuid():
            return
        try:
            os.unlink(name, dir_fd=parent)
        except FileNotFoundError:
            pass
    finally:
        os.close(parent)


def remove_decision(path: str | None) -> None:
    """Remove an atomically published decision after installer termination."""
    if path:
        remove_status(path)


def parse_process_identity(value: str) -> ProcessIdentity | None:
    try:
        boot_id, start_time = value.rsplit(":", 1)
        parsed_start_time = int(start_time)
    except (AttributeError, ValueError):
        return None
    if not boot_id or parsed_start_time <= 0:
        return None
    return ProcessIdentity(parsed_start_time, boot_id)


def read_lock_status(path: str) -> LockStatus | None:
    absolute = os.path.abspath(path)
    name = os.path.basename(absolute)
    parent_path = os.path.dirname(absolute)
    if not name or not parent_path:
        return None

    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
    try:
        parent = os.open(parent_path, flags)
    except OSError:
        return None

    descriptor = -1
    try:
        try:
            metadata = os.stat(name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            return None
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or metadata.st_uid != os.geteuid()
        ):
            return None

        descriptor = os.open(
            name,
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
            dir_fd=parent,
        )
        content = os.read(descriptor, 8193).decode("utf-8", errors="strict")
        lines = content.splitlines()
        if len(lines) != STATUS_LINE_COUNT:
            return None
        if lines[10] != f"schema={STATUS_SCHEMA_VERSION}" or lines[11] != "ready=1":
            return None

        try:
            supervisor_process_id = int(lines[0])
            worker_process_id = int(lines[1])
            wrapper_process_id = int(lines[5])
            installer_process_id = int(lines[7])
            watchdog_process_id = int(lines[8])
        except ValueError:
            return None
        if min(
            supervisor_process_id,
            worker_process_id,
            wrapper_process_id,
            installer_process_id,
            watchdog_process_id,
        ) <= 1:
            return None

        installer_identity = parse_process_identity(lines[2])
        supervisor_identity = parse_process_identity(lines[3])
        worker_identity = parse_process_identity(lines[4])
        wrapper_identity = parse_process_identity(lines[6])
        watchdog_identity = parse_process_identity(lines[9])
        if any(
            identity is None
            for identity in (
                installer_identity,
                supervisor_identity,
                worker_identity,
                wrapper_identity,
                watchdog_identity,
            )
        ):
            return None

        return LockStatus(
            installer_process_id=installer_process_id,
            installer_identity=installer_identity,
            wrapper_process_id=wrapper_process_id,
            wrapper_identity=wrapper_identity,
            supervisor_process_id=supervisor_process_id,
            supervisor_identity=supervisor_identity,
            worker_process_id=worker_process_id,
            worker_identity=worker_identity,
            watchdog_process_id=watchdog_process_id,
            watchdog_identity=watchdog_identity,
        )
    except (OSError, UnicodeError):
        return None
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(parent)


def read_status_identity(path: str) -> ProcessIdentity | None:
    status = read_lock_status(path)
    if status is None:
        return None
    return status.installer_identity


def encode_process_identity(identity: ProcessIdentity) -> str:
    return f"{identity.boot_id}:{identity.start_time}"


def read_boot_id() -> str | None:
    try:
        with open("/proc/sys/kernel/random/boot_id", "r", encoding="ascii") as boot_file:
            return boot_file.read().strip()
    except (OSError, UnicodeError):
        return None


def read_process_details_checked(process_id: int) -> tuple[str, int, int] | None:
    """Read process details, distinguishing absence from transient failure."""
    try:
        with open(f"/proc/{process_id}/stat", "r", encoding="ascii") as stat_file:
            status = stat_file.read()
    except (FileNotFoundError, ProcessLookupError):
        return None
    except (OSError, UnicodeError) as error:
        raise ProcessInspectionUnavailable(
            f"unable to inspect process {process_id}: {error}"
        ) from error

    command_end = status.rfind(")")
    if command_end < 0:
        raise ProcessInspectionUnavailable(
            f"unable to parse process {process_id} details"
        )
    fields = status[command_end + 1 :].split()
    if len(fields) <= 19:
        raise ProcessInspectionUnavailable(
            f"unable to parse process {process_id} details"
        )
    try:
        return fields[0], int(fields[1]), int(fields[19])
    except ValueError as error:
        raise ProcessInspectionUnavailable(
            f"unable to parse process {process_id} details"
        ) from error


def read_process_details(process_id: int) -> tuple[str, int, int] | None:
    try:
        return read_process_details_checked(process_id)
    except ProcessInspectionUnavailable:
        return None


def read_process_state(process_id: int) -> tuple[str, int] | None:
    details = read_process_details(process_id)
    if details is None:
        return None
    state, _parent_process_id, start_time = details
    return state, start_time


def capture_process_identity_observation(
    process_id: int,
) -> tuple[ProcessIdentity | None, ProcessObservation]:
    """Capture an identity without conflating absence and read failure."""
    try:
        details = read_process_details_checked(process_id)
    except ProcessInspectionUnavailable:
        return None, ProcessObservation.UNKNOWN
    if details is None:
        return None, ProcessObservation.EXITED

    state, _parent_process_id, start_time = details
    if state == "Z":
        return None, ProcessObservation.EXITED
    boot_id = read_boot_id()
    if not boot_id:
        return None, ProcessObservation.UNKNOWN
    identity = ProcessIdentity(start_time, boot_id)
    if state in {"T", "t"}:
        return identity, ProcessObservation.STOPPED
    return identity, ProcessObservation.ALIVE


def capture_process_identity(process_id: int) -> ProcessIdentity | None:
    identity, observation = capture_process_identity_observation(process_id)
    if observation not in {
        ProcessObservation.ALIVE,
        ProcessObservation.STOPPED,
    }:
        return None
    return identity


def wait_for_captured_process_identity(
    process_id: int,
    timeout: float = 1.0,
) -> ProcessIdentity | None:
    """Retry unknown identity reads until success or definitive exit."""
    deadline = time.monotonic() + timeout
    while True:
        identity, observation = capture_process_identity_observation(process_id)
        if observation in {
            ProcessObservation.ALIVE,
            ProcessObservation.STOPPED,
        }:
            return identity
        if observation in {
            ProcessObservation.EXITED,
            ProcessObservation.REPLACED,
        }:
            return None
        if time.monotonic() >= deadline:
            return None
        time.sleep(0.01)


def observe_process_identity(
    process_id: int,
    identity: ProcessIdentity,
) -> ProcessObservation:
    """Classify a process without treating a transient read failure as exit."""
    try:
        details = read_process_details_checked(process_id)
    except ProcessInspectionUnavailable:
        return ProcessObservation.UNKNOWN
    if details is None:
        return ProcessObservation.EXITED

    state, _parent_process_id, start_time = details
    if state == "Z":
        return ProcessObservation.EXITED
    if start_time != identity.start_time:
        return ProcessObservation.REPLACED

    boot_id = read_boot_id()
    if boot_id is None:
        return ProcessObservation.UNKNOWN
    if boot_id != identity.boot_id:
        return ProcessObservation.REPLACED
    if state in {"T", "t"}:
        return ProcessObservation.STOPPED
    return ProcessObservation.ALIVE


def process_matches_identity(process_id: int, identity: ProcessIdentity) -> bool:
    return observe_process_identity(process_id, identity) in {
        ProcessObservation.ALIVE,
        ProcessObservation.STOPPED,
    }


def observe_parent_relationship(
    process_id: int,
    expected_parent: int,
) -> ProcessObservation:
    """Classify a parent relationship without conflating read failure."""
    try:
        details = read_process_details_checked(process_id)
    except ProcessInspectionUnavailable:
        return ProcessObservation.UNKNOWN
    if details is None:
        return ProcessObservation.EXITED

    state, parent_process_id, _start_time = details
    if state == "Z":
        return ProcessObservation.EXITED
    if parent_process_id != expected_parent:
        return ProcessObservation.REPLACED
    if state in {"T", "t"}:
        return ProcessObservation.STOPPED
    return ProcessObservation.ALIVE


def process_parent_matches(process_id: int, expected_parent: int) -> bool:
    return (
        observe_parent_relationship(process_id, expected_parent)
        == ProcessObservation.ALIVE
    )


def open_verified_pidfd(
    process_id: int,
    identity: ProcessIdentity,
) -> int:
    """Open a pidfd only for the process with the recorded identity."""
    observation = observe_process_identity(process_id, identity)
    if observation in {
        ProcessObservation.EXITED,
        ProcessObservation.REPLACED,
        ProcessObservation.UNKNOWN,
    }:
        return -1
    try:
        descriptor = os.pidfd_open(process_id)
    except (AttributeError, OSError):
        return -1

    observation = observe_process_identity(process_id, identity)
    if observation in {
        ProcessObservation.EXITED,
        ProcessObservation.REPLACED,
        ProcessObservation.UNKNOWN,
    }:
        try:
            os.close(descriptor)
        except OSError:
            pass
        return -1
    return descriptor


def signal_process_by_identity(
    process_id: int,
    identity: ProcessIdentity,
    signal_number: int,
) -> bool:
    """Signal a process without targeting a replacement PID.

    A pidfd is preferred because it remains bound to the original process.
    The raw-PID fallback is retained for systems without pidfd support and
    verifies the recorded identity immediately before sending the signal.
    """
    observation = observe_process_identity(process_id, identity)
    if observation in {
        ProcessObservation.EXITED,
        ProcessObservation.REPLACED,
    }:
        return False
    if observation == ProcessObservation.UNKNOWN:
        raise MonitoringUnavailable(
            f"unable to verify process {process_id} before signaling"
        )

    descriptor = open_verified_pidfd(process_id, identity)
    if descriptor >= 0:
        try:
            if hasattr(signal, "pidfd_send_signal"):
                try:
                    signal.pidfd_send_signal(descriptor, signal_number)
                    return True
                except ProcessLookupError:
                    return False
                except OSError:
                    pass
        finally:
            try:
                os.close(descriptor)
            except OSError:
                pass

    observation = observe_process_identity(process_id, identity)
    if observation in {
        ProcessObservation.EXITED,
        ProcessObservation.REPLACED,
    }:
        return False
    if observation == ProcessObservation.UNKNOWN:
        raise MonitoringUnavailable(
            f"unable to verify process {process_id} before signaling"
        )
    try:
        os.kill(process_id, signal_number)
        return True
    except ProcessLookupError:
        return False
    except OSError as error:
        raise MonitoringUnavailable(
            f"unable to signal process {process_id}: {error}"
        ) from error


def resume_process(process_id: int, identity: ProcessIdentity) -> bool:
    """Resume a stopped process after verifying its identity."""
    observation = observe_process_identity(process_id, identity)
    if observation in {
        ProcessObservation.EXITED,
        ProcessObservation.REPLACED,
    }:
        return False
    if observation == ProcessObservation.UNKNOWN:
        raise MonitoringUnavailable(
            f"unable to verify stopped process {process_id}"
        )
    if observation != ProcessObservation.STOPPED:
        return True
    return signal_process_by_identity(
        process_id,
        identity,
        signal.SIGCONT,
    )


def wait_for_process_identity(
    process_id: int,
    expected_identity: ProcessIdentity,
    timeout: float = 1.0,
) -> bool:
    """Wait for an expected identity without treating unknown as exit."""
    deadline = time.monotonic() + timeout
    while True:
        observation = observe_process_identity(process_id, expected_identity)
        if observation in {
            ProcessObservation.ALIVE,
            ProcessObservation.STOPPED,
        }:
            if observation == ProcessObservation.STOPPED:
                try:
                    resume_process(process_id, expected_identity)
                except MonitoringUnavailable:
                    pass
            return True
        if observation in {
            ProcessObservation.EXITED,
            ProcessObservation.REPLACED,
        }:
            return False
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.01)


def wait_for_parent_relationship(
    process_id: int,
    expected_parent: int,
    expected_identity: ProcessIdentity | None = None,
    timeout: float = 1.0,
) -> bool:
    """Retry unknown relationship reads without accepting a replacement."""
    deadline = time.monotonic() + timeout
    while True:
        unknown = False
        if expected_identity is not None:
            identity_observation = observe_process_identity(
                process_id,
                expected_identity,
            )
            if identity_observation in {
                ProcessObservation.EXITED,
                ProcessObservation.REPLACED,
            }:
                return False
            if identity_observation == ProcessObservation.UNKNOWN:
                unknown = True
            if identity_observation == ProcessObservation.STOPPED:
                try:
                    resume_process(process_id, expected_identity)
                except MonitoringUnavailable:
                    unknown = True

        parent_observation = observe_parent_relationship(
            process_id,
            expected_parent,
        )
        if parent_observation in {
            ProcessObservation.EXITED,
            ProcessObservation.REPLACED,
        }:
            return False
        if parent_observation == ProcessObservation.STOPPED:
            if expected_identity is not None:
                try:
                    resume_process(process_id, expected_identity)
                except MonitoringUnavailable:
                    unknown = True
        if parent_observation == ProcessObservation.ALIVE and not unknown:
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.01)


def inspect_lock_status(
    path: str,
    wrapper_process_id: int,
    installer_process_id: int,
    installer_identity: ProcessIdentity,
    require_watchdog_parent: bool = True,
) -> tuple[LockStatus | None, bool]:
    """Inspect a status file without conflating unknown and invalid state.

    The second return value reports a definitive integrity failure. A
    transient ``/proc`` failure returns ``(None, False)`` so callers can retry
    instead of treating an unknown observation as helper death.
    """
    status = read_lock_status(path)
    if status is None:
        return None, True
    if status.wrapper_process_id != wrapper_process_id:
        return None, True
    if status.installer_process_id != installer_process_id:
        return None, True
    if status.installer_identity != installer_identity:
        return None, True

    identity_checks = [
        (status.wrapper_process_id, status.wrapper_identity),
        (status.supervisor_process_id, status.supervisor_identity),
        (status.worker_process_id, status.worker_identity),
        (status.watchdog_process_id, status.watchdog_identity),
        (installer_process_id, installer_identity),
    ]
    parent_checks = [
        (status.wrapper_process_id, installer_process_id),
        (status.supervisor_process_id, status.wrapper_process_id),
        (status.worker_process_id, status.supervisor_process_id),
    ]
    if require_watchdog_parent:
        parent_checks.append(
            (status.watchdog_process_id, status.supervisor_process_id)
        )

    unknown = False
    for process_id, identity in identity_checks:
        observation = observe_process_identity(process_id, identity)
        if observation in {
            ProcessObservation.EXITED,
            ProcessObservation.REPLACED,
        }:
            return None, True
        if observation in {
            ProcessObservation.UNKNOWN,
            ProcessObservation.STOPPED,
        }:
            unknown = True

    for process_id, expected_parent in parent_checks:
        observation = observe_parent_relationship(process_id, expected_parent)
        if observation in {
            ProcessObservation.EXITED,
            ProcessObservation.REPLACED,
        }:
            return None, True
        if observation in {
            ProcessObservation.UNKNOWN,
            ProcessObservation.STOPPED,
        }:
            unknown = True

    if unknown:
        return None, False
    return status, False


def validate_lock_status(
    path: str,
    wrapper_process_id: int,
    installer_process_id: int,
    installer_identity: ProcessIdentity,
    require_watchdog_parent: bool = True,
) -> LockStatus | None:
    status, _definitive_failure = inspect_lock_status(
        path,
        wrapper_process_id,
        installer_process_id,
        installer_identity,
        require_watchdog_parent,
    )
    return status


class ProcessMonitor:
    def __init__(
        self,
        processes: list[tuple[str, int] | tuple[str, int, ProcessIdentity]],
    ) -> None:
        self.targets: list[MonitoredProcess] = []
        self.poller = select.poll()
        self.descriptor_count = 0

        for process in processes:
            label, process_id = process[0], process[1]
            expected_identity = process[2] if len(process) == 3 else None
            target = MonitoredProcess(label, process_id)

            if expected_identity is not None:
                target.identity = expected_identity
                observation = observe_process_identity(process_id, expected_identity)
                if observation in {
                    ProcessObservation.EXITED,
                    ProcessObservation.REPLACED,
                }:
                    target.exited = True
                    self.targets.append(target)
                    continue
                if observation == ProcessObservation.UNKNOWN:
                    # Do not bind a pidfd until the recorded identity has been
                    # observed. A later successful observation may safely open
                    # one; an unknown observation is never treated as exit.
                    self.targets.append(target)
                    continue
            else:
                target.identity = capture_process_identity(process_id)

            target.pidfd_attempted = True
            try:
                target.descriptor = os.pidfd_open(process_id)
            except ProcessLookupError:
                target.exited = True
            except (AttributeError, OSError) as error:
                if target.identity is None:
                    raise MonitoringUnavailable(
                        f"unable to monitor {label} process {process_id}: {error}"
                    ) from error
            if target.descriptor >= 0:
                if target.identity is not None:
                    observation = observe_process_identity(
                        process_id,
                        target.identity,
                    )
                    if observation in {
                        ProcessObservation.EXITED,
                        ProcessObservation.REPLACED,
                    }:
                        os.close(target.descriptor)
                        target.descriptor = -1
                        target.exited = True
                    elif observation == ProcessObservation.UNKNOWN:
                        # The pidfd might have been opened after PID reuse. Use
                        # identity polling until the process can be verified.
                        os.close(target.descriptor)
                        target.descriptor = -1
                    else:
                        self.poller.register(target.descriptor, select.POLLIN)
                        self.descriptor_count += 1
                else:
                    self.poller.register(target.descriptor, select.POLLIN)
                    self.descriptor_count += 1
            self.targets.append(target)

    def try_open_descriptor(self, target: MonitoredProcess) -> None:
        if (
            target.exited
            or target.descriptor >= 0
            or target.pidfd_attempted
            or target.identity is None
        ):
            return

        target.pidfd_attempted = True
        try:
            descriptor = os.pidfd_open(target.process_id)
        except ProcessLookupError:
            self.mark_exited(target)
            return
        except (AttributeError, OSError):
            return

        observation = observe_process_identity(
            target.process_id,
            target.identity,
        )
        if observation in {
            ProcessObservation.EXITED,
            ProcessObservation.REPLACED,
        }:
            os.close(descriptor)
            self.mark_exited(target)
            return
        if observation == ProcessObservation.UNKNOWN:
            os.close(descriptor)
            return

        target.descriptor = descriptor
        self.poller.register(target.descriptor, select.POLLIN)
        self.descriptor_count += 1

    def resume(self, target: MonitoredProcess) -> bool | None:
        """Resume a stopped target without confusing it with an exit."""
        if target.identity is None:
            return None
        try:
            resumed = resume_process(target.process_id, target.identity)
        except MonitoringUnavailable:
            return None
        if not resumed:
            self.mark_exited(target)
        return resumed

    def mark_exited(self, target: MonitoredProcess) -> None:
        target.exited = True
        if target.descriptor < 0:
            return
        try:
            self.poller.unregister(target.descriptor)
        except (KeyError, OSError):
            pass
        try:
            os.close(target.descriptor)
        except OSError:
            pass
        target.descriptor = -1
        self.descriptor_count -= 1

    def wait(
        self,
        validation_callback: Callable[[], bool] | None = None,
        raise_on_cancellation: bool = True,
        interruption_callback: Callable[[], bool] | None = None,
    ) -> MonitoredProcess | None:
        while True:
            if CANCELLATION_ABORT_REQUESTED and raise_on_cancellation:
                if CANCELLATION_REQUESTED:
                    raise AcquisitionCancelled()
                raise AcquisitionDecisionUnknown(
                    "the installation lock decision could not be classified"
                )
            if interruption_callback is not None and interruption_callback():
                return None

            # Check process state before the status callback. If a helper has
            # exited, its stale status must not be mistaken for status
            # corruption and the child must still be reaped by its parent.
            for target in self.targets:
                if target.exited:
                    return target
                if target.identity is None:
                    continue
                observation = observe_process_identity(
                    target.process_id,
                    target.identity,
                )
                if observation in {
                    ProcessObservation.EXITED,
                    ProcessObservation.REPLACED,
                }:
                    self.mark_exited(target)
                    return target
                if observation == ProcessObservation.STOPPED:
                    resumed = self.resume(target)
                    if resumed is False:
                        return target
                    continue
                if observation == ProcessObservation.ALIVE:
                    self.try_open_descriptor(target)

            if validation_callback is not None and not validation_callback():
                return None

            if self.descriptor_count == 0:
                time.sleep(0.1)
                continue

            events = self.poller.poll(0.1)
            if events:
                for descriptor, _event in events:
                    for target in self.targets:
                        if target.descriptor == descriptor:
                            self.mark_exited(target)
                            return target

    def signal_via_pidfd(
        self,
        label: str,
        signal_number: int,
    ) -> bool | None:
        """Signal through a monitored pidfd without using a raw PID.

        ``True`` means the signal was delivered, ``False`` means the monitored
        process has definitively exited, and ``None`` means that this monitor
        cannot currently use pidfd signaling.
        """
        target = next(
            (candidate for candidate in self.targets if candidate.label == label),
            None,
        )
        if target is None:
            raise ValueError(f"unknown monitored process: {label}")
        if target.exited:
            return False
        if target.descriptor < 0 or not hasattr(signal, "pidfd_send_signal"):
            return None

        try:
            signal.pidfd_send_signal(target.descriptor, signal_number)
            return True
        except ProcessLookupError:
            self.mark_exited(target)
            return False
        except OSError:
            return None

    def signal(self, label: str, signal_number: int) -> bool:
        for target in self.targets:
            if target.label != label:
                continue
            if target.exited:
                return False
            if target.descriptor >= 0 and hasattr(signal, "pidfd_send_signal"):
                try:
                    signal.pidfd_send_signal(target.descriptor, signal_number)
                    return True
                except ProcessLookupError:
                    self.mark_exited(target)
                    return False
                except OSError:
                    pass
            if target.identity is None:
                raise MonitoringUnavailable(
                    f"unable to signal {label} process {target.process_id} safely"
                )

            observation = observe_process_identity(
                target.process_id,
                target.identity,
            )
            if observation in {
                ProcessObservation.EXITED,
                ProcessObservation.REPLACED,
            }:
                self.mark_exited(target)
                return False
            if observation == ProcessObservation.UNKNOWN:
                raise MonitoringUnavailable(
                    f"unable to verify {label} process {target.process_id}"
                )

            try:
                os.kill(target.process_id, signal_number)
                return True
            except ProcessLookupError:
                self.mark_exited(target)
                return False
            except OSError as error:
                raise MonitoringUnavailable(
                    f"unable to signal {label} process {target.process_id}: {error}"
                ) from error
        raise ValueError(f"unknown monitored process: {label}")

    def wait_for(
        self,
        label: str,
        raise_on_cancellation: bool = True,
        interruption_callback: Callable[[], bool] | None = None,
    ) -> MonitoredProcess:
        target = next(
            (candidate for candidate in self.targets if candidate.label == label),
            None,
        )
        if target is None:
            raise ValueError(f"unknown monitored process: {label}")

        while not target.exited:
            if CANCELLATION_REQUESTED and raise_on_cancellation:
                raise AcquisitionCancelled()
            if interruption_callback is not None and interruption_callback():
                break
            if target.identity is not None:
                observation = observe_process_identity(
                    target.process_id,
                    target.identity,
                )
                if observation in {
                    ProcessObservation.EXITED,
                    ProcessObservation.REPLACED,
                }:
                    self.mark_exited(target)
                    break
                if observation == ProcessObservation.STOPPED:
                    resumed = self.resume(target)
                    if resumed is False:
                        break
                    continue
                if observation == ProcessObservation.ALIVE:
                    self.try_open_descriptor(target)

            if self.descriptor_count == 0:
                time.sleep(0.1)
                continue

            events = self.poller.poll(0.1)
            for descriptor, _event in events:
                for event_target in self.targets:
                    if event_target.descriptor == descriptor:
                        self.mark_exited(event_target)
                if target.exited:
                    break
        return target

    def close(self) -> None:
        for target in self.targets:
            if target.descriptor >= 0:
                try:
                    os.close(target.descriptor)
                except OSError:
                    pass
                target.descriptor = -1


def wait_for_processes(processes: list[tuple[str, int]]) -> MonitoredProcess:
    monitor = ProcessMonitor(processes)
    try:
        result = monitor.wait()
        if result is None:
            raise MonitoringUnavailable("process monitoring stopped unexpectedly")
        return result
    finally:
        monitor.close()


def wait_for_parents(process_ids: list[int]) -> int:
    processes = [(str(process_id), process_id) for process_id in process_ids]
    return wait_for_processes(processes).process_id


def reap_child(process_id: int) -> bool:
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        try:
            waited_process_id, _status = os.waitpid(process_id, os.WNOHANG)
        except ChildProcessError:
            return True
        except InterruptedError:
            continue
        if waited_process_id == process_id:
            return True
        time.sleep(0.01)
    return False


def terminate_child(
    process_id: int,
    expected_identity: ProcessIdentity | None = None,
) -> None:
    """Stop a child without signaling a process that reused its PID."""
    if expected_identity is None:
        # There is no safe identity with which to signal the process. It may
        # already have exited; waitpid can still reap only this child.
        reap_child(process_id)
        return

    observation = observe_process_identity(process_id, expected_identity)
    if observation in {
        ProcessObservation.EXITED,
        ProcessObservation.REPLACED,
    }:
        reap_child(process_id)
        return

    try:
        signal_process_by_identity(
            process_id,
            expected_identity,
            signal.SIGUSR2,
        )
    except MonitoringUnavailable:
        pass
    if reap_child(process_id):
        return

    try:
        signal_process_by_identity(
            process_id,
            expected_identity,
            signal.SIGKILL,
        )
    except MonitoringUnavailable:
        pass
    reap_child(process_id)


def signal_installer_loss(monitor: ProcessMonitor) -> bool:
    while True:
        try:
            return monitor.signal("installer", signal.SIGUSR1)
        except MonitoringUnavailable:
            target = next(
                (
                    candidate
                    for candidate in monitor.targets
                    if candidate.label == "installer"
                ),
                None,
            )
            if target is None or target.identity is None:
                return False
            observation = observe_process_identity(
                target.process_id,
                target.identity,
            )
            if observation in {
                ProcessObservation.EXITED,
                ProcessObservation.REPLACED,
            }:
                monitor.mark_exited(target)
                return False
            # Unknown is neither a successful notification nor installer
            # exit. Retry until the identity can be verified and signaled.
            time.sleep(0.01)


def configure_watchdog_signal_handlers() -> None:
    """Install the watchdog's cancellation-aware shutdown policy."""
    for signal_number in (
        signal.SIGINT,
        signal.SIGTERM,
        signal.SIGHUP,
        signal.SIGUSR1,
    ):
        signal.signal(signal_number, signal.SIG_IGN)
    signal.signal(signal.SIGUSR2, request_watchdog_cancellation)


def close_watchdog_ready(ready_descriptor: int) -> None:
    """Close the readiness channel without declaring the watchdog ready."""
    if ready_descriptor < 0:
        return
    try:
        os.close(ready_descriptor)
    except OSError:
        pass


def publish_watchdog_ready(ready_descriptor: int) -> None:
    """Publish readiness only after a monitoring strategy is active."""
    if ready_descriptor < 0:
        return
    try:
        os.write(ready_descriptor, b"1")
    except OSError:
        pass
    finally:
        close_watchdog_ready(ready_descriptor)


def watchdog_cancellation_observed() -> bool:
    global WATCHDOG_CANCELLATION_REQUESTED
    global WATCHDOG_DECISION_STATE

    if WATCHDOG_CANCELLATION_REQUESTED:
        return True
    if not DECISION_PATH:
        return False
    decision = read_decision(DECISION_PATH)
    WATCHDOG_DECISION_STATE = decision
    if decision == DECISION_CANCELLED:
        WATCHDOG_CANCELLATION_REQUESTED = True
    return WATCHDOG_CANCELLATION_REQUESTED


def watchdog_process_observation(
    process_id: int,
    identity: ProcessIdentity,
) -> ProcessObservation:
    return observe_process_identity(process_id, identity)


def validate_watchdog_startup(
    installer_process_id: int,
    installer_identity: ProcessIdentity,
    guardian_process_id: int,
    guardian_identity: ProcessIdentity,
    supervisor_process_id: int,
    supervisor_identity: ProcessIdentity,
    worker_process_id: int,
    worker_identity: ProcessIdentity,
) -> tuple[bool, bool]:
    """Validate identities and the initial helper parent relationships.

    The second return value reports a definitive integrity failure. An
    unresolved ``/proc`` read is reported as unknown and must be retried by
    the fail-safe polling path rather than interpreted as process exit.
    """
    expected_processes = [
        (installer_process_id, installer_identity),
        (guardian_process_id, guardian_identity),
        (supervisor_process_id, supervisor_identity),
        (worker_process_id, worker_identity),
    ]
    expected_parents = [
        (guardian_process_id, installer_process_id),
        (supervisor_process_id, guardian_process_id),
        (worker_process_id, supervisor_process_id),
        (os.getpid(), supervisor_process_id),
    ]

    unknown = False
    for process_id, identity in expected_processes:
        observation = watchdog_process_observation(process_id, identity)
        if observation in {
            ProcessObservation.EXITED,
            ProcessObservation.REPLACED,
        }:
            return False, True
        if observation in {
            ProcessObservation.UNKNOWN,
            ProcessObservation.STOPPED,
        }:
            unknown = True
            if observation == ProcessObservation.STOPPED:
                try:
                    resume_process(process_id, identity)
                except MonitoringUnavailable:
                    pass

    for process_id, expected_parent in expected_parents:
        observation = observe_parent_relationship(process_id, expected_parent)
        if observation in {
            ProcessObservation.EXITED,
            ProcessObservation.REPLACED,
        }:
            return False, True
        if observation == ProcessObservation.UNKNOWN:
            unknown = True

    if capture_process_identity(os.getpid()) is None:
        unknown = True
    return not unknown, False


def watchdog_helper_relationships_broken(
    installer_process_id: int,
    guardian_process_id: int,
    guardian_identity: ProcessIdentity,
    supervisor_process_id: int,
    supervisor_identity: ProcessIdentity,
    worker_process_id: int,
    worker_identity: ProcessIdentity,
) -> bool:
    """Return true only for a definitive helper exit or tree mismatch."""
    helper_processes = [
        (guardian_process_id, guardian_identity),
        (supervisor_process_id, supervisor_identity),
        (worker_process_id, worker_identity),
    ]
    for process_id, identity in helper_processes:
        observation = watchdog_process_observation(process_id, identity)
        if observation in {
            ProcessObservation.EXITED,
            ProcessObservation.REPLACED,
        }:
            return True
        if observation == ProcessObservation.STOPPED:
            try:
                if not resume_process(process_id, identity):
                    return True
            except MonitoringUnavailable:
                pass

    expected_parents = [
        (guardian_process_id, installer_process_id),
        (supervisor_process_id, guardian_process_id),
        (worker_process_id, supervisor_process_id),
        (os.getpid(), supervisor_process_id),
    ]
    for process_id, expected_parent in expected_parents:
        observation = observe_parent_relationship(process_id, expected_parent)
        if observation in {
            ProcessObservation.EXITED,
            ProcessObservation.REPLACED,
        }:
            return True
    return False


def open_verified_installer_pidfd(
    installer_process_id: int,
    installer_identity: ProcessIdentity,
) -> int:
    """Open an installer pidfd only after verifying its recorded identity."""
    observation = watchdog_process_observation(
        installer_process_id,
        installer_identity,
    )
    if observation not in {
        ProcessObservation.ALIVE,
        ProcessObservation.STOPPED,
    }:
        return -1
    try:
        descriptor = os.pidfd_open(installer_process_id)
    except (AttributeError, OSError):
        return -1

    observation = watchdog_process_observation(
        installer_process_id,
        installer_identity,
    )
    if observation not in {
        ProcessObservation.ALIVE,
        ProcessObservation.STOPPED,
    }:
        try:
            os.close(descriptor)
        except OSError:
            pass
        return -1
    return descriptor


def notify_watchdog_installer(
    monitor: ProcessMonitor | None,
    installer_process_id: int,
    installer_identity: ProcessIdentity,
) -> bool:
    """Notify the installer, retrying until success or definitive exit."""
    while True:
        if monitor is not None:
            try:
                monitor_result = monitor.signal_via_pidfd(
                    "installer",
                    signal.SIGUSR1,
                )
                if monitor_result is True:
                    return True
                if monitor_result is False:
                    return False
            except (AttributeError, MonitoringUnavailable, OSError, ValueError):
                pass

        observation = watchdog_process_observation(
            installer_process_id,
            installer_identity,
        )
        if observation in {
            ProcessObservation.EXITED,
            ProcessObservation.REPLACED,
        }:
            return False
        if observation == ProcessObservation.UNKNOWN:
            time.sleep(0.01)
            continue

        descriptor = open_verified_installer_pidfd(
            installer_process_id,
            installer_identity,
        )
        if descriptor >= 0:
            try:
                if hasattr(signal, "pidfd_send_signal"):
                    try:
                        signal.pidfd_send_signal(descriptor, signal.SIGUSR1)
                        return True
                    except ProcessLookupError:
                        return False
                    except OSError:
                        pass
            finally:
                try:
                    os.close(descriptor)
                except OSError:
                    pass

        # A raw PID signal is the last resort. Re-verify the recorded
        # identity immediately before using it so PID reuse cannot target an
        # unrelated process.
        observation = watchdog_process_observation(
            installer_process_id,
            installer_identity,
        )
        if observation in {
            ProcessObservation.EXITED,
            ProcessObservation.REPLACED,
        }:
            return False
        if observation == ProcessObservation.UNKNOWN:
            time.sleep(0.01)
            continue
        try:
            os.kill(installer_process_id, signal.SIGUSR1)
            return True
        except ProcessLookupError:
            return False
        except OSError:
            time.sleep(0.01)


def wait_for_watchdog_installer_exit(
    installer_process_id: int,
    installer_identity: ProcessIdentity,
    monitor: ProcessMonitor | None = None,
) -> None:
    """Wait for installer exit while retaining the locked descriptor."""
    if monitor is not None:
        try:
            target = monitor.wait_for("installer", raise_on_cancellation=False)
            if target.exited:
                remove_decision(DECISION_PATH)
                return
        except (MonitoringUnavailable, OSError, ValueError):
            pass

    while True:
        observation = watchdog_process_observation(
            installer_process_id,
            installer_identity,
        )
        if observation in {
            ProcessObservation.EXITED,
            ProcessObservation.REPLACED,
        }:
            remove_decision(DECISION_PATH)
            return
        time.sleep(0.01)


def watchdog_last_resort_loop(
    installer_process_id: int,
    installer_identity: ProcessIdentity,
) -> None:
    """Keep the descriptor until installer exit if watchdog setup fails."""
    notified = False
    while True:
        try:
            observation = watchdog_process_observation(
                installer_process_id,
                installer_identity,
            )
        except BaseException:
            observation = ProcessObservation.UNKNOWN
        if observation in {
            ProcessObservation.EXITED,
            ProcessObservation.REPLACED,
        }:
            remove_decision(DECISION_PATH)
            return

        if not notified and observation in {
            ProcessObservation.ALIVE,
            ProcessObservation.STOPPED,
        }:
            try:
                notified = notify_watchdog_installer(
                    None,
                    installer_process_id,
                    installer_identity,
                )
                if not notified:
                    remove_decision(DECISION_PATH)
                    return
            except BaseException:
                pass
        try:
            time.sleep(0.01)
        except InterruptedError:
            pass


def watchdog_fallback_loop(
    installer_process_id: int,
    installer_identity: ProcessIdentity,
    guardian_process_id: int,
    guardian_identity: ProcessIdentity,
    supervisor_process_id: int,
    supervisor_identity: ProcessIdentity,
    worker_process_id: int,
    worker_identity: ProcessIdentity,
    ready_descriptor: int,
    startup_failure: bool = False,
    startup_validated: bool = False,
) -> None:
    """Poll identities when pidfd monitoring cannot be established."""
    policy_installed = True
    try:
        configure_watchdog_signal_handlers()
    except (OSError, RuntimeError, ValueError):
        # Without the watchdog-specific policy the watchdog cannot claim
        # readiness. It still keeps the descriptor and polls as a fail-safe.
        policy_installed = False

    helper_loss = startup_failure
    ready_published = False
    if startup_validated and policy_installed and not helper_loss:
        publish_watchdog_ready(ready_descriptor)
        ready_published = True
    elif not policy_installed or helper_loss:
        close_watchdog_ready(ready_descriptor)

    while True:
        observation = watchdog_process_observation(
            installer_process_id,
            installer_identity,
        )
        if observation in {
            ProcessObservation.EXITED,
            ProcessObservation.REPLACED,
        }:
            if not ready_published:
                close_watchdog_ready(ready_descriptor)
            remove_decision(DECISION_PATH)
            return

        if watchdog_cancellation_observed():
            if not ready_published:
                close_watchdog_ready(ready_descriptor)
            if notify_watchdog_installer(
                None,
                installer_process_id,
                installer_identity,
            ):
                wait_for_watchdog_installer_exit(
                    installer_process_id,
                    installer_identity,
                )
            else:
                remove_decision(DECISION_PATH)
            return

        if not helper_loss:
            try:
                helper_loss = watchdog_helper_relationships_broken(
                    installer_process_id,
                    guardian_process_id,
                    guardian_identity,
                    supervisor_process_id,
                    supervisor_identity,
                    worker_process_id,
                    worker_identity,
                )
            except BaseException:
                # A transient inspection failure is not definitive helper loss.
                helper_loss = False

        if helper_loss:
            if not ready_published:
                close_watchdog_ready(ready_descriptor)
            if notify_watchdog_installer(
                None,
                installer_process_id,
                installer_identity,
            ):
                wait_for_watchdog_installer_exit(
                    installer_process_id,
                    installer_identity,
                )
            else:
                remove_decision(DECISION_PATH)
            return

        if not startup_validated:
            try:
                startup_valid, definitive_failure = validate_watchdog_startup(
                    installer_process_id,
                    installer_identity,
                    guardian_process_id,
                    guardian_identity,
                    supervisor_process_id,
                    supervisor_identity,
                    worker_process_id,
                    worker_identity,
                )
            except BaseException:
                startup_valid = False
                definitive_failure = False

            if definitive_failure:
                helper_loss = True
                continue
            if startup_valid:
                startup_validated = True
                if policy_installed and not ready_published:
                    publish_watchdog_ready(ready_descriptor)
                    ready_published = True

        if observation == ProcessObservation.UNKNOWN:
            # Unknown is not installer exit. Keep the descriptor and retry.
            time.sleep(0.01)
            continue
        time.sleep(0.01)


def watchdog_loop(
    installer_process_id: int,
    installer_identity: ProcessIdentity,
    guardian_process_id: int,
    guardian_identity: ProcessIdentity,
    supervisor_process_id: int,
    supervisor_identity: ProcessIdentity,
    worker_process_id: int,
    worker_identity: ProcessIdentity,
    ready_descriptor: int,
) -> None:
    """Watch the helper tree and keep the lock until the installer exits.

    The watchdog is deliberately a separate process from the supervisor. It
    inherits the already locked descriptor and never opens or locks the lock
    file itself. A failure in the monitor therefore changes the observation
    strategy, not the ownership of the descriptor.
    """
    configure_watchdog_signal_handlers()

    startup_valid = False
    startup_failure = False
    for _ in range(20):
        try:
            startup_valid, definitive_failure = validate_watchdog_startup(
                installer_process_id,
                installer_identity,
                guardian_process_id,
                guardian_identity,
                supervisor_process_id,
                supervisor_identity,
                worker_process_id,
                worker_identity,
            )
        except (MonitoringUnavailable, OSError, ValueError):
            # A transient inspection failure is not a definitive helper loss.
            startup_valid = False
            definitive_failure = False
        if startup_valid or definitive_failure:
            startup_failure = definitive_failure
            break
        time.sleep(0.01)

    monitor: ProcessMonitor | None = None
    if startup_valid:
        try:
            monitor = ProcessMonitor(
                [
                    ("installer", installer_process_id, installer_identity),
                    ("guardian", guardian_process_id, guardian_identity),
                    ("supervisor", supervisor_process_id, supervisor_identity),
                    ("worker", worker_process_id, worker_identity),
                ]
            )
            if any(target.exited for target in monitor.targets):
                startup_failure = True
                monitor.close()
                monitor = None
        except (MonitoringUnavailable, OSError, ValueError):
            # The identity and parent relationships were already validated.
            # Fall back to polling rather than declaring a helper loss.
            startup_failure = False

    if monitor is None:
        watchdog_fallback_loop(
            installer_process_id,
            installer_identity,
            guardian_process_id,
            guardian_identity,
            supervisor_process_id,
            supervisor_identity,
            worker_process_id,
            worker_identity,
            ready_descriptor,
            startup_failure,
            startup_valid,
        )
        return

    # Readiness now means that identities and parent relationships were
    # validated and either pidfd monitoring or identity polling is active.
    publish_watchdog_ready(ready_descriptor)
    try:
        while True:
            if watchdog_cancellation_observed():
                if notify_watchdog_installer(
                    monitor,
                    installer_process_id,
                    installer_identity,
                ):
                    wait_for_watchdog_installer_exit(
                        installer_process_id,
                        installer_identity,
                        monitor,
                    )
                else:
                    remove_decision(DECISION_PATH)
                return

            try:
                exited = monitor.wait(
                    raise_on_cancellation=False,
                    interruption_callback=watchdog_cancellation_observed,
                )
            except AcquisitionCancelled:
                # Cancellation is watchdog state, never an escaping exception.
                monitor.close()
                monitor = None
                watchdog_fallback_loop(
                    installer_process_id,
                    installer_identity,
                    guardian_process_id,
                    guardian_identity,
                    supervisor_process_id,
                    supervisor_identity,
                    worker_process_id,
                    worker_identity,
                    -1,
                    False,
                    True,
                )
                return
            except (MonitoringUnavailable, OSError, ValueError):
                monitor.close()
                monitor = None
                watchdog_fallback_loop(
                    installer_process_id,
                    installer_identity,
                    guardian_process_id,
                    guardian_identity,
                    supervisor_process_id,
                    supervisor_identity,
                    worker_process_id,
                    worker_identity,
                    -1,
                    True,
                )
                return

            if exited is None:
                if watchdog_cancellation_observed():
                    if notify_watchdog_installer(
                        monitor,
                        installer_process_id,
                        installer_identity,
                    ):
                        wait_for_watchdog_installer_exit(
                            installer_process_id,
                            installer_identity,
                            monitor,
                        )
                    else:
                        remove_decision(DECISION_PATH)
                    return
                helper_loss = True
            elif exited.label == "installer":
                remove_decision(DECISION_PATH)
                return
            else:
                helper_loss = True

            if helper_loss:
                if notify_watchdog_installer(
                    monitor,
                    installer_process_id,
                    installer_identity,
                ):
                    wait_for_watchdog_installer_exit(
                        installer_process_id,
                        installer_identity,
                        monitor,
                    )
                else:
                    remove_decision(DECISION_PATH)
                return
    finally:
        if monitor is not None:
            monitor.close()


def worker_loop(
    installer_process_id: int,
    installer_identity: ProcessIdentity,
    supervisor_process_id: int,
    supervisor_identity: ProcessIdentity,
    status_path: str,
    ready_descriptor: int,
) -> None:
    configure_signal_handlers(allow_cancellation=True)
    if not wait_for_process_identity(installer_process_id, installer_identity):
        os._exit(1)

    monitor = ProcessMonitor(
        [
            ("installer", installer_process_id, installer_identity),
            ("supervisor", supervisor_process_id, supervisor_identity),
        ]
    )
    try:
        os.write(ready_descriptor, b"1")
    finally:
        os.close(ready_descriptor)

    installer_terminated = False
    try:
        exited = monitor.wait()
        if exited is None:
            raise MonitoringUnavailable("worker status validation failed")
        if exited.label == "installer":
            installer_terminated = True
        else:
            decision = read_decision(DECISION_PATH) if DECISION_PATH else None
            if decision != DECISION_CANCELLED:
                if signal_installer_loss(monitor):
                    monitor.wait_for("installer")
                installer_terminated = True
    finally:
        monitor.close()
    if installer_terminated:
        remove_status(status_path)
        remove_decision(DECISION_PATH)


def supervisor_loop(
    installer_process_id: int,
    installer_identity: ProcessIdentity,
    wrapper_process_id: int,
    wrapper_identity: ProcessIdentity,
    worker_process_id: int,
    worker_identity: ProcessIdentity,
    watchdog_process_id: int,
    watchdog_identity: ProcessIdentity,
    status_path: str,
) -> None:
    monitor = ProcessMonitor(
        [
            ("installer", installer_process_id, installer_identity),
            ("wrapper", wrapper_process_id, wrapper_identity),
            ("worker", worker_process_id, worker_identity),
            ("watchdog", watchdog_process_id, watchdog_identity),
        ]
    )
    installer_terminated = False
    try:
        def status_is_valid() -> bool:
            # The watchdog is initially a child of the supervisor. It may be
            # reparented if the supervisor is killed, so only the initial
            # publication requires that parent relationship. An unresolved
            # /proc observation is retried rather than treated as corruption.
            status, definitive_failure = inspect_lock_status(
                status_path,
                wrapper_process_id,
                installer_process_id,
                installer_identity,
                require_watchdog_parent=False,
            )
            return status is not None or not definitive_failure

        exited = monitor.wait(status_is_valid)
        if exited is None:
            # A missing, corrupt, or mismatched status file is an integrity
            # failure. Abort the installer, but retain the descriptor until the
            # installer has completed its cleanup.
            decision = read_decision(DECISION_PATH) if DECISION_PATH else None
            if decision == DECISION_CANCELLED:
                raise AcquisitionCancelled()
            if signal_installer_loss(monitor):
                monitor.wait_for("installer")
            installer_terminated = True
        elif exited.label == "installer":
            installer_terminated = True
        else:
            if exited.label == "worker":
                reap_child(worker_process_id)
            decision = read_decision(DECISION_PATH) if DECISION_PATH else None
            if decision == DECISION_CANCELLED:
                raise AcquisitionCancelled()
            if signal_installer_loss(monitor):
                monitor.wait_for("installer")
            installer_terminated = True
    finally:
        monitor.close()
        # The watchdog is intentionally not terminated here.  It is the
        # fail-safe owner of the descriptor when this supervisor fails.
        terminate_child(worker_process_id, worker_identity)
    if installer_terminated:
        remove_status(status_path)
        remove_decision(DECISION_PATH)


def wait_for_ready(descriptor: int, timeout: float = 5.0) -> bool:
    try:
        readable, _writable, _exceptional = select.select([descriptor], [], [], timeout)
    except InterruptedError:
        return False
    if not readable:
        return False
    try:
        return os.read(descriptor, 1) == b"1"
    except OSError:
        return False


def wait_for_installer(
    installer_process_id: int,
    installer_identity: ProcessIdentity,
) -> None:
    configure_signal_handlers(allow_cancellation=False)
    observation = observe_process_identity(
        installer_process_id,
        installer_identity,
    )
    if observation in {
        ProcessObservation.EXITED,
        ProcessObservation.REPLACED,
    }:
        return

    monitor = ProcessMonitor(
        [("installer", installer_process_id, installer_identity)]
    )
    try:
        target = monitor.targets[0]
        if target.exited:
            return
        if signal_installer_loss(monitor):
            monitor.wait_for("installer")
    finally:
        monitor.close()


def encode_status(status: LockStatus) -> str:
    return (
        f"{status.supervisor_process_id}\n"
        f"{status.worker_process_id}\n"
        f"{encode_process_identity(status.installer_identity)}\n"
        f"{encode_process_identity(status.supervisor_identity)}\n"
        f"{encode_process_identity(status.worker_identity)}\n"
        f"{status.wrapper_process_id}\n"
        f"{encode_process_identity(status.wrapper_identity)}\n"
        f"{status.installer_process_id}\n"
        f"{status.watchdog_process_id}\n"
        f"{encode_process_identity(status.watchdog_identity)}\n"
        f"schema={STATUS_SCHEMA_VERSION}\n"
        "ready=1\n"
    )


def hold_lock(
    lock_path: str,
    status_path: str,
    decision_path: str,
    installer_process_id: int,
    installer_identity: ProcessIdentity,
    wrapper_process_id: int,
) -> None:
    global DECISION_PATH
    global WATCHDOG_CANCELLATION_REQUESTED

    DECISION_PATH = decision_path
    configure_signal_handlers(allow_cancellation=True)
    if not wait_for_process_identity(installer_process_id, installer_identity):
        fail("installer process identity changed before lock helper startup")
    if wrapper_process_id != os.getppid():
        fail(
            "lock helper is not a child of the lock guardian "
            f"(expected {wrapper_process_id}, actual {os.getppid()})"
        )

    lock_descriptor = find_lock_descriptor(lock_path)
    supervisor_process_id = os.getpid()
    wrapper_identity = wait_for_captured_process_identity(wrapper_process_id)
    supervisor_identity = wait_for_captured_process_identity(supervisor_process_id)
    if wrapper_identity is None or supervisor_identity is None:
        fail("unable to capture lock helper identities")

    ready_read, ready_write = os.pipe()
    worker_process_id = os.fork()
    if worker_process_id == 0:
        os.close(ready_read)
        try:
            worker_loop(
                installer_process_id,
                installer_identity,
                supervisor_process_id,
                supervisor_identity,
                status_path,
                ready_write,
            )
        except BaseException:
            os._exit(1)
        os._exit(0)

    os.close(ready_write)
    worker_identity = wait_for_captured_process_identity(worker_process_id)
    worker_ready = wait_for_ready(ready_read)
    os.close(ready_read)
    if not worker_ready:
        terminate_child(worker_process_id, worker_identity)
        fail("lock worker did not become ready")

    if worker_identity is None:
        terminate_child(worker_process_id)
        fail("unable to capture the lock worker identity")
    if not wait_for_parent_relationship(
        worker_process_id,
        os.getpid(),
        worker_identity,
    ):
        terminate_child(worker_process_id, worker_identity)
        fail("lock worker is not a child of the lock supervisor")

    # Fork the watchdog only after the worker is ready.  The child inherits
    # the exact descriptor used by the supervisor; it never calls
    # find_lock_descriptor() and never attempts to acquire the lock again.
    watchdog_ready_read, watchdog_ready_write = os.pipe()
    watchdog_process_id = os.fork()
    if watchdog_process_id == 0:
        WATCHDOG_CANCELLATION_REQUESTED = False
        try:
            os.close(watchdog_ready_read)
            # Install the watchdog policy in the child before doing any other
            # work. A concurrently delivered USR2 is then handled by the
            # atomic watchdog cancellation protocol rather than the
            # supervisor's exception-based cancellation path.
            configure_watchdog_signal_handlers()
            watchdog_loop(
                installer_process_id,
                installer_identity,
                wrapper_process_id,
                wrapper_identity,
                supervisor_process_id,
                supervisor_identity,
                worker_process_id,
                worker_identity,
                watchdog_ready_write,
            )
        except BaseException:
            # A watchdog startup error must not make the supervisor kill this
            # process. Fall back to identity polling and keep the inherited
            # descriptor until the installer exits. AcquisitionCancelled is
            # deliberately handled here and can never escape the watchdog.
            try:
                watchdog_fallback_loop(
                    installer_process_id,
                    installer_identity,
                    wrapper_process_id,
                    wrapper_identity,
                    supervisor_process_id,
                    supervisor_identity,
                    worker_process_id,
                    worker_identity,
                    watchdog_ready_write,
                    False,
                    False,
                )
            except BaseException:
                close_watchdog_ready(watchdog_ready_write)
                watchdog_last_resort_loop(
                    installer_process_id,
                    installer_identity,
                )
        os._exit(0)

    os.close(watchdog_ready_write)
    watchdog_ready = wait_for_ready(watchdog_ready_read)
    os.close(watchdog_ready_read)
    if not watchdog_ready:
        # Do not terminate the watchdog here.  If it is alive but unable to
        # publish readiness, its fail-safe polling mode is still preferable
        # to silently dropping the last descriptor owner.
        fail("lock watchdog did not become ready")

    watchdog_identity = wait_for_captured_process_identity(watchdog_process_id)
    if watchdog_identity is None:
        fail("unable to capture the lock watchdog identity")
    if not wait_for_parent_relationship(
        watchdog_process_id,
        os.getpid(),
        watchdog_identity,
    ):
        fail("lock watchdog is not a child of the lock supervisor")

    status = LockStatus(
        installer_process_id=installer_process_id,
        installer_identity=installer_identity,
        wrapper_process_id=wrapper_process_id,
        wrapper_identity=wrapper_identity,
        supervisor_process_id=supervisor_process_id,
        supervisor_identity=supervisor_identity,
        worker_process_id=worker_process_id,
        worker_identity=worker_identity,
        watchdog_process_id=watchdog_process_id,
        watchdog_identity=watchdog_identity,
    )
    try:
        write_status(status_path, encode_status(status))
    except BaseException:
        # The watchdog is deliberately left running.  It will observe the
        # supervisor's exit and retain the descriptor until the installer has
        # finished cleaning up.
        terminate_child(worker_process_id, worker_identity)
        raise

    try:
        supervisor_loop(
            installer_process_id,
            installer_identity,
            wrapper_process_id,
            wrapper_identity,
            worker_process_id,
            worker_identity,
            watchdog_process_id,
            watchdog_identity,
            status_path,
        )
    finally:
        os.close(lock_descriptor)


def main() -> None:
    if len(sys.argv) == 4 and sys.argv[1] == "claim-decision":
        value = sys.argv[3]
        if value not in {DECISION_COMMITTED, DECISION_CANCELLED}:
            fail(f"invalid lock decision: {value}")
        try:
            created, decision = claim_decision(sys.argv[2], value)
        except DecisionPublicationError as error:
            # The decision is already visible even though the directory sync
            # failed.  Return the authoritative value with a failure status;
            # the caller can distinguish it from an unpublished decision.
            print(error.decision)
            raise SystemExit(1)
        print(decision)
        if created:
            raise SystemExit(0)
        if decision in {DECISION_COMMITTED, DECISION_CANCELLED}:
            raise SystemExit(75)
        raise SystemExit(1)

    if len(sys.argv) == 3 and sys.argv[1] == "read-decision":
        decision = read_decision(sys.argv[2])
        if decision not in {DECISION_COMMITTED, DECISION_CANCELLED}:
            raise SystemExit(1)
        print(decision)
        return

    if len(sys.argv) == 3 and sys.argv[1] == "identity":
        configure_signal_handlers(allow_cancellation=False)
        process_id = int(sys.argv[2])
        identity = capture_process_identity(process_id)
        if identity is None:
            fail(f"unable to identify process {process_id}")
        print(encode_process_identity(identity))
        return

    if len(sys.argv) == 6 and sys.argv[1] == "validate-status":
        configure_signal_handlers(allow_cancellation=False)
        installer_identity = parse_process_identity(sys.argv[5])
        if installer_identity is None:
            fail("invalid installer process identity")
        status = None
        for _ in range(100):
            status, definitive_failure = inspect_lock_status(
                sys.argv[2],
                int(sys.argv[3]),
                int(sys.argv[4]),
                installer_identity,
            )
            if status is not None or definitive_failure:
                break
            time.sleep(0.01)
        if status is None:
            raise SystemExit(1)
        print(
            f"{status.supervisor_process_id} "
            f"{status.worker_process_id} "
            f"{status.watchdog_process_id}"
        )
        return

    if len(sys.argv) == 4 and sys.argv[1] == "await-installer":
        configure_signal_handlers(allow_cancellation=False)
        installer_identity = parse_process_identity(sys.argv[2])
        if installer_identity is None:
            fail("invalid installer process identity")
        wait_for_installer(int(sys.argv[3]), installer_identity)
        return

    if len(sys.argv) != 8 or sys.argv[1] != "hold":
        fail(
            "usage: lock-holder.py identity PID or "
            "lock-holder.py validate-status STATUS WRAPPER_PID INSTALLER_PID "
            "INSTALLER_IDENTITY or lock-holder.py await-installer "
            "INSTALLER_IDENTITY INSTALLER_PID or lock-holder.py claim-decision "
            "PATH VALUE or lock-holder.py read-decision PATH or lock-holder.py "
            "hold LOCK_PATH STATUS_PATH DECISION_PATH INSTALLER_PID "
            "INSTALLER_IDENTITY WRAPPER_PID"
        )

    installer_identity = parse_process_identity(sys.argv[6])
    if installer_identity is None:
        fail("invalid installer process identity")
    hold_lock(
        sys.argv[2],
        sys.argv[3],
        sys.argv[4],
        int(sys.argv[5]),
        installer_identity,
        int(sys.argv[7]),
    )


if __name__ == "__main__":
    try:
        main()
    except AcquisitionCancelled:
        raise SystemExit(73)
    except AcquisitionDecisionUnknown as error:
        fail(str(error))
    except (OSError, MonitoringUnavailable, ValueError) as error:
        fail(str(error))
