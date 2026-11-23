#!/usr/bin/env python3

# SPDX-License-Identifier: MIT

import ctypes
import errno
import fcntl
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
STATUS_READ_LIMIT = 8192
SUPPORT_SCHEMA_VERSION = 2
SUPPORT_STATUS_READ_LIMIT = 8192
SUPPORT_STATE_READY = "ready"
SUPPORT_ACK_STATE_OWNER_RETIRED = "owner-retired"
OWNER_RETIREMENT_SCHEMA_VERSION = 1
OWNER_RETIREMENT_REQUEST_STATE = "owner-retirement-requested"
OWNER_RETIREMENT_MARKER_STATE = "owner-retiring"
OWNER_RETIREMENT_ACK_STATE = SUPPORT_ACK_STATE_OWNER_RETIRED
SUPPORT_ROLE_OWNER = "owner"
SUPPORT_ROLE_SENTINEL = "sentinel"
# Linux does not define SIGUSR3 (unlike some BSD systems). Use the first
# process-directed realtime signal as this project's owner-loss notification
# when the platform has no native SIGUSR3. The numeric value is also usable
# by the Bash installer, which can trap realtime signals by number.
SIGUSR3 = getattr(signal, "SIGUSR3", signal.SIGRTMIN)
# Sentinel/support loss uses the next realtime signal so it remains distinct
# from owner loss and from the guardian's helper-loss notification.
SIGSUPPORT_LOSS = signal.SIGRTMIN + 1
DECISION_COMMITTED = "committed"
DECISION_CANCELLED = "cancelled"
DECISION_UNKNOWN = "unknown"
DECISION_RESOLUTION_ATTEMPTS = 20
DECISION_RESOLUTION_DELAY = 0.01
CANCELLATION_REQUESTED = False
CANCELLATION_ABORT_REQUESTED = False
CANCELLATION_DECISION_STATE = DECISION_UNKNOWN
WATCHDOG_CANCELLATION_REQUESTED = False
WATCHDOG_ABORT_REQUESTED = False
WATCHDOG_DECISION_STATE = DECISION_UNKNOWN
SENTINEL_RETIREMENT_REQUESTED = False
OWNER_RETIREMENT_REQUESTED = False
DECISION_PATH: str | None = None
OBSERVED_DECISION_STATES: dict[str, str] = {}
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


def observe_decision(path: str | None) -> str:
    """Observe an existing decision without creating or changing one.

    The authoritative decision is retained until the installer terminates, so
    a transient read failure must not make a published winner disappear from
    the observer's classification. The first authoritative winner is latched
    per decision path. This helper never claims a cancellation; it is safe for
    generic helper and cleanup observers.
    """
    if not path:
        return DECISION_UNKNOWN

    decision_key = os.path.abspath(path)
    observed_decision = OBSERVED_DECISION_STATES.get(decision_key)
    if observed_decision in {DECISION_COMMITTED, DECISION_CANCELLED}:
        return observed_decision

    for _ in range(DECISION_RESOLUTION_ATTEMPTS):
        decision = read_decision(path)
        if decision in {DECISION_COMMITTED, DECISION_CANCELLED}:
            OBSERVED_DECISION_STATES[decision_key] = decision
            return decision
        time.sleep(DECISION_RESOLUTION_DELAY)
    return DECISION_UNKNOWN


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
            if existing in {DECISION_COMMITTED, DECISION_CANCELLED}:
                OBSERVED_DECISION_STATES[os.path.abspath(path)] = existing
            return False, existing
        OBSERVED_DECISION_STATES[os.path.abspath(path)] = value
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


class SentinelRetirementResult(Enum):
    RETIRED = "retired"
    OWNER_LOST = "owner-lost"
    INSTALLER_EXITED = "installer-exited"


@dataclass(frozen=True)
class ProcessIdentity:
    start_time: int
    boot_id: str


@dataclass(frozen=True)
class DescriptorIdentity:
    device: int
    inode: int


@dataclass(frozen=True)
class SupportStatus:
    run_id: str
    role: str
    installer_process_id: int
    installer_identity: ProcessIdentity
    process_process_id: int
    process_identity: ProcessIdentity
    owner_process_id: int
    owner_identity: ProcessIdentity
    peer_process_id: int
    peer_identity: ProcessIdentity
    file_descriptor: int
    scope_descriptor: int
    file_identity: DescriptorIdentity
    scope_identity: DescriptorIdentity


@dataclass(frozen=True)
class OwnerRetirementMarker:
    state: str
    run_id: str
    request_id: str
    owner_process_id: int
    owner_identity: ProcessIdentity
    sentinel_process_id: int
    sentinel_identity: ProcessIdentity
    installer_process_id: int
    installer_identity: ProcessIdentity


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


@dataclass
class ProcessGroupAnchor:
    process_id: int
    identity: ProcessIdentity
    descriptor: int


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

    decision_key = os.path.abspath(path)
    observed_decision = OBSERVED_DECISION_STATES.get(decision_key)
    if observed_decision in {DECISION_COMMITTED, DECISION_CANCELLED}:
        return observed_decision

    for _ in range(DECISION_RESOLUTION_ATTEMPTS):
        decision = read_decision(path)
        if decision in {DECISION_COMMITTED, DECISION_CANCELLED}:
            OBSERVED_DECISION_STATES[decision_key] = decision
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
    global WATCHDOG_ABORT_REQUESTED
    global WATCHDOG_CANCELLATION_REQUESTED
    global WATCHDOG_DECISION_STATE

    # The watchdog observes the same atomic decision as the other helpers, but
    # it must never turn cancellation into an exception: the watchdog retains
    # the locked descriptor until the installer has actually terminated. An
    # unknown decision after SIGUSR2 is a sticky generic abort, never an
    # implicit cancellation that a later read could turn into commitment.
    WATCHDOG_DECISION_STATE = resolve_cancellation_decision(DECISION_PATH)
    if WATCHDOG_DECISION_STATE == DECISION_UNKNOWN:
        WATCHDOG_ABORT_REQUESTED = True
        WATCHDOG_CANCELLATION_REQUESTED = False
    elif WATCHDOG_DECISION_STATE == DECISION_CANCELLED:
        WATCHDOG_CANCELLATION_REQUESTED = not WATCHDOG_ABORT_REQUESTED
    else:
        WATCHDOG_CANCELLATION_REQUESTED = False


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


def request_sentinel_retirement(_signal_number: int, _frame: object) -> None:
    """Record an intentional owner-retirement request for the sentinel."""
    global SENTINEL_RETIREMENT_REQUESTED
    SENTINEL_RETIREMENT_REQUESTED = True


def configure_sentinel_signal_handlers() -> None:
    """Ignore ordinary shutdown signals and retain only the retirement request."""
    for signal_number in (
        signal.SIGINT,
        signal.SIGTERM,
        signal.SIGHUP,
        signal.SIGUSR1,
    ):
        signal.signal(signal_number, signal.SIG_IGN)
    signal.signal(signal.SIGUSR2, request_sentinel_retirement)


def request_owner_retirement(_signal_number: int, _frame: object) -> None:
    """Record an identity-bound retirement request received by the owner."""
    global OWNER_RETIREMENT_REQUESTED
    OWNER_RETIREMENT_REQUESTED = True


def configure_owner_signal_handlers() -> None:
    """Ignore ordinary shutdown signals and accept a retirement request."""
    configure_signal_handlers(allow_cancellation=False)
    signal.signal(signal.SIGUSR1, request_owner_retirement)


def read_lock_file_identity(path: str) -> tuple[int, int]:
    """Return the device and inode of a validated lock file."""
    absolute = os.path.abspath(path)
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
    descriptor = os.open(absolute, flags)
    try:
        opened_metadata = os.fstat(descriptor)
        path_metadata = os.stat(absolute, follow_symlinks=False)
        if stat.S_ISLNK(path_metadata.st_mode):
            raise OSError(
                errno.ELOOP,
                f"lock path must not be a symbolic link: {path}",
            )
        if not stat.S_ISREG(path_metadata.st_mode):
            raise OSError(
                errno.EINVAL,
                f"lock path must be a regular file: {path}",
            )
        if path_metadata.st_nlink != 1 or opened_metadata.st_nlink != 1:
            raise OSError(
                errno.EINVAL,
                f"lock path has multiple hard links: {path}",
            )
        if path_metadata.st_uid != os.geteuid():
            raise OSError(
                errno.EPERM,
                f"lock path is not owned by the current user: {path}",
            )
        if (
            opened_metadata.st_dev != path_metadata.st_dev
            or opened_metadata.st_ino != path_metadata.st_ino
            or not stat.S_ISREG(opened_metadata.st_mode)
            or opened_metadata.st_uid != os.geteuid()
        ):
            raise OSError(
                errno.EINVAL,
                f"lock path changed while it was being inspected: {path}",
            )

        final_metadata = os.stat(absolute, follow_symlinks=False)
        if (
            final_metadata.st_dev != opened_metadata.st_dev
            or final_metadata.st_ino != opened_metadata.st_ino
            or not stat.S_ISREG(final_metadata.st_mode)
            or final_metadata.st_nlink != 1
            or final_metadata.st_uid != os.geteuid()
        ):
            raise OSError(
                errno.EINVAL,
                f"lock path changed while it was being inspected: {path}",
            )
        return opened_metadata.st_dev, opened_metadata.st_ino
    finally:
        os.close(descriptor)


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
        chunks: list[bytes] = []
        total = 0
        read_limit = STATUS_READ_LIMIT + 1
        while total < read_limit:
            chunk = os.read(descriptor, min(4096, read_limit - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        if total > STATUS_READ_LIMIT:
            return None
        content = b"".join(chunks).decode("utf-8", errors="strict")
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


def encode_descriptor_identity(identity: DescriptorIdentity) -> str:
    return f"{identity.device}:{identity.inode}"


def parse_descriptor_identity(value: str) -> DescriptorIdentity | None:
    """Parse the canonical decimal device:inode descriptor identity."""
    if not isinstance(value, str) or value.count(":") != 1:
        return None
    device_text, inode_text = value.split(":", 1)
    if not device_text or not inode_text:
        return None
    if not device_text.isascii() or not device_text.isdigit():
        return None
    if not inode_text.isascii() or not inode_text.isdigit():
        return None
    try:
        device = int(device_text, 10)
        inode = int(inode_text, 10)
    except ValueError:
        return None
    if device < 0 or inode <= 0:
        return None
    identity = DescriptorIdentity(device, inode)
    if encode_descriptor_identity(identity) != value:
        return None
    return identity


def parse_strict_process_identity(value: str) -> ProcessIdentity | None:
    """Parse only the canonical process identity used by support files."""
    identity = parse_process_identity(value)
    if identity is None or encode_process_identity(identity) != value:
        return None
    if any(character.isspace() or ord(character) < 0x21 for character in value):
        return None
    return identity


def parse_support_process_id(value: str) -> int | None:
    """Parse a canonical process ID used by the support protocol."""
    if not isinstance(value, str) or not value.isascii() or not value.isdigit():
        return None
    try:
        process_id = int(value, 10)
    except ValueError:
        return None
    if process_id <= 1 or str(process_id) != value:
        return None
    return process_id


def parse_support_descriptor_number(value: str) -> int | None:
    """Parse a canonical inherited descriptor number."""
    if not isinstance(value, str) or not value.isascii() or not value.isdigit():
        return None
    try:
        descriptor = int(value, 10)
    except ValueError:
        return None
    if descriptor < 0 or str(descriptor) != value:
        return None
    return descriptor


def validate_support_run_id(value: str) -> str | None:
    """Return a run ID that can be represented by one strict status line."""
    if not isinstance(value, str) or not value or len(value) > 256:
        return None
    if "=" in value:
        return None
    if any(character.isspace() or ord(character) < 0x21 or ord(character) > 0x7E for character in value):
        return None
    return value


def validate_inherited_descriptor(
    descriptor: int,
    expected_identity: DescriptorIdentity,
) -> bool:
    """Validate the exact locked open-file description at one descriptor.

    Device and inode identity alone cannot distinguish the inherited locked
    descriptor from a separately opened descriptor for the same pathname. On
    Linux, ``flock`` locks belong to the open-file description: a duplicate of
    the locked descriptor can re-acquire the same lock, while a separate open
    is rejected while the launch parent still holds the original lock.
    """
    if descriptor < 0:
        return False
    try:
        descriptor_metadata = os.fstat(descriptor)
        proc_metadata = os.stat(f"/proc/self/fd/{descriptor}")
    except (OSError, ValueError):
        return False
    expected_device = expected_identity.device
    expected_inode = expected_identity.inode
    if not (
        descriptor_metadata.st_dev == expected_device
        and descriptor_metadata.st_ino == expected_inode
        and proc_metadata.st_dev == expected_device
        and proc_metadata.st_ino == expected_inode
    ):
        return False

    while True:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except InterruptedError:
            continue
        except OSError:
            return False


def validate_process_descriptor_identity(
    process_id: int,
    descriptor: int,
    expected_identity: DescriptorIdentity,
) -> bool:
    """Validate one exact descriptor in another process."""
    if process_id <= 1 or descriptor < 0:
        return False
    try:
        metadata = os.stat(f"/proc/{process_id}/fd/{descriptor}")
    except (OSError, ValueError):
        return False
    return (
        metadata.st_dev == expected_identity.device
        and metadata.st_ino == expected_identity.inode
    )


def read_support_status(path: str) -> SupportStatus | None:
    """Read one bounded, strictly owned support status file."""
    absolute = os.path.abspath(path)
    name = os.path.basename(absolute)
    parent_path = os.path.dirname(absolute)
    if not name or not parent_path or name in {".", ".."}:
        return None

    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
    try:
        parent = os.open(parent_path, flags)
    except OSError:
        return None

    descriptor = -1
    try:
        try:
            path_metadata = os.stat(name, dir_fd=parent, follow_symlinks=False)
        except OSError:
            return None
        if (
            stat.S_ISLNK(path_metadata.st_mode)
            or not stat.S_ISREG(path_metadata.st_mode)
            or path_metadata.st_nlink != 1
            or path_metadata.st_uid != os.geteuid()
        ):
            return None

        try:
            descriptor = os.open(
                name,
                os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
                dir_fd=parent,
            )
        except OSError:
            return None

        opened_metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened_metadata.st_mode)
            or opened_metadata.st_nlink != 1
            or opened_metadata.st_uid != os.geteuid()
            or opened_metadata.st_dev != path_metadata.st_dev
            or opened_metadata.st_ino != path_metadata.st_ino
        ):
            return None

        chunks: list[bytes] = []
        total = 0
        read_limit = SUPPORT_STATUS_READ_LIMIT + 1
        while total < read_limit:
            try:
                chunk = os.read(descriptor, min(4096, read_limit - total))
            except OSError:
                return None
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        if total > SUPPORT_STATUS_READ_LIMIT:
            return None

        try:
            final_metadata = os.stat(name, dir_fd=parent, follow_symlinks=False)
        except OSError:
            return None
        if (
            stat.S_ISLNK(final_metadata.st_mode)
            or not stat.S_ISREG(final_metadata.st_mode)
            or final_metadata.st_nlink != 1
            or final_metadata.st_uid != os.geteuid()
            or final_metadata.st_dev != opened_metadata.st_dev
            or final_metadata.st_ino != opened_metadata.st_ino
        ):
            return None

        try:
            content = b"".join(chunks).decode("utf-8", errors="strict")
        except UnicodeError:
            return None
        return parse_support_status(content)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(parent)


def parse_owner_retirement_marker(content: str) -> OwnerRetirementMarker | None:
    """Parse the strict owner-retirement request or acknowledgement marker."""
    expected_keys = (
        "schema",
        "run_id",
        "state",
        "request_id",
        "owner_pid",
        "owner_identity",
        "sentinel_pid",
        "sentinel_identity",
        "installer_pid",
        "installer_identity",
    )
    if not content.endswith("\n") or "\r" in content or "\x00" in content:
        return None
    lines = content[:-1].split("\n")
    if len(lines) != len(expected_keys):
        return None

    values: dict[str, str] = {}
    for line in lines:
        if line.count("=") != 1:
            return None
        key, value = line.split("=", 1)
        if key in values:
            return None
        values[key] = value
    if tuple(values.keys()) != expected_keys:
        return None
    if values["schema"] != str(OWNER_RETIREMENT_SCHEMA_VERSION):
        return None
    if values["state"] not in {
        OWNER_RETIREMENT_REQUEST_STATE,
        OWNER_RETIREMENT_MARKER_STATE,
        OWNER_RETIREMENT_ACK_STATE,
    }:
        return None

    run_id = validate_support_run_id(values["run_id"])
    request_id = values["request_id"]
    owner_process_id = parse_support_process_id(values["owner_pid"])
    owner_identity = parse_strict_process_identity(values["owner_identity"])
    sentinel_process_id = parse_support_process_id(values["sentinel_pid"])
    sentinel_identity = parse_strict_process_identity(values["sentinel_identity"])
    installer_process_id = parse_support_process_id(values["installer_pid"])
    installer_identity = parse_strict_process_identity(values["installer_identity"])
    if (
        run_id is None
        or len(request_id) != 64
        or not request_id.isascii()
        or any(character not in "0123456789abcdef" for character in request_id)
        or owner_process_id is None
        or owner_identity is None
        or sentinel_process_id is None
        or sentinel_identity is None
        or installer_process_id is None
        or installer_identity is None
        or owner_process_id == sentinel_process_id
        or owner_process_id == installer_process_id
        or sentinel_process_id == installer_process_id
    ):
        return None

    return OwnerRetirementMarker(
        state=values["state"],
        run_id=run_id,
        request_id=request_id,
        owner_process_id=owner_process_id,
        owner_identity=owner_identity,
        sentinel_process_id=sentinel_process_id,
        sentinel_identity=sentinel_identity,
        installer_process_id=installer_process_id,
        installer_identity=installer_identity,
    )


def encode_owner_retirement_marker(marker: OwnerRetirementMarker) -> str:
    """Encode one strict owner-retirement request or marker."""
    return (
        f"schema={OWNER_RETIREMENT_SCHEMA_VERSION}\n"
        f"run_id={marker.run_id}\n"
        f"state={marker.state}\n"
        f"request_id={marker.request_id}\n"
        f"owner_pid={marker.owner_process_id}\n"
        f"owner_identity={encode_process_identity(marker.owner_identity)}\n"
        f"sentinel_pid={marker.sentinel_process_id}\n"
        f"sentinel_identity={encode_process_identity(marker.sentinel_identity)}\n"
        f"installer_pid={marker.installer_process_id}\n"
        f"installer_identity={encode_process_identity(marker.installer_identity)}\n"
    )


def read_owner_retirement_marker(path: str) -> OwnerRetirementMarker | None:
    """Read one bounded, strictly owned owner-retirement marker."""
    absolute = os.path.abspath(path)
    name = os.path.basename(absolute)
    parent_path = os.path.dirname(absolute)
    if not name or not parent_path or name in {".", ".."}:
        return None

    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
    try:
        parent = os.open(parent_path, flags)
    except OSError:
        return None

    descriptor = -1
    try:
        try:
            path_metadata = os.stat(name, dir_fd=parent, follow_symlinks=False)
        except OSError:
            return None
        if (
            stat.S_ISLNK(path_metadata.st_mode)
            or not stat.S_ISREG(path_metadata.st_mode)
            or path_metadata.st_nlink != 1
            or path_metadata.st_uid != os.geteuid()
        ):
            return None

        try:
            descriptor = os.open(
                name,
                os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
                dir_fd=parent,
            )
        except OSError:
            return None

        opened_metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened_metadata.st_mode)
            or opened_metadata.st_nlink != 1
            or opened_metadata.st_uid != os.geteuid()
            or opened_metadata.st_dev != path_metadata.st_dev
            or opened_metadata.st_ino != path_metadata.st_ino
        ):
            return None

        chunks: list[bytes] = []
        total = 0
        read_limit = SUPPORT_STATUS_READ_LIMIT + 1
        while total < read_limit:
            try:
                chunk = os.read(descriptor, min(4096, read_limit - total))
            except OSError:
                return None
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        if total > SUPPORT_STATUS_READ_LIMIT:
            return None

        try:
            final_metadata = os.stat(name, dir_fd=parent, follow_symlinks=False)
        except OSError:
            return None
        if (
            stat.S_ISLNK(final_metadata.st_mode)
            or not stat.S_ISREG(final_metadata.st_mode)
            or final_metadata.st_nlink != 1
            or final_metadata.st_uid != os.geteuid()
            or final_metadata.st_dev != opened_metadata.st_dev
            or final_metadata.st_ino != opened_metadata.st_ino
        ):
            return None

        try:
            content = b"".join(chunks).decode("utf-8", errors="strict")
        except UnicodeError:
            return None
        return parse_owner_retirement_marker(content)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(parent)


def validate_owner_retirement_transaction(
    acknowledgement_path: str,
    marker_path: str,
    run_id: str,
    owner_process_id: int,
    owner_identity: ProcessIdentity,
    sentinel_process_id: int,
    sentinel_identity: ProcessIdentity,
    installer_process_id: int,
    installer_identity: ProcessIdentity,
) -> bool:
    """Validate one owner-retirement marker and acknowledgement transaction."""
    marker = read_owner_retirement_marker(marker_path)
    acknowledgement = read_owner_retirement_marker(acknowledgement_path)
    if (
        marker is None
        or acknowledgement is None
        or marker.state != OWNER_RETIREMENT_MARKER_STATE
        or acknowledgement.state != OWNER_RETIREMENT_ACK_STATE
    ):
        return False
    return (
        marker.run_id == run_id
        and acknowledgement.run_id == run_id
        and marker.request_id == acknowledgement.request_id
        and marker.owner_process_id == owner_process_id
        and acknowledgement.owner_process_id == owner_process_id
        and marker.owner_identity == owner_identity
        and acknowledgement.owner_identity == owner_identity
        and marker.sentinel_process_id == sentinel_process_id
        and acknowledgement.sentinel_process_id == sentinel_process_id
        and marker.sentinel_identity == sentinel_identity
        and acknowledgement.sentinel_identity == sentinel_identity
        and marker.installer_process_id == installer_process_id
        and acknowledgement.installer_process_id == installer_process_id
        and marker.installer_identity == installer_identity
        and acknowledgement.installer_identity == installer_identity
    )


def parse_support_status(content: str) -> SupportStatus | None:
    """Parse the canonical support status schema without accepting extras."""
    expected_keys = (
        "schema",
        "run_id",
        "state",
        "role",
        "installer_pid",
        "installer_identity",
        "process_pid",
        "process_identity",
        "owner_pid",
        "owner_identity",
        "peer_pid",
        "peer_identity",
        "file_fd",
        "scope_fd",
        "file_identity",
        "scope_identity",
    )
    if not content.endswith("\n") or "\r" in content or "\x00" in content:
        return None
    lines = content[:-1].split("\n")
    if len(lines) != len(expected_keys):
        return None

    values: dict[str, str] = {}
    for line in lines:
        if line.count("=") != 1:
            return None
        key, value = line.split("=", 1)
        if key in values:
            return None
        values[key] = value
    if tuple(values.keys()) != expected_keys:
        return None
    if values["schema"] != str(SUPPORT_SCHEMA_VERSION):
        return None
    if values["state"] != SUPPORT_STATE_READY:
        return None
    if values["role"] not in {SUPPORT_ROLE_OWNER, SUPPORT_ROLE_SENTINEL}:
        return None

    run_id = validate_support_run_id(values["run_id"])
    installer_process_id = parse_support_process_id(values["installer_pid"])
    installer_identity = parse_strict_process_identity(values["installer_identity"])
    process_process_id = parse_support_process_id(values["process_pid"])
    process_identity = parse_strict_process_identity(values["process_identity"])
    owner_process_id = parse_support_process_id(values["owner_pid"])
    owner_identity = parse_strict_process_identity(values["owner_identity"])
    peer_process_id = parse_support_process_id(values["peer_pid"])
    peer_identity = parse_strict_process_identity(values["peer_identity"])
    file_descriptor = parse_support_descriptor_number(values["file_fd"])
    scope_descriptor = parse_support_descriptor_number(values["scope_fd"])
    file_identity = parse_descriptor_identity(values["file_identity"])
    scope_identity = parse_descriptor_identity(values["scope_identity"])
    if any(
        item is None
        for item in (
            run_id,
            installer_process_id,
            installer_identity,
            process_process_id,
            process_identity,
            owner_process_id,
            owner_identity,
            peer_process_id,
            peer_identity,
            file_descriptor,
            scope_descriptor,
            file_identity,
            scope_identity,
        )
    ):
        return None

    if values["role"] == SUPPORT_ROLE_OWNER:
        if (
            owner_process_id != process_process_id
            or owner_identity != process_identity
            or owner_process_id == installer_process_id
            or peer_process_id == process_process_id
            or peer_process_id == installer_process_id
        ):
            return None
    elif (
        owner_process_id == process_process_id
        or owner_process_id == installer_process_id
        or process_process_id == installer_process_id
        or peer_process_id != owner_process_id
        or peer_identity != owner_identity
    ):
        return None

    return SupportStatus(
        run_id=run_id,
        role=values["role"],
        installer_process_id=installer_process_id,
        installer_identity=installer_identity,
        process_process_id=process_process_id,
        process_identity=process_identity,
        owner_process_id=owner_process_id,
        owner_identity=owner_identity,
        peer_process_id=peer_process_id,
        peer_identity=peer_identity,
        file_descriptor=file_descriptor,
        scope_descriptor=scope_descriptor,
        file_identity=file_identity,
        scope_identity=scope_identity,
    )


def encode_support_status(status: SupportStatus) -> str:
    """Encode the canonical owner/sentinel readiness status."""
    return (
        f"schema={SUPPORT_SCHEMA_VERSION}\n"
        f"run_id={status.run_id}\n"
        f"state={SUPPORT_STATE_READY}\n"
        f"role={status.role}\n"
        f"installer_pid={status.installer_process_id}\n"
        f"installer_identity={encode_process_identity(status.installer_identity)}\n"
        f"process_pid={status.process_process_id}\n"
        f"process_identity={encode_process_identity(status.process_identity)}\n"
        f"owner_pid={status.owner_process_id}\n"
        f"owner_identity={encode_process_identity(status.owner_identity)}\n"
        f"peer_pid={status.peer_process_id}\n"
        f"peer_identity={encode_process_identity(status.peer_identity)}\n"
        f"file_fd={status.file_descriptor}\n"
        f"scope_fd={status.scope_descriptor}\n"
        f"file_identity={encode_descriptor_identity(status.file_identity)}\n"
        f"scope_identity={encode_descriptor_identity(status.scope_identity)}\n"
    )


def encode_owner_retirement_ack(
    run_id: str,
    request_id: str,
    owner_process_id: int,
    owner_identity: ProcessIdentity,
    sentinel_process_id: int,
    sentinel_identity: ProcessIdentity,
    installer_process_id: int,
    installer_identity: ProcessIdentity,
) -> str:
    """Encode the atomic acknowledgement for an intentional owner retirement."""
    acknowledgement = OwnerRetirementMarker(
        state=OWNER_RETIREMENT_ACK_STATE,
        run_id=run_id,
        request_id=request_id,
        owner_process_id=owner_process_id,
        owner_identity=owner_identity,
        sentinel_process_id=sentinel_process_id,
        sentinel_identity=sentinel_identity,
        installer_process_id=installer_process_id,
        installer_identity=installer_identity,
    )
    return encode_owner_retirement_marker(acknowledgement)


def validate_support_status(
    path: str,
    role: str,
    run_id: str,
    process_process_id: int,
    process_identity: ProcessIdentity,
    owner_process_id: int,
    owner_identity: ProcessIdentity,
    peer_process_id: int,
    peer_identity: ProcessIdentity,
    installer_process_id: int,
    installer_identity: ProcessIdentity,
    file_descriptor: int,
    scope_descriptor: int,
    file_identity: DescriptorIdentity,
    scope_identity: DescriptorIdentity,
) -> bool:
    """Validate a support status and all of its live identity bindings."""
    if role not in {SUPPORT_ROLE_OWNER, SUPPORT_ROLE_SENTINEL}:
        return False
    status = read_support_status(path)
    if status is None:
        return False

    expected = SupportStatus(
        run_id=run_id,
        role=role,
        installer_process_id=installer_process_id,
        installer_identity=installer_identity,
        process_process_id=process_process_id,
        process_identity=process_identity,
        owner_process_id=owner_process_id,
        owner_identity=owner_identity,
        peer_process_id=peer_process_id,
        peer_identity=peer_identity,
        file_descriptor=file_descriptor,
        scope_descriptor=scope_descriptor,
        file_identity=file_identity,
        scope_identity=scope_identity,
    )
    if status != expected:
        return False

    for process_id, identity in (
        (installer_process_id, installer_identity),
        (process_process_id, process_identity),
        (owner_process_id, owner_identity),
        (peer_process_id, peer_identity),
    ):
        observation = observe_process_identity(process_id, identity)
        if observation != ProcessObservation.ALIVE:
            return False

    if not validate_process_descriptor_identity(
        process_process_id,
        file_descriptor,
        file_identity,
    ):
        return False
    if not validate_process_descriptor_identity(
        process_process_id,
        scope_descriptor,
        scope_identity,
    ):
        return False

    # Recheck the identities after inspecting /proc so a PID replacement
    # cannot be accepted between the first observation and descriptor checks.
    for process_id, identity in (
        (installer_process_id, installer_identity),
        (process_process_id, process_identity),
        (owner_process_id, owner_identity),
        (peer_process_id, peer_identity),
    ):
        observation = observe_process_identity(process_id, identity)
        if observation != ProcessObservation.ALIVE:
            return False

    # Re-read the file after all live checks so a replacement between the
    # initial parse and validation cannot be accepted.
    if read_support_status(path) != status:
        return False
    return True


def support_status_matches(
    status: SupportStatus,
    role: str,
    run_id: str,
    installer_process_id: int,
    installer_identity: ProcessIdentity,
    process_process_id: int,
    process_identity: ProcessIdentity,
    owner_process_id: int,
    owner_identity: ProcessIdentity,
    peer_process_id: int,
    peer_identity: ProcessIdentity,
    file_descriptor: int,
    scope_descriptor: int,
    file_identity: DescriptorIdentity,
    scope_identity: DescriptorIdentity,
) -> bool:
    """Return whether one support status has the expected static bindings."""
    return (
        status.role == role
        and status.run_id == run_id
        and status.installer_process_id == installer_process_id
        and status.installer_identity == installer_identity
        and status.process_process_id == process_process_id
        and status.process_identity == process_identity
        and status.owner_process_id == owner_process_id
        and status.owner_identity == owner_identity
        and status.peer_process_id == peer_process_id
        and status.peer_identity == peer_identity
        and status.file_descriptor == file_descriptor
        and status.scope_descriptor == scope_descriptor
        and status.file_identity == file_identity
        and status.scope_identity == scope_identity
    )


def wait_for_sentinel_binding(
    status_path: str,
    run_id: str,
    owner_process_id: int,
    owner_identity: ProcessIdentity,
    installer_process_id: int,
    installer_identity: ProcessIdentity,
    file_descriptor: int,
    scope_descriptor: int,
    file_identity: DescriptorIdentity,
    scope_identity: DescriptorIdentity,
) -> SupportStatus | None:
    """Wait for and authenticate the sentinel's strict readiness status."""
    while True:
        installer_observation = observe_process_identity(
            installer_process_id,
            installer_identity,
        )
        if installer_observation != ProcessObservation.ALIVE:
            if installer_observation == ProcessObservation.UNKNOWN:
                time.sleep(0.01)
                continue
            return None

        status = read_support_status(status_path)
        if status is None:
            time.sleep(0.01)
            continue
        if not support_status_matches(
            status,
            SUPPORT_ROLE_SENTINEL,
            run_id,
            installer_process_id,
            installer_identity,
            status.process_process_id,
            status.process_identity,
            owner_process_id,
            owner_identity,
            owner_process_id,
            owner_identity,
            file_descriptor,
            scope_descriptor,
            file_identity,
            scope_identity,
        ):
            return None

        sentinel_observation = observe_process_identity(
            status.process_process_id,
            status.process_identity,
        )
        if sentinel_observation == ProcessObservation.STOPPED:
            try:
                if not resume_process(
                    status.process_process_id,
                    status.process_identity,
                ):
                    return None
            except MonitoringUnavailable:
                time.sleep(0.01)
                continue
            time.sleep(0.01)
            continue
        if sentinel_observation != ProcessObservation.ALIVE:
            return None
        if not validate_process_descriptor_identity(
            status.process_process_id,
            file_descriptor,
            file_identity,
        ) or not validate_process_descriptor_identity(
            status.process_process_id,
            scope_descriptor,
            scope_identity,
        ):
            return None

        # Recheck the live identity and the strict status after inspecting
        # /proc so a PID or pathname replacement cannot be accepted.
        sentinel_observation = observe_process_identity(
            status.process_process_id,
            status.process_identity,
        )
        if sentinel_observation == ProcessObservation.STOPPED:
            try:
                if not resume_process(
                    status.process_process_id,
                    status.process_identity,
                ):
                    return None
            except MonitoringUnavailable:
                pass
            time.sleep(0.01)
            continue
        if sentinel_observation != ProcessObservation.ALIVE:
            return None
        if read_support_status(status_path) != status:
            return None
        return status


def read_boot_id() -> str | None:
    try:
        with open("/proc/sys/kernel/random/boot_id", "r", encoding="ascii") as boot_file:
            return boot_file.read().strip()
    except (OSError, UnicodeError):
        return None


def read_process_details_checked(
    process_id: int,
) -> tuple[str, int, int, int] | None:
    """Read process details, distinguishing absence from transient failure."""
    try:
        # The comm field is an arbitrary byte string. Parsing in binary keeps
        # an unrelated process with non-ASCII bytes from poisoning a scan of
        # the complete /proc hierarchy.
        with open(f"/proc/{process_id}/stat", "rb") as stat_file:
            status = stat_file.read()
    except (FileNotFoundError, ProcessLookupError):
        return None
    except (OSError, UnicodeError) as error:
        raise ProcessInspectionUnavailable(
            f"unable to inspect process {process_id}: {error}"
        ) from error

    command_end = status.rfind(b")")
    if command_end < 0:
        raise ProcessInspectionUnavailable(
            f"unable to parse process {process_id} details"
        )
    fields = status[command_end + 1 :].split()
    if len(fields) <= 19 or len(fields[0]) != 1:
        raise ProcessInspectionUnavailable(
            f"unable to parse process {process_id} details"
        )
    try:
        state = fields[0].decode("ascii")
        return state, int(fields[1]), int(fields[2]), int(fields[19])
    except (UnicodeError, ValueError) as error:
        raise ProcessInspectionUnavailable(
            f"unable to parse process {process_id} details"
        ) from error


def read_process_details(process_id: int) -> tuple[str, int, int, int] | None:
    try:
        return read_process_details_checked(process_id)
    except ProcessInspectionUnavailable:
        return None


def read_process_state(process_id: int) -> tuple[str, int] | None:
    details = read_process_details(process_id)
    if details is None:
        return None
    state, _parent_process_id, _process_group_id, start_time = details
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

    state, _parent_process_id, _process_group_id, start_time = details
    if state == "Z":
        return None, ProcessObservation.EXITED
    boot_id = read_boot_id()
    if not boot_id:
        return None, ProcessObservation.UNKNOWN
    identity = ProcessIdentity(start_time, boot_id)
    if state in {"T", "t"}:
        return identity, ProcessObservation.STOPPED
    return identity, ProcessObservation.ALIVE


def capture_process_identity_and_parent_observation(
    process_id: int,
    expected_parent: int,
) -> tuple[ProcessIdentity | None, ProcessObservation]:
    """Capture identity and validate PPID from one /proc stat snapshot."""
    try:
        details = read_process_details_checked(process_id)
    except ProcessInspectionUnavailable:
        return None, ProcessObservation.UNKNOWN
    if details is None:
        return None, ProcessObservation.EXITED

    state, parent_process_id, _process_group_id, start_time = details
    if state == "Z":
        return None, ProcessObservation.EXITED
    boot_id = read_boot_id()
    if not boot_id:
        return None, ProcessObservation.UNKNOWN
    if parent_process_id != expected_parent:
        return None, ProcessObservation.REPLACED
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

    state, _parent_process_id, _process_group_id, start_time = details
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

    state, parent_process_id, _process_group_id, _start_time = details
    if state == "Z":
        return ProcessObservation.EXITED
    if parent_process_id != expected_parent:
        return ProcessObservation.REPLACED
    if state in {"T", "t"}:
        return ProcessObservation.STOPPED
    return ProcessObservation.ALIVE


def observe_process_identity_and_parent(
    process_id: int,
    identity: ProcessIdentity,
    expected_parent: int,
) -> ProcessObservation:
    """Validate identity and PPID from one /proc stat snapshot."""
    try:
        details = read_process_details_checked(process_id)
    except ProcessInspectionUnavailable:
        return ProcessObservation.UNKNOWN
    if details is None:
        return ProcessObservation.EXITED

    state, parent_process_id, _process_group_id, start_time = details
    if state == "Z":
        return ProcessObservation.EXITED
    if start_time != identity.start_time:
        return ProcessObservation.REPLACED

    boot_id = read_boot_id()
    if boot_id is None:
        return ProcessObservation.UNKNOWN
    if boot_id != identity.boot_id:
        return ProcessObservation.REPLACED
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


def signal_pidfd(descriptor: int, signal_number: int) -> bool:
    """Send a signal through a pidfd without falling back to a raw PID."""
    if not hasattr(signal, "pidfd_send_signal"):
        raise MonitoringUnavailable(
            "pidfd signaling is unavailable on this system"
        )
    try:
        signal.pidfd_send_signal(descriptor, signal_number)
        return True
    except ProcessLookupError:
        return False
    except OSError as error:
        raise MonitoringUnavailable(
            f"unable to signal process through pidfd: {error}"
        ) from error


def signal_process_by_identity(
    process_id: int,
    identity: ProcessIdentity,
    signal_number: int,
) -> bool:
    """Signal a process without ever targeting a replacement PID."""
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
    if descriptor < 0:
        observation = observe_process_identity(process_id, identity)
        if observation in {
            ProcessObservation.EXITED,
            ProcessObservation.REPLACED,
        }:
            return False
        raise MonitoringUnavailable(
            f"unable to establish a verified pidfd for process {process_id}"
        )
    try:
        return signal_pidfd(descriptor, signal_number)
    finally:
        try:
            os.close(descriptor)
        except OSError:
            pass


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


def signal_process_command(
    process_id: int,
    identity: ProcessIdentity,
    signal_number: int,
) -> None:
    """Signal an identity-bound process through a verified pidfd."""
    if signal_number <= 0:
        raise ValueError("invalid signal number")
    try:
        signaled = signal_process_by_identity(
            process_id,
            identity,
            signal_number,
        )
    except MonitoringUnavailable as error:
        fail(str(error))
    if not signaled:
        raise SystemExit(1)


def resume_process_command(
    process_id: int,
    identity: ProcessIdentity,
) -> None:
    """Resume a stopped helper and require a fresh running-state observation."""
    try:
        resumed = wait_for_resumed_process_identity(process_id, identity)
    except MonitoringUnavailable as error:
        fail(str(error))
    if not resumed:
        raise SystemExit(1)


def wait_for_live_process_identity(
    process_id: int,
    expected_identity: ProcessIdentity,
    timeout: float = 1.0,
) -> bool:
    """Wait for a live identity without resuming or changing the process."""
    deadline = time.monotonic() + timeout
    while True:
        observation = observe_process_identity(process_id, expected_identity)
        if observation == ProcessObservation.ALIVE:
            return True
        if observation in {
            ProcessObservation.EXITED,
            ProcessObservation.REPLACED,
            ProcessObservation.STOPPED,
        }:
            return False
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.01)


def wait_for_resumed_process_identity(
    process_id: int,
    expected_identity: ProcessIdentity,
    timeout: float = 1.0,
) -> bool:
    """Resume a helper and wait for a fresh running-state observation."""
    deadline = time.monotonic() + timeout
    while True:
        observation = observe_process_identity(process_id, expected_identity)
        if observation == ProcessObservation.ALIVE:
            return True
        if observation == ProcessObservation.STOPPED:
            try:
                if not resume_process(process_id, expected_identity):
                    return False
            except MonitoringUnavailable:
                if time.monotonic() >= deadline:
                    return False
                time.sleep(0.01)
                continue
            # Signal delivery is not readiness. Continue until the helper is
            # freshly observed in the running state.
            if time.monotonic() >= deadline:
                return False
            time.sleep(0.01)
            continue
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
        if expected_identity is not None:
            observation = observe_process_identity_and_parent(
                process_id,
                expected_identity,
                expected_parent,
            )
        else:
            observation = observe_parent_relationship(
                process_id,
                expected_parent,
            )
        if observation == ProcessObservation.ALIVE:
            return True
        if observation == ProcessObservation.STOPPED:
            if expected_identity is not None:
                try:
                    if not resume_process(process_id, expected_identity):
                        return False
                except MonitoringUnavailable:
                    pass
                # Delivery of SIGCONT is not readiness. Re-observe the helper
                # until its identity and parent relationship are both live.
                if time.monotonic() >= deadline:
                    return False
                time.sleep(0.01)
                continue
        if observation in {
            ProcessObservation.EXITED,
            ProcessObservation.REPLACED,
        }:
            return False
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
        (installer_process_id, installer_identity),
    ]
    relationship_checks = [
        (
            status.wrapper_process_id,
            status.wrapper_identity,
            installer_process_id,
        ),
        (
            status.supervisor_process_id,
            status.supervisor_identity,
            status.wrapper_process_id,
        ),
        (
            status.worker_process_id,
            status.worker_identity,
            status.supervisor_process_id,
        ),
    ]
    if require_watchdog_parent:
        relationship_checks.append(
            (
                status.watchdog_process_id,
                status.watchdog_identity,
                status.supervisor_process_id,
            )
        )
    else:
        identity_checks.append(
            (status.watchdog_process_id, status.watchdog_identity)
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

    for process_id, identity, expected_parent in relationship_checks:
        observation = observe_process_identity_and_parent(
            process_id,
            identity,
            expected_parent,
        )
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
                target.pidfd_attempted = False
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
                        target.pidfd_attempted = False
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
            target.pidfd_attempted = False
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
            target.pidfd_attempted = False
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

    def resume_stopped_targets(self) -> None:
        """Resume stopped siblings before a monitor releases its descriptor."""
        for target in self.targets:
            if target.exited or target.label == "installer":
                continue
            if target.identity is None:
                continue
            observation = observe_process_identity(
                target.process_id,
                target.identity,
            )
            if observation == ProcessObservation.STOPPED:
                self.resume(target)

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
                    self.resume_stopped_targets()
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
                self.resume_stopped_targets()
                return None

            if self.descriptor_count == 0:
                time.sleep(0.1)
                continue

            events = self.poller.poll(0.1)
            if events:
                for descriptor, _event in events:
                    for target in self.targets:
                        if target.descriptor == descriptor:
                            # The installer may have exited between the
                            # identity scan and the poll. Resume every
                            # stopped sibling before this monitor releases
                            # its inherited descriptor.
                            self.resume_stopped_targets()
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
            if target.descriptor < 0:
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
                self.try_open_descriptor(target)
                if target.exited:
                    return False
                if target.descriptor < 0:
                    raise MonitoringUnavailable(
                        f"unable to establish a verified pidfd for {label} "
                        f"process {target.process_id}"
                    )
            if not hasattr(signal, "pidfd_send_signal"):
                raise MonitoringUnavailable(
                    "pidfd signaling is unavailable on this system"
                )
            try:
                signal.pidfd_send_signal(target.descriptor, signal_number)
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
                    self.resume_stopped_targets()
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
                        self.resume_stopped_targets()
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


def signal_unidentified_child(process_id: int, signal_number: int) -> bool:
    """Signal an unreaped child whose PID is still reserved."""
    while True:
        try:
            waited_process_id, _status = os.waitpid(process_id, os.WNOHANG)
        except ChildProcessError:
            return False
        except InterruptedError:
            continue
        if waited_process_id == process_id:
            return False
        break

    descriptor = -1
    try:
        descriptor = os.pidfd_open(process_id)
    except (AttributeError, OSError):
        descriptor = -1
    try:
        if descriptor >= 0 and hasattr(signal, "pidfd_send_signal"):
            try:
                signal.pidfd_send_signal(descriptor, signal_number)
                return True
            except ProcessLookupError:
                return False
            except OSError:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
                descriptor = -1

        # The child has not been reaped, so its PID cannot be reused. This is
        # the only raw-PID signaling path in the helper.
        try:
            os.kill(process_id, signal_number)
            return True
        except ProcessLookupError:
            return False
    finally:
        if descriptor >= 0:
            try:
                os.close(descriptor)
            except OSError:
                pass


def terminate_unidentified_child(process_id: int) -> None:
    """Terminate an unreaped child when no identity was captured.

    A child PID cannot be reused until its parent reaps it. The initial
    nonblocking wait therefore establishes that a raw signal is still safe;
    a child that was already reaped is never signaled.
    """
    while True:
        try:
            waited_process_id, _status = os.waitpid(process_id, os.WNOHANG)
        except ChildProcessError:
            return
        except InterruptedError:
            continue
        if waited_process_id == process_id:
            return
        break

    if not signal_unidentified_child(process_id, signal.SIGUSR2):
        return
    if reap_child(process_id):
        return

    signal_unidentified_child(process_id, signal.SIGKILL)
    reap_child(process_id)


def terminate_process_by_identity(
    process_id: int,
    identity: ProcessIdentity,
    deadline: float | None = None,
) -> bool:
    """Terminate one process without signaling a reused PID."""
    observation = observe_process_identity(process_id, identity)
    if observation in {
        ProcessObservation.EXITED,
        ProcessObservation.REPLACED,
    }:
        return True
    if observation == ProcessObservation.UNKNOWN:
        raise MonitoringUnavailable(
            f"unable to verify process {process_id} before termination"
        )

    if not signal_process_by_identity(
        process_id,
        identity,
        signal.SIGKILL,
    ):
        return True

    if deadline is None:
        deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        observation = observe_process_identity(process_id, identity)
        if observation in {
            ProcessObservation.EXITED,
            ProcessObservation.REPLACED,
        }:
            return True
        time.sleep(0.01)
    return False


def read_process_group_members(
    process_group_id: int,
) -> tuple[dict[int, ProcessIdentity], bool]:
    """Return live identities in a dedicated helper process group."""
    boot_id = read_boot_id()
    if not boot_id:
        return {}, True

    members: dict[int, ProcessIdentity] = {}
    unknown = False
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        process_id = int(entry)
        try:
            details = read_process_details_checked(process_id)
        except ProcessInspectionUnavailable:
            # A failed stat read does not establish target-group membership.
            # getpgid can still distinguish an unrelated process from a
            # target-group member without trusting a second stat snapshot.
            try:
                observed_group_id = os.getpgid(process_id)
            except (FileNotFoundError, ProcessLookupError):
                continue
            except (AttributeError, OSError):
                unknown = True
                continue
            if observed_group_id == process_group_id:
                # The target-group membership is known, but its identity is
                # not. Keep the scan conservative until a later snapshot can
                # establish both values.
                unknown = True
            continue
        if details is None:
            continue
        state, _parent_process_id, group_id, start_time = details
        if group_id != process_group_id:
            continue
        if state in {"Z", "X", "x"}:
            continue
        members[process_id] = ProcessIdentity(start_time, boot_id)
    return members, unknown


def process_holds_lock_inode(
    process_id: int,
    lock_device: int,
    lock_inode: int,
) -> tuple[bool, bool]:
    """Return whether a process holds an exact lock inode."""
    descriptor_directory = f"/proc/{process_id}/fd"
    try:
        entries = os.listdir(descriptor_directory)
    except (FileNotFoundError, ProcessLookupError):
        return False, False
    except OSError:
        return False, True

    unknown = False
    for entry in entries:
        if not entry.isdigit():
            continue
        try:
            metadata = os.stat(f"{descriptor_directory}/{entry}")
        except (FileNotFoundError, ProcessLookupError):
            continue
        except OSError:
            unknown = True
            continue
        if (
            metadata.st_dev == lock_device
            and metadata.st_ino == lock_inode
            and stat.S_ISREG(metadata.st_mode)
        ):
            return True, unknown
    return False, unknown


def open_group_anchor_pidfd(
    process_id: int,
    identity: ProcessIdentity,
) -> int:
    """Open an anchor pidfd, retrying transient acquisition failures."""
    for _ in range(3):
        descriptor = open_verified_pidfd(process_id, identity)
        if descriptor >= 0:
            return descriptor
        observation = observe_process_identity(process_id, identity)
        if observation in {
            ProcessObservation.EXITED,
            ProcessObservation.REPLACED,
        }:
            return -1
        if observation == ProcessObservation.UNKNOWN:
            time.sleep(0.01)
            continue
        time.sleep(0.01)
    raise MonitoringUnavailable(
        f"unable to establish a verified pidfd for process group anchor {process_id}"
    )


def stop_process_group_anchor(
    anchor: ProcessGroupAnchor,
    process_group_id: int,
    lock_device: int | None = None,
    lock_inode: int | None = None,
) -> bool:
    """Stop and validate the process that anchors a helper group."""
    observation = observe_process_identity(
        anchor.process_id,
        anchor.identity,
    )
    if observation in {
        ProcessObservation.EXITED,
        ProcessObservation.REPLACED,
    }:
        return False
    if observation == ProcessObservation.UNKNOWN:
        raise MonitoringUnavailable(
            f"unable to verify process group anchor {anchor.process_id}"
        )

    stopped_by_us = False
    if observation == ProcessObservation.ALIVE:
        if not signal_pidfd(anchor.descriptor, signal.SIGSTOP):
            return False
        stopped_by_us = True

    deadline = time.monotonic() + 1.0
    while True:
        observation = observe_process_identity(
            anchor.process_id,
            anchor.identity,
        )
        if observation == ProcessObservation.STOPPED:
            break
        if observation in {
            ProcessObservation.EXITED,
            ProcessObservation.REPLACED,
        }:
            return False
        if observation == ProcessObservation.UNKNOWN:
            if time.monotonic() >= deadline:
                if stopped_by_us:
                    try:
                        signal_pidfd(anchor.descriptor, signal.SIGCONT)
                    except MonitoringUnavailable:
                        pass
                raise MonitoringUnavailable(
                    f"unable to verify process group anchor {anchor.process_id}"
                )
            time.sleep(0.01)
            continue
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.01)

    valid = True
    try:
        details = read_process_details_checked(anchor.process_id)
    except ProcessInspectionUnavailable as error:
        if stopped_by_us:
            try:
                signal_pidfd(anchor.descriptor, signal.SIGCONT)
            except MonitoringUnavailable:
                pass
        raise MonitoringUnavailable(
            f"unable to inspect process group anchor {anchor.process_id}"
        ) from error
    if details is None:
        valid = False
    else:
        _state, _parent_process_id, group_id, start_time = details
        boot_id = read_boot_id()
        if (
            group_id != process_group_id
            or start_time != anchor.identity.start_time
            or boot_id != anchor.identity.boot_id
        ):
            valid = False

    if valid and lock_device is not None and lock_inode is not None:
        holds_lock, unknown = process_holds_lock_inode(
            anchor.process_id,
            lock_device,
            lock_inode,
        )
        if unknown and not holds_lock:
            if stopped_by_us:
                try:
                    signal_pidfd(anchor.descriptor, signal.SIGCONT)
                except MonitoringUnavailable:
                    pass
            raise MonitoringUnavailable(
                f"unable to inspect the lock inode held by process "
                f"{anchor.process_id}"
            )
        if not holds_lock:
            valid = False

    if not valid and stopped_by_us:
        try:
            signal_pidfd(anchor.descriptor, signal.SIGCONT)
        except MonitoringUnavailable:
            pass
    return valid


def find_lock_inode_group_anchor(
    process_group_id: int,
    lock_device: int,
    lock_inode: int,
) -> ProcessGroupAnchor | None:
    """Find a group member that holds the original lock inode."""
    members, scan_unknown = read_process_group_members(process_group_id)
    fd_unknown = False
    for process_id, identity in sorted(members.items()):
        holds_lock, unknown = process_holds_lock_inode(
            process_id,
            lock_device,
            lock_inode,
        )
        fd_unknown = fd_unknown or unknown
        if not holds_lock:
            continue

        descriptor = open_group_anchor_pidfd(process_id, identity)
        if descriptor < 0:
            continue
        anchor = ProcessGroupAnchor(process_id, identity, descriptor)
        keep_descriptor = False
        try:
            if stop_process_group_anchor(
                anchor,
                process_group_id,
                lock_device,
                lock_inode,
            ):
                keep_descriptor = True
                return anchor
        finally:
            if not keep_descriptor:
                try:
                    os.close(descriptor)
                except OSError:
                    pass

    if scan_unknown or fd_unknown:
        raise MonitoringUnavailable(
            f"unable to establish whether helper process group "
            f"{process_group_id} still holds the original lock inode"
        )
    return None


def establish_process_group_anchor(
    process_group_id: int,
    expected_guardian_identity: ProcessIdentity | None,
    lock_device: int | None,
    lock_inode: int | None,
) -> ProcessGroupAnchor | None:
    """Establish a non-recycled helper group without using a raw PID."""
    if expected_guardian_identity is not None:
        observation = observe_process_identity(
            process_group_id,
            expected_guardian_identity,
        )
        if observation in {
            ProcessObservation.ALIVE,
            ProcessObservation.STOPPED,
        }:
            try:
                details = read_process_details_checked(process_group_id)
            except ProcessInspectionUnavailable as error:
                raise MonitoringUnavailable(
                    f"unable to inspect helper group leader {process_group_id}"
                ) from error
            if details is not None and details[2] == process_group_id:
                descriptor = open_group_anchor_pidfd(
                    process_group_id,
                    expected_guardian_identity,
                )
                if descriptor >= 0:
                    anchor = ProcessGroupAnchor(
                        process_group_id,
                        expected_guardian_identity,
                        descriptor,
                    )
                    keep_descriptor = False
                    try:
                        if stop_process_group_anchor(
                            anchor,
                            process_group_id,
                        ):
                            keep_descriptor = True
                            return anchor
                    finally:
                        if not keep_descriptor:
                            try:
                                os.close(descriptor)
                            except OSError:
                                pass
        elif observation == ProcessObservation.UNKNOWN and (
            lock_device is None or lock_inode is None
        ):
            raise MonitoringUnavailable(
                f"unable to verify helper group leader {process_group_id}"
            )

    if lock_device is None or lock_inode is None:
        return None
    return find_lock_inode_group_anchor(
        process_group_id,
        lock_device,
        lock_inode,
    )


def merge_process_group_members(
    members: dict[int, ProcessIdentity],
    known: dict[int, ProcessIdentity],
) -> bool:
    """Merge observed members while rejecting a reused process ID."""
    for process_id, identity in members.items():
        previous_identity = known.get(process_id)
        if previous_identity is not None and previous_identity != identity:
            return False
        known[process_id] = identity
    return True


def verify_process_group_empty(process_group_id: int) -> bool:
    """Return true only when no live process remains in a helper group."""
    if process_group_id <= 1:
        return False
    if os.getpgrp() == process_group_id:
        return False
    members, unknown = read_process_group_members(process_group_id)
    return not members and not unknown


def terminate_process_group(
    process_group_id: int,
    expected_guardian_identity: ProcessIdentity | None = None,
    lock_device: int | None = None,
    lock_inode: int | None = None,
) -> bool:
    """Terminate every live member of a dedicated helper process group."""
    if process_group_id <= 1:
        return False
    if os.getpgrp() == process_group_id:
        raise MonitoringUnavailable(
            "refusing to terminate the installer's own process group"
        )
    if (lock_device is None) != (lock_inode is None):
        raise ValueError("lock device and inode must be provided together")
    if lock_device is not None and (
        lock_device < 0 or lock_inode is None or lock_inode <= 0
    ):
        raise ValueError("invalid lock device or inode")

    anchor = establish_process_group_anchor(
        process_group_id,
        expected_guardian_identity,
        lock_device,
        lock_inode,
    )
    if anchor is None:
        return False

    known: dict[int, ProcessIdentity] = {
        anchor.process_id: anchor.identity,
    }
    try:
        stabilize_deadline = time.monotonic() + 3.0
        termination_deadline = time.monotonic() + 5.0

        # Freeze the complete group before killing it. A stopped process
        # cannot fork, and SIGKILL works on stopped processes, so this closes
        # the race in which a helper could create a new descriptor owner.
        while time.monotonic() < stabilize_deadline:
            anchor_observation = observe_process_identity(
                anchor.process_id,
                anchor.identity,
            )
            if anchor_observation in {
                ProcessObservation.EXITED,
                ProcessObservation.REPLACED,
            }:
                return False
            if anchor_observation == ProcessObservation.UNKNOWN:
                raise MonitoringUnavailable(
                    f"unable to verify helper group anchor {anchor.process_id}"
                )

            members, unknown = read_process_group_members(process_group_id)
            anchor_identity = members.get(anchor.process_id)
            if anchor_identity != anchor.identity:
                return False
            if not merge_process_group_members(members, known):
                return False

            for process_id, identity in sorted(
                members.items(),
                key=lambda item: item[0] != anchor.process_id,
            ):
                observation = observe_process_identity(process_id, identity)
                if observation != ProcessObservation.ALIVE:
                    continue
                try:
                    signal_process_by_identity(
                        process_id,
                        identity,
                        signal.SIGSTOP,
                    )
                except MonitoringUnavailable:
                    unknown = True

            time.sleep(0.01)
            current, current_unknown = read_process_group_members(process_group_id)
            unknown = unknown or current_unknown
            if current.get(anchor.process_id) != anchor.identity:
                return False
            if not merge_process_group_members(current, known):
                return False
            if unknown:
                continue

            all_stopped = True
            for process_id, identity in current.items():
                observation = observe_process_identity(process_id, identity)
                if observation != ProcessObservation.STOPPED:
                    all_stopped = False
                    break
            if all_stopped:
                break

        # Keep the anchor alive until every other member is stopped and
        # terminated. While it remains in the group, the numeric group ID
        # cannot be recycled.
        while time.monotonic() < termination_deadline:
            anchor_observation = observe_process_identity(
                anchor.process_id,
                anchor.identity,
            )
            if anchor_observation in {
                ProcessObservation.EXITED,
                ProcessObservation.REPLACED,
            }:
                return False
            if anchor_observation == ProcessObservation.UNKNOWN:
                raise MonitoringUnavailable(
                    f"unable to verify helper group anchor {anchor.process_id}"
                )

            members, unknown = read_process_group_members(process_group_id)
            if unknown:
                time.sleep(0.01)
                continue
            if members.get(anchor.process_id) != anchor.identity:
                return False
            if not merge_process_group_members(members, known):
                return False

            all_stopped = True
            for process_id, identity in members.items():
                observation = observe_process_identity(process_id, identity)
                if observation == ProcessObservation.ALIVE:
                    all_stopped = False
                    try:
                        signal_process_by_identity(
                            process_id,
                            identity,
                            signal.SIGSTOP,
                        )
                    except MonitoringUnavailable:
                        pass
                elif observation == ProcessObservation.UNKNOWN:
                    all_stopped = False
                elif observation == ProcessObservation.REPLACED:
                    return False
            if not all_stopped:
                time.sleep(0.01)
                continue

            # Terminate every known non-anchor member through its verified
            # identity. Members that already exited need no signal.
            for process_id, identity in known.items():
                if process_id == anchor.process_id:
                    continue
                observation = observe_process_identity(process_id, identity)
                if observation not in {
                    ProcessObservation.ALIVE,
                    ProcessObservation.STOPPED,
                }:
                    continue
                try:
                    signal_process_by_identity(
                        process_id,
                        identity,
                        signal.SIGKILL,
                    )
                except MonitoringUnavailable:
                    pass

            current, current_unknown = read_process_group_members(process_group_id)
            if current_unknown:
                time.sleep(0.01)
                continue
            if current.get(anchor.process_id) != anchor.identity:
                return False
            if not merge_process_group_members(current, known):
                return False

            non_anchor_live = False
            for process_id, identity in known.items():
                if process_id == anchor.process_id:
                    continue
                observation = observe_process_identity(process_id, identity)
                if observation in {
                    ProcessObservation.ALIVE,
                    ProcessObservation.STOPPED,
                }:
                    non_anchor_live = True
                    break
                if observation == ProcessObservation.UNKNOWN:
                    non_anchor_live = True
                    break
            if non_anchor_live or any(
                process_id != anchor.process_id
                for process_id in current
            ):
                time.sleep(0.01)
                continue

            # The anchor is killed last. After it exits, no further signal is
            # sent by numeric group ID: a newly created process group with the
            # same number must never be mistaken for the original group.
            try:
                signal_process_by_identity(
                    anchor.process_id,
                    anchor.identity,
                    signal.SIGKILL,
                )
            except MonitoringUnavailable:
                time.sleep(0.01)
                continue

            anchor_exited = False
            while time.monotonic() < termination_deadline:
                observation = observe_process_identity(
                    anchor.process_id,
                    anchor.identity,
                )
                if observation in {
                    ProcessObservation.EXITED,
                    ProcessObservation.REPLACED,
                }:
                    anchor_exited = True
                    break
                if observation == ProcessObservation.UNKNOWN:
                    time.sleep(0.01)
                    continue
                try:
                    signal_process_by_identity(
                        anchor.process_id,
                        anchor.identity,
                        signal.SIGKILL,
                    )
                except MonitoringUnavailable:
                    pass
                time.sleep(0.01)
            if not anchor_exited:
                return False

            # Require a confirmed empty group, but do not signal anything
            # after the generation anchor has exited.
            while True:
                remaining, remaining_unknown = read_process_group_members(
                    process_group_id
                )
                if remaining:
                    return False
                if not remaining_unknown:
                    return True
                if time.monotonic() >= termination_deadline:
                    return False
                time.sleep(0.01)
    finally:
        try:
            os.close(anchor.descriptor)
        except OSError:
            pass


def terminate_child(
    process_id: int,
    expected_identity: ProcessIdentity | None = None,
) -> None:
    """Stop a child without signaling a process that reused its PID."""
    if expected_identity is None:
        terminate_unidentified_child(process_id)
        return

    observation = observe_process_identity(process_id, expected_identity)
    if observation in {
        ProcessObservation.EXITED,
        ProcessObservation.REPLACED,
    }:
        reap_child(process_id)
        return

    if observation == ProcessObservation.STOPPED:
        try:
            if not resume_process(process_id, expected_identity):
                reap_child(process_id)
                return
        except MonitoringUnavailable:
            pass

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
    if WATCHDOG_DECISION_STATE in {DECISION_COMMITTED, DECISION_CANCELLED}:
        decision = WATCHDOG_DECISION_STATE
    else:
        decision = observe_decision(DECISION_PATH)
        WATCHDOG_DECISION_STATE = decision
    if decision == DECISION_CANCELLED:
        WATCHDOG_CANCELLATION_REQUESTED = True
    return WATCHDOG_CANCELLATION_REQUESTED


def watchdog_abort_observed() -> bool:
    """Return the sticky generic-abort state established by SIGUSR2."""
    return WATCHDOG_ABORT_REQUESTED


def watchdog_shutdown_requested() -> bool:
    """Return true for either a cancellation or a sticky generic abort."""
    if watchdog_abort_observed():
        return True
    return watchdog_cancellation_observed()


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
    expected_relationships = [
        (guardian_process_id, guardian_identity, installer_process_id),
        (supervisor_process_id, supervisor_identity, guardian_process_id),
        (worker_process_id, worker_identity, supervisor_process_id),
    ]

    unknown = False
    observation = watchdog_process_observation(
        installer_process_id,
        installer_identity,
    )
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
        # The installer owns its process state. Helpers never resume it; a
        # stopped installer is simply not ready for helper startup.

    for process_id, identity, expected_parent in expected_relationships:
        observation = observe_process_identity_and_parent(
            process_id,
            identity,
            expected_parent,
        )
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
                    if not wait_for_parent_relationship(
                        process_id,
                        expected_parent,
                        identity,
                    ):
                        unknown = True
                except MonitoringUnavailable:
                    unknown = True

    current_identity, observation = capture_process_identity_and_parent_observation(
        os.getpid(),
        supervisor_process_id,
    )
    if observation in {
        ProcessObservation.EXITED,
        ProcessObservation.REPLACED,
    }:
        return False, True
    if observation == ProcessObservation.UNKNOWN or current_identity is None:
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
    helper_relationships = [
        (guardian_process_id, guardian_identity, installer_process_id),
        (supervisor_process_id, supervisor_identity, guardian_process_id),
        (worker_process_id, worker_identity, supervisor_process_id),
    ]
    for process_id, identity, expected_parent in helper_relationships:
        observation = observe_process_identity_and_parent(
            process_id,
            identity,
            expected_parent,
        )
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

    _current_identity, observation = capture_process_identity_and_parent_observation(
        os.getpid(),
        supervisor_process_id,
    )
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
        if (
            not hasattr(os, "pidfd_open")
            or not hasattr(signal, "pidfd_send_signal")
        ):
            raise MonitoringUnavailable(
                "pidfd signaling is unavailable on this system"
            )

        descriptor = open_verified_installer_pidfd(
            installer_process_id,
            installer_identity,
        )
        if descriptor >= 0:
            try:
                if signal_pidfd(descriptor, signal.SIGUSR1):
                    return True
                return False
            except MonitoringUnavailable:
                pass
            finally:
                try:
                    os.close(descriptor)
                except OSError:
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

        if watchdog_shutdown_requested():
            if not ready_published:
                close_watchdog_ready(ready_descriptor)
            notify_watchdog_installer(
                None,
                installer_process_id,
                installer_identity,
            )
            wait_for_watchdog_installer_exit(
                installer_process_id,
                installer_identity,
            )
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
            if watchdog_shutdown_requested():
                notify_watchdog_installer(
                    monitor,
                    installer_process_id,
                    installer_identity,
                )
                wait_for_watchdog_installer_exit(
                    installer_process_id,
                    installer_identity,
                    monitor,
                )
                return

            try:
                exited = monitor.wait(
                    raise_on_cancellation=False,
                    interruption_callback=watchdog_shutdown_requested,
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
                if watchdog_shutdown_requested():
                    notify_watchdog_installer(
                        monitor,
                        installer_process_id,
                        installer_identity,
                    )
                    wait_for_watchdog_installer_exit(
                        installer_process_id,
                        installer_identity,
                        monitor,
                    )
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
    if not wait_for_live_process_identity(installer_process_id, installer_identity):
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

    installer_exited = False
    try:
        exited = monitor.wait()
        if exited is None:
            raise MonitoringUnavailable("worker status validation failed")
        if exited.label == "installer":
            installer_exited = True
        else:
            decision = observe_decision(DECISION_PATH)
            if decision == DECISION_CANCELLED:
                # The cancellation decision must remain authoritative until
                # the guardian and installer have observed it. Removing it
                # here would let a later installer claim "committed" after a
                # cancellation had already won the atomic decision.
                return
            if signal_installer_loss(monitor):
                monitor.wait_for("installer")
            installer_exited = True
    finally:
        monitor.close()
    if installer_exited:
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
            decision = observe_decision(DECISION_PATH)
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
            decision = observe_decision(DECISION_PATH)
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


def establish_support_process_group(
    isolated_process_ids: tuple[int, ...] = (),
) -> int:
    """Create an independent support process group, tolerating job control.

    With Bash job control enabled, a background child may already be its
    process-group leader. ``setsid(2)`` then fails with ``EPERM`` even though
    the child already owns a singleton group. That case is accepted only when
    the child is still the leader of its own group.
    """
    previous_group_id = os.getpgid(0)
    setsid_succeeded = True
    try:
        os.setsid()
    except OSError as error:
        setsid_succeeded = False
        if error.errno != errno.EPERM or os.getpgid(0) != os.getpid():
            raise

    process_group_id = os.getpgid(0)
    if process_group_id != os.getpid():
        raise MonitoringUnavailable(
            "support process did not establish an independent process group"
        )
    if setsid_succeeded and process_group_id == previous_group_id:
        raise MonitoringUnavailable(
            "support process remained in its launch process group"
        )

    for process_id in isolated_process_ids:
        try:
            other_group_id = os.getpgid(process_id)
        except (ProcessLookupError, OSError):
            continue
        if other_group_id == process_group_id:
            raise MonitoringUnavailable(
                f"support process shares a process group with process {process_id}"
            )

    # The launch parent represents the helper guardian group in normal use.
    # It must not share the support process's singleton group either.
    try:
        parent_group_id = os.getpgid(os.getppid())
    except (ProcessLookupError, OSError):
        parent_group_id = -1
    if parent_group_id == process_group_id:
        raise MonitoringUnavailable(
            "support process shares a process group with its helper guardian"
        )
    return process_group_id


def hold_owner_with_monitor(
    installer_process_id: int,
    installer_identity: ProcessIdentity,
    monitor: ProcessMonitor,
    run_id: str | None = None,
    retirement_marker_path: str | None = None,
    owner_identity: ProcessIdentity | None = None,
) -> None:
    """Retain the locks while monitoring the installer and optional sentinel."""
    global OWNER_RETIREMENT_REQUESTED

    installer_target = monitored_target(monitor, "installer")
    sentinel_target = next(
        (target for target in monitor.targets if target.label == "sentinel"),
        None,
    )

    while True:
        if installer_target.exited:
            return
        if sentinel_target is not None and sentinel_target.exited:
            notify_installer_with_pidfd(monitor, SIGSUPPORT_LOSS)
            wait_for_sentinel_installer_exit(monitor)
            return

        if OWNER_RETIREMENT_REQUESTED:
            if (
                sentinel_target is None
                or sentinel_target.identity is None
                or owner_identity is None
                or run_id is None
                or retirement_marker_path is None
            ):
                OWNER_RETIREMENT_REQUESTED = False
                continue

            sentinel_observation = observe_process_identity(
                sentinel_target.process_id,
                sentinel_target.identity,
            )
            if sentinel_observation == ProcessObservation.STOPPED:
                if monitor.resume(sentinel_target) is not False:
                    time.sleep(0.01)
                    continue
                notify_installer_with_pidfd(monitor, SIGSUPPORT_LOSS)
                wait_for_sentinel_installer_exit(monitor)
                return
            if sentinel_observation != ProcessObservation.ALIVE:
                if sentinel_observation in {
                    ProcessObservation.EXITED,
                    ProcessObservation.REPLACED,
                }:
                    monitor.mark_exited(sentinel_target)
                notify_installer_with_pidfd(monitor, SIGSUPPORT_LOSS)
                wait_for_sentinel_installer_exit(monitor)
                return

            request = read_owner_retirement_marker(retirement_marker_path)
            if request is None:
                # The sentinel publishes the request before signaling the
                # owner. A transient read failure is not permission to retire
                # the owner without an authenticated request.
                time.sleep(0.01)
                continue
            if (
                request.state != OWNER_RETIREMENT_REQUEST_STATE
                or request.run_id != run_id
                or request.owner_process_id != os.getpid()
                or request.owner_identity != owner_identity
                or request.sentinel_process_id != sentinel_target.process_id
                or request.sentinel_identity != sentinel_target.identity
                or request.installer_process_id != installer_process_id
                or request.installer_identity != installer_identity
            ):
                # Ignore a stale or unrelated request. The owner remains the
                # final descriptor holder and continues monitoring normally.
                OWNER_RETIREMENT_REQUESTED = False
                continue

            marker = OwnerRetirementMarker(
                state=OWNER_RETIREMENT_MARKER_STATE,
                run_id=request.run_id,
                request_id=request.request_id,
                owner_process_id=request.owner_process_id,
                owner_identity=request.owner_identity,
                sentinel_process_id=request.sentinel_process_id,
                sentinel_identity=request.sentinel_identity,
                installer_process_id=request.installer_process_id,
                installer_identity=request.installer_identity,
            )
            write_status(
                retirement_marker_path,
                encode_owner_retirement_marker(marker),
            )
            return

        for target in monitor.targets:
            if target.exited or target.identity is None:
                continue
            observation = observe_process_identity(
                target.process_id,
                target.identity,
            )
            if observation in {
                ProcessObservation.EXITED,
                ProcessObservation.REPLACED,
            }:
                monitor.mark_exited(target)
                continue
            if observation == ProcessObservation.STOPPED:
                if target.label == "sentinel":
                    monitor.resume(target)
                continue
            if observation == ProcessObservation.ALIVE:
                monitor.try_open_descriptor(target)

        if installer_target.exited:
            return
        if sentinel_target is not None and sentinel_target.exited:
            notify_installer_with_pidfd(monitor, SIGSUPPORT_LOSS)
            wait_for_sentinel_installer_exit(monitor)
            return

        if monitor.descriptor_count == 0:
            time.sleep(0.1)
            continue
        events = monitor.poller.poll(0.1)
        for descriptor, _event in events:
            for target in monitor.targets:
                if target.descriptor == descriptor:
                    monitor.mark_exited(target)


def hold_owner(
    installer_process_id: int,
    installer_identity: ProcessIdentity,
) -> None:
    """Retain inherited locks until the verified installer exits.

    Unlike :func:`wait_for_installer`, this owner never notifies the
    installer. It observes the recorded identity and, when available, waits
    on a verified pidfd without sending even a resume signal to a stopped
    installer.
    """
    configure_signal_handlers(allow_cancellation=False)
    monitor = ProcessMonitor(
        [("installer", installer_process_id, installer_identity)]
    )
    try:
        hold_owner_with_monitor(
            installer_process_id,
            installer_identity,
            monitor,
        )
    finally:
        monitor.close()


def hold_owner_ready(
    installer_process_id: int,
    installer_identity: ProcessIdentity,
    run_id: str,
    status_path: str,
    sentinel_status_path: str,
    retirement_marker_path: str,
    file_descriptor: int,
    scope_descriptor: int,
    file_identity: DescriptorIdentity,
    scope_identity: DescriptorIdentity,
) -> None:
    """Publish a mutually bound owner and retain the inherited locks."""
    global OWNER_RETIREMENT_REQUESTED

    OWNER_RETIREMENT_REQUESTED = False
    configure_owner_signal_handlers()
    if not validate_inherited_descriptor(file_descriptor, file_identity):
        fail("inherited lock file descriptor does not match its identity")
    if not validate_inherited_descriptor(scope_descriptor, scope_identity):
        fail("inherited lock scope descriptor does not match its identity")

    establish_support_process_group((installer_process_id,))

    observation = observe_process_identity(
        installer_process_id,
        installer_identity,
    )
    if observation != ProcessObservation.ALIVE:
        fail("installer process identity is not live")

    process_process_id = os.getpid()
    process_identity = capture_process_identity(process_process_id)
    if process_identity is None:
        fail("unable to capture the lock owner identity")
    if process_process_id == installer_process_id:
        fail("owner and installer must be distinct processes")

    sentinel_status = wait_for_sentinel_binding(
        sentinel_status_path,
        run_id,
        process_process_id,
        process_identity,
        installer_process_id,
        installer_identity,
        file_descriptor,
        scope_descriptor,
        file_identity,
        scope_identity,
    )
    if sentinel_status is None:
        fail("lock sentinel did not publish a valid readiness binding")

    monitor = ProcessMonitor(
        [
            ("installer", installer_process_id, installer_identity),
            (
                "sentinel",
                sentinel_status.process_process_id,
                sentinel_status.process_identity,
            ),
        ]
    )
    try:
        require_monitored_pidfd(monitor, "installer")
        require_monitored_pidfd(monitor, "sentinel")
        if not validate_support_status(
            sentinel_status_path,
            SUPPORT_ROLE_SENTINEL,
            run_id,
            sentinel_status.process_process_id,
            sentinel_status.process_identity,
            process_process_id,
            process_identity,
            process_process_id,
            process_identity,
            installer_process_id,
            installer_identity,
            file_descriptor,
            scope_descriptor,
            file_identity,
            scope_identity,
        ):
            fail("lock sentinel readiness binding changed before owner readiness")

        status = SupportStatus(
            run_id=run_id,
            role=SUPPORT_ROLE_OWNER,
            installer_process_id=installer_process_id,
            installer_identity=installer_identity,
            process_process_id=process_process_id,
            process_identity=process_identity,
            owner_process_id=process_process_id,
            owner_identity=process_identity,
            peer_process_id=sentinel_status.process_process_id,
            peer_identity=sentinel_status.process_identity,
            file_descriptor=file_descriptor,
            scope_descriptor=scope_descriptor,
            file_identity=file_identity,
            scope_identity=scope_identity,
        )
        write_status(status_path, encode_support_status(status))
        hold_owner_with_monitor(
            installer_process_id,
            installer_identity,
            monitor,
            run_id,
            retirement_marker_path,
            process_identity,
        )
    finally:
        monitor.close()


def monitored_target(monitor: ProcessMonitor, label: str) -> MonitoredProcess:
    """Return one named target from a process monitor."""
    for target in monitor.targets:
        if target.label == label:
            return target
    raise ValueError(f"unknown monitored process: {label}")


def require_monitored_pidfd(
    monitor: ProcessMonitor,
    label: str,
) -> MonitoredProcess:
    """Require a live target with the verified pidfd opened before readiness."""
    target = monitored_target(monitor, label)
    if target.exited:
        raise MonitoringUnavailable(
            f"{label} process {target.process_id} exited before readiness"
        )
    if target.descriptor < 0:
        raise MonitoringUnavailable(
            f"unable to establish a verified pidfd for {label} process "
            f"{target.process_id}"
        )
    return target


def notify_installer_with_pidfd(
    monitor: ProcessMonitor,
    signal_number: int,
) -> bool:
    """Notify the installer through a verified pidfd until delivery or exit."""
    target = monitored_target(monitor, "installer")
    if target.identity is None:
        raise MonitoringUnavailable("installer identity is unavailable")
    while True:
        if target.exited:
            return False
        if target.descriptor < 0:
            monitor.try_open_descriptor(target)
            if target.exited:
                return False
            if target.descriptor < 0:
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
                time.sleep(0.01)
                continue
        try:
            delivered = signal_pidfd(target.descriptor, signal_number)
        except MonitoringUnavailable:
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
            time.sleep(0.01)
            continue
        if not delivered:
            monitor.mark_exited(target)
        return delivered


def notify_sentinel_installer(monitor: ProcessMonitor) -> bool:
    """Notify the installer of unexpected owner death through its pidfd.

    Transient pidfd signaling failures are retried while the sentinel retains
    its inherited locks. A definitive installer exit is distinguished from a
    transient failure; signaling never falls back to a reusable numeric PID.
    """
    return notify_installer_with_pidfd(monitor, SIGUSR3)


def wait_for_sentinel_installer_exit(monitor: ProcessMonitor) -> None:
    """Wait for installer exit without sending the installer any signal."""
    target = monitored_target(monitor, "installer")
    while not target.exited:
        observation = observe_process_identity(
            target.process_id,
            target.identity,
        )
        if observation in {
            ProcessObservation.EXITED,
            ProcessObservation.REPLACED,
        }:
            monitor.mark_exited(target)
            return
        if target.descriptor >= 0:
            monitor.poller.poll(0.1)
        else:
            time.sleep(0.1)


def retire_sentinel_owner(
    monitor: ProcessMonitor,
    owner_process_id: int,
    owner_identity: ProcessIdentity,
    teardown_ack_path: str,
    retirement_marker_path: str,
    run_id: str,
    process_process_id: int,
    process_identity: ProcessIdentity,
    installer_process_id: int,
    installer_identity: ProcessIdentity,
) -> SentinelRetirementResult:
    """Retire the owner through an acknowledged identity-bound handshake.

    The sentinel first publishes a nonce-bound request, then signals the
    owner through its verified pidfd. The owner replaces that request with a
    strict marker and exits voluntarily. Only a marker that matches the
    request and an independently confirmed owner exit can produce the final
    teardown acknowledgement.
    """
    owner_target = require_monitored_pidfd(monitor, "owner")

    def installer_exited() -> bool:
        observation = observe_process_identity(
            installer_process_id,
            installer_identity,
        )
        return observation in {
            ProcessObservation.EXITED,
            ProcessObservation.REPLACED,
        }

    observation_deadline = time.monotonic() + 1.0
    while True:
        if installer_exited():
            return SentinelRetirementResult.INSTALLER_EXITED
        observation = observe_process_identity(owner_process_id, owner_identity)
        if observation in {
            ProcessObservation.EXITED,
            ProcessObservation.REPLACED,
        }:
            # The owner was already gone when the intentional request was
            # handled. This is an unexpected owner death, not a retirement.
            return SentinelRetirementResult.OWNER_LOST
        if observation == ProcessObservation.STOPPED:
            if monitor.resume(owner_target) is False:
                return SentinelRetirementResult.OWNER_LOST
            time.sleep(0.01)
            continue
        if observation == ProcessObservation.ALIVE:
            break
        if time.monotonic() >= observation_deadline:
            return SentinelRetirementResult.OWNER_LOST
        time.sleep(0.01)

    request_id = secrets.token_hex(32)
    request = OwnerRetirementMarker(
        state=OWNER_RETIREMENT_REQUEST_STATE,
        run_id=run_id,
        request_id=request_id,
        owner_process_id=owner_process_id,
        owner_identity=owner_identity,
        sentinel_process_id=process_process_id,
        sentinel_identity=process_identity,
        installer_process_id=installer_process_id,
        installer_identity=installer_identity,
    )
    write_status(
        retirement_marker_path,
        encode_owner_retirement_marker(request),
    )

    delivery_deadline = time.monotonic() + 1.0
    while True:
        if installer_exited():
            remove_status(retirement_marker_path)
            return SentinelRetirementResult.INSTALLER_EXITED
        try:
            delivered = signal_pidfd(owner_target.descriptor, signal.SIGUSR1)
        except MonitoringUnavailable:
            delivered = False
        if delivered:
            break
        observation = observe_process_identity(owner_process_id, owner_identity)
        if observation in {
            ProcessObservation.EXITED,
            ProcessObservation.REPLACED,
        }:
            remove_status(retirement_marker_path)
            return SentinelRetirementResult.OWNER_LOST
        if time.monotonic() >= delivery_deadline:
            remove_status(retirement_marker_path)
            return SentinelRetirementResult.OWNER_LOST
        time.sleep(0.01)

    confirmation_deadline = time.monotonic() + 2.0
    while True:
        marker = read_owner_retirement_marker(retirement_marker_path)
        observation = observe_process_identity(owner_process_id, owner_identity)
        marker_matches = (
            marker is not None
            and marker.state == OWNER_RETIREMENT_MARKER_STATE
            and marker.run_id == run_id
            and marker.request_id == request_id
            and marker.owner_process_id == owner_process_id
            and marker.owner_identity == owner_identity
            and marker.sentinel_process_id == process_process_id
            and marker.sentinel_identity == process_identity
            and marker.installer_process_id == installer_process_id
            and marker.installer_identity == installer_identity
        )
        if marker_matches and observation in {
            ProcessObservation.EXITED,
            ProcessObservation.REPLACED,
        }:
            # Re-read the marker after observing the exit so a replacement
            # cannot turn an earlier acknowledgement into a false one.
            confirmed_marker = read_owner_retirement_marker(retirement_marker_path)
            if confirmed_marker != marker:
                return SentinelRetirementResult.OWNER_LOST
            write_status(
                teardown_ack_path,
                encode_owner_retirement_ack(
                    run_id,
                    request_id,
                    owner_process_id,
                    owner_identity,
                    process_process_id,
                    process_identity,
                    installer_process_id,
                    installer_identity,
                ),
            )
            return SentinelRetirementResult.RETIRED
        if observation in {
            ProcessObservation.EXITED,
            ProcessObservation.REPLACED,
        }:
            # The owner disappeared without publishing the matching marker.
            # This is unexpected owner loss, never an intentional retirement.
            remove_status(retirement_marker_path)
            return SentinelRetirementResult.OWNER_LOST
        if installer_exited():
            remove_status(retirement_marker_path)
            return SentinelRetirementResult.INSTALLER_EXITED
        if time.monotonic() >= confirmation_deadline:
            remove_status(retirement_marker_path)
            return SentinelRetirementResult.OWNER_LOST
        time.sleep(0.01)


def sentinel_loop(
    monitor: ProcessMonitor,
    owner_process_id: int,
    owner_identity: ProcessIdentity,
    teardown_ack_path: str,
    retirement_marker_path: str,
    run_id: str,
    process_process_id: int,
    process_identity: ProcessIdentity,
    installer_process_id: int,
    installer_identity: ProcessIdentity,
) -> None:
    """Monitor owner and installer, applying only the sentinel policy."""
    owner_target = monitored_target(monitor, "owner")
    installer_target = monitored_target(monitor, "installer")
    owner_terminal = False
    retirement_handled = False

    while True:
        if SENTINEL_RETIREMENT_REQUESTED and not retirement_handled:
            retirement_handled = True
            retirement_result = retire_sentinel_owner(
                monitor,
                owner_process_id,
                owner_identity,
                teardown_ack_path,
                retirement_marker_path,
                run_id,
                process_process_id,
                process_identity,
                installer_process_id,
                installer_identity,
            )
            if retirement_result == SentinelRetirementResult.RETIRED:
                owner_terminal = True
                monitor.mark_exited(owner_target)
            elif retirement_result == SentinelRetirementResult.INSTALLER_EXITED:
                monitor.mark_exited(installer_target)
                return
            else:
                # No acknowledgement is valid unless the owner authenticated
                # the request and its identity was confirmed gone.
                notify_sentinel_installer(monitor)
                wait_for_sentinel_installer_exit(monitor)
                return

        if not owner_terminal:
            observation = observe_process_identity(
                owner_process_id,
                owner_identity,
            )
            if observation in {
                ProcessObservation.EXITED,
                ProcessObservation.REPLACED,
            }:
                owner_terminal = True
                monitor.mark_exited(owner_target)
                notify_sentinel_installer(monitor)
                wait_for_sentinel_installer_exit(monitor)
                return
            if observation == ProcessObservation.STOPPED:
                # Restore the owner's ability to monitor this sentinel before
                # continuing. Otherwise a later sentinel death could occur
                # while the only other descriptor holder is unable to observe
                # it.
                if monitor.resume(owner_target) is None:
                    time.sleep(0.01)
                continue

        observation = observe_process_identity(
            installer_target.process_id,
            installer_target.identity,
        )
        if observation in {
            ProcessObservation.EXITED,
            ProcessObservation.REPLACED,
        }:
            monitor.mark_exited(installer_target)
            return
        if installer_target.descriptor >= 0:
            monitor.poller.poll(0.1)
        else:
            time.sleep(0.1)


def lock_sentinel(
    run_id: str,
    status_path: str,
    teardown_ack_path: str,
    retirement_marker_path: str,
    owner_process_id: int,
    owner_identity: ProcessIdentity,
    installer_process_id: int,
    installer_identity: ProcessIdentity,
    file_descriptor: int,
    scope_descriptor: int,
    file_identity: DescriptorIdentity,
    scope_identity: DescriptorIdentity,
) -> None:
    """Monitor the owner and notify the installer if the owner dies."""
    global SENTINEL_RETIREMENT_REQUESTED
    SENTINEL_RETIREMENT_REQUESTED = False
    configure_sentinel_signal_handlers()

    if not validate_inherited_descriptor(file_descriptor, file_identity):
        fail("inherited lock file descriptor does not match its identity")
    if not validate_inherited_descriptor(scope_descriptor, scope_identity):
        fail("inherited lock scope descriptor does not match its identity")

    establish_support_process_group(
        (owner_process_id, installer_process_id)
    )

    if owner_process_id == installer_process_id:
        fail("owner and installer must be distinct processes")

    installer_observation = observe_process_identity(
        installer_process_id,
        installer_identity,
    )
    if installer_observation != ProcessObservation.ALIVE:
        fail("installer process identity is not live")

    owner_observation = observe_process_identity(owner_process_id, owner_identity)
    if owner_observation == ProcessObservation.STOPPED:
        try:
            if not wait_for_resumed_process_identity(owner_process_id, owner_identity):
                fail("owner process identity is not live")
        except MonitoringUnavailable:
            fail("owner process identity is not live")
    elif owner_observation != ProcessObservation.ALIVE:
        fail("owner process identity is not live")

    if not hasattr(signal, "pidfd_send_signal"):
        fail("pidfd signaling is unavailable on this system")

    process_process_id = os.getpid()
    process_identity = capture_process_identity(process_process_id)
    if process_identity is None:
        fail("unable to capture the lock sentinel identity")
    if process_process_id == owner_process_id or process_process_id == installer_process_id:
        fail("sentinel, owner, and installer must be distinct processes")

    monitor = ProcessMonitor(
        [
            ("owner", owner_process_id, owner_identity),
            ("installer", installer_process_id, installer_identity),
        ]
    )
    try:
        require_monitored_pidfd(monitor, "owner")
        require_monitored_pidfd(monitor, "installer")
        status = SupportStatus(
            run_id=run_id,
            role=SUPPORT_ROLE_SENTINEL,
            installer_process_id=installer_process_id,
            installer_identity=installer_identity,
            process_process_id=process_process_id,
            process_identity=process_identity,
            owner_process_id=owner_process_id,
            owner_identity=owner_identity,
            peer_process_id=owner_process_id,
            peer_identity=owner_identity,
            file_descriptor=file_descriptor,
            scope_descriptor=scope_descriptor,
            file_identity=file_identity,
            scope_identity=scope_identity,
        )
        write_status(status_path, encode_support_status(status))
        sentinel_loop(
            monitor,
            owner_process_id,
            owner_identity,
            teardown_ack_path,
            retirement_marker_path,
            run_id,
            process_process_id,
            process_identity,
            installer_process_id,
            installer_identity,
        )
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
    global WATCHDOG_ABORT_REQUESTED
    global WATCHDOG_CANCELLATION_REQUESTED

    DECISION_PATH = decision_path
    configure_signal_handlers(allow_cancellation=True)
    if not wait_for_live_process_identity(installer_process_id, installer_identity):
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
        WATCHDOG_ABORT_REQUESTED = False
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
        decision = observe_decision(sys.argv[2])
        if decision not in {DECISION_COMMITTED, DECISION_CANCELLED}:
            raise SystemExit(1)
        print(decision)
        return

    if len(sys.argv) == 5 and sys.argv[1] == "signal-process":
        configure_signal_handlers(allow_cancellation=False)
        process_identity = parse_process_identity(sys.argv[3])
        if process_identity is None:
            fail("invalid process identity")
        signal_process_command(
            int(sys.argv[2]),
            process_identity,
            int(sys.argv[4]),
        )
        return

    if len(sys.argv) == 4 and sys.argv[1] == "resume-process":
        configure_signal_handlers(allow_cancellation=False)
        process_identity = parse_process_identity(sys.argv[3])
        if process_identity is None:
            fail("invalid process identity")
        resume_process_command(int(sys.argv[2]), process_identity)
        return

    if len(sys.argv) == 4 and sys.argv[1] == "terminate-process":
        configure_signal_handlers(allow_cancellation=False)
        process_identity = parse_process_identity(sys.argv[3])
        if process_identity is None:
            fail("invalid process identity")
        if not terminate_process_by_identity(int(sys.argv[2]), process_identity):
            raise SystemExit(1)
        return

    if len(sys.argv) in {4, 6} and sys.argv[1] == "terminate-group":
        configure_signal_handlers(allow_cancellation=False)
        process_identity = parse_process_identity(sys.argv[3])
        if process_identity is None:
            fail("invalid process identity")
        lock_device = None
        lock_inode = None
        if len(sys.argv) == 6:
            lock_device = int(sys.argv[4])
            lock_inode = int(sys.argv[5])
        if not terminate_process_group(
            int(sys.argv[2]),
            process_identity,
            lock_device,
            lock_inode,
        ):
            raise SystemExit(1)
        return

    if len(sys.argv) == 3 and sys.argv[1] == "verify-group-empty":
        configure_signal_handlers(allow_cancellation=False)
        if not verify_process_group_empty(int(sys.argv[2])):
            raise SystemExit(1)
        return

    if len(sys.argv) == 3 and sys.argv[1] == "lock-identity":
        lock_device, lock_inode = read_lock_file_identity(sys.argv[2])
        print(f"{lock_device}:{lock_inode}")
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
            f"{status.watchdog_process_id} "
            f"{encode_process_identity(status.supervisor_identity)} "
            f"{encode_process_identity(status.worker_identity)} "
            f"{encode_process_identity(status.watchdog_identity)} "
            f"{encode_process_identity(status.wrapper_identity)}"
        )
        return

    if len(sys.argv) == 4 and sys.argv[1] == "hold-owner":
        installer_identity = parse_process_identity(sys.argv[2])
        if installer_identity is None:
            fail("invalid installer process identity")
        try:
            installer_process_id = int(sys.argv[3])
        except ValueError:
            fail("invalid installer process id")
        if installer_process_id <= 1:
            fail("invalid installer process id")
        hold_owner(installer_process_id, installer_identity)
        return

    if len(sys.argv) == 12 and sys.argv[1] == "hold-owner-ready":
        installer_identity = parse_strict_process_identity(sys.argv[2])
        if installer_identity is None:
            fail("invalid installer process identity")
        installer_process_id = parse_support_process_id(sys.argv[3])
        if installer_process_id is None:
            fail("invalid installer process id")
        run_id = validate_support_run_id(sys.argv[4])
        if run_id is None:
            fail("invalid support run id")
        file_descriptor = parse_support_descriptor_number(sys.argv[8])
        scope_descriptor = parse_support_descriptor_number(sys.argv[9])
        file_identity = parse_descriptor_identity(sys.argv[10])
        scope_identity = parse_descriptor_identity(sys.argv[11])
        if (
            file_descriptor is None
            or scope_descriptor is None
            or file_identity is None
            or scope_identity is None
        ):
            fail("invalid inherited lock descriptor identity")
        hold_owner_ready(
            installer_process_id,
            installer_identity,
            run_id,
            sys.argv[5],
            sys.argv[6],
            sys.argv[7],
            file_descriptor,
            scope_descriptor,
            file_identity,
            scope_identity,
        )
        return

    if len(sys.argv) == 14 and sys.argv[1] == "lock-sentinel":
        run_id = validate_support_run_id(sys.argv[2])
        if run_id is None:
            fail("invalid support run id")
        owner_identity = parse_strict_process_identity(sys.argv[6])
        if owner_identity is None:
            fail("invalid owner process identity")
        owner_process_id = parse_support_process_id(sys.argv[7])
        if owner_process_id is None:
            fail("invalid owner process id")
        installer_identity = parse_strict_process_identity(sys.argv[8])
        if installer_identity is None:
            fail("invalid installer process identity")
        installer_process_id = parse_support_process_id(sys.argv[9])
        if installer_process_id is None:
            fail("invalid installer process id")
        file_descriptor = parse_support_descriptor_number(sys.argv[10])
        scope_descriptor = parse_support_descriptor_number(sys.argv[11])
        file_identity = parse_descriptor_identity(sys.argv[12])
        scope_identity = parse_descriptor_identity(sys.argv[13])
        if (
            file_descriptor is None
            or scope_descriptor is None
            or file_identity is None
            or scope_identity is None
        ):
            fail("invalid inherited lock descriptor identity")
        lock_sentinel(
            run_id,
            sys.argv[3],
            sys.argv[4],
            sys.argv[5],
            owner_process_id,
            owner_identity,
            installer_process_id,
            installer_identity,
            file_descriptor,
            scope_descriptor,
            file_identity,
            scope_identity,
        )
        return

    if len(sys.argv) == 11 and sys.argv[1] == "validate-owner-retirement":
        run_id = validate_support_run_id(sys.argv[4])
        owner_process_id = parse_support_process_id(sys.argv[5])
        owner_identity = parse_strict_process_identity(sys.argv[6])
        sentinel_process_id = parse_support_process_id(sys.argv[7])
        sentinel_identity = parse_strict_process_identity(sys.argv[8])
        installer_process_id = parse_support_process_id(sys.argv[9])
        installer_identity = parse_strict_process_identity(sys.argv[10])
        if (
            run_id is None
            or owner_process_id is None
            or owner_identity is None
            or sentinel_process_id is None
            or sentinel_identity is None
            or installer_process_id is None
            or installer_identity is None
        ):
            fail("invalid owner retirement transaction expectation")
        if not validate_owner_retirement_transaction(
            sys.argv[2],
            sys.argv[3],
            run_id,
            owner_process_id,
            owner_identity,
            sentinel_process_id,
            sentinel_identity,
            installer_process_id,
            installer_identity,
        ):
            raise SystemExit(1)
        return

    if len(sys.argv) == 17 and sys.argv[1] == "validate-support":
        configure_signal_handlers(allow_cancellation=False)
        if sys.argv[3] not in {SUPPORT_ROLE_OWNER, SUPPORT_ROLE_SENTINEL}:
            fail("invalid support role")
        run_id = validate_support_run_id(sys.argv[4])
        if run_id is None:
            fail("invalid support run id")
        process_process_id = parse_support_process_id(sys.argv[5])
        process_identity = parse_strict_process_identity(sys.argv[6])
        owner_process_id = parse_support_process_id(sys.argv[7])
        owner_identity = parse_strict_process_identity(sys.argv[8])
        peer_process_id = parse_support_process_id(sys.argv[9])
        peer_identity = parse_strict_process_identity(sys.argv[10])
        installer_process_id = parse_support_process_id(sys.argv[11])
        installer_identity = parse_strict_process_identity(sys.argv[12])
        file_descriptor = parse_support_descriptor_number(sys.argv[13])
        scope_descriptor = parse_support_descriptor_number(sys.argv[14])
        file_identity = parse_descriptor_identity(sys.argv[15])
        scope_identity = parse_descriptor_identity(sys.argv[16])
        if any(
            item is None
            for item in (
                process_process_id,
                process_identity,
                owner_process_id,
                owner_identity,
                peer_process_id,
                peer_identity,
                installer_process_id,
                installer_identity,
                file_descriptor,
                scope_descriptor,
                file_identity,
                scope_identity,
            )
        ):
            fail("invalid support status expectation")
        if not validate_support_status(
            sys.argv[2],
            sys.argv[3],
            run_id,
            process_process_id,
            process_identity,
            owner_process_id,
            owner_identity,
            peer_process_id,
            peer_identity,
            installer_process_id,
            installer_identity,
            file_descriptor,
            scope_descriptor,
            file_identity,
            scope_identity,
        ):
            raise SystemExit(1)
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
            "lock-holder.py lock-identity PATH or "
            "lock-holder.py signal-process PID IDENTITY SIGNAL or "
            "lock-holder.py resume-process PID IDENTITY or "
            "lock-holder.py terminate-process PID IDENTITY or "
            "lock-holder.py terminate-group PGID IDENTITY [DEVICE INODE] or "
            "lock-holder.py verify-group-empty PGID or "
            "lock-holder.py validate-status STATUS WRAPPER_PID INSTALLER_PID "
            "INSTALLER_IDENTITY or lock-holder.py hold-owner "
            "INSTALLER_IDENTITY INSTALLER_PID or lock-holder.py hold-owner-ready "
            "INSTALLER_IDENTITY INSTALLER_PID RUN_ID OWNER_STATUS_PATH "
            "SENTINEL_STATUS_PATH RETIREMENT_MARKER_PATH FILE_FD SCOPE_FD "
            "FILE_IDENTITY SCOPE_IDENTITY or lock-holder.py lock-sentinel "
            "RUN_ID STATUS_PATH TEARDOWN_ACK_PATH RETIREMENT_MARKER_PATH "
            "OWNER_IDENTITY OWNER_PID INSTALLER_IDENTITY INSTALLER_PID FILE_FD "
            "SCOPE_FD FILE_IDENTITY SCOPE_IDENTITY or lock-holder.py "
            "validate-support STATUS_PATH ROLE RUN_ID PROCESS_ID "
            "PROCESS_IDENTITY OWNER_PID OWNER_IDENTITY PEER_PID PEER_IDENTITY "
            "INSTALLER_PID INSTALLER_IDENTITY FILE_FD SCOPE_FD FILE_IDENTITY "
            "SCOPE_IDENTITY or lock-holder.py await-installer "
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
