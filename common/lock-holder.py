#!/usr/bin/env python3

# SPDX-License-Identifier: MIT

import errno
import os
import select
import signal
import stat
import sys
import time
from dataclasses import dataclass
from typing import Callable


STATUS_SCHEMA_VERSION = 2
STATUS_LINE_COUNT = 10
CANCELLATION_REQUESTED = False
COMMIT_PATH: str | None = None


def fail(message: str) -> None:
    print(f"lock-holder: {message}", file=sys.stderr)
    raise SystemExit(1)


class MonitoringUnavailable(RuntimeError):
    pass


class AcquisitionCancelled(RuntimeError):
    pass


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


@dataclass
class MonitoredProcess:
    label: str
    process_id: int
    descriptor: int = -1
    identity: ProcessIdentity | None = None
    exited: bool = False


def request_cancellation(_signal_number: int, _frame: object) -> None:
    global CANCELLATION_REQUESTED

    # USR2 is an acquisition-only cancellation signal. Once the guardian has
    # committed the acquisition, it must not release the lock merely because a
    # process group received USR2.
    if COMMIT_PATH:
        try:
            if os.path.exists(COMMIT_PATH):
                return
        except OSError:
            pass
    CANCELLATION_REQUESTED = True


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
        if lines[8] != f"schema={STATUS_SCHEMA_VERSION}" or lines[9] != "ready=1":
            return None

        try:
            supervisor_process_id = int(lines[0])
            worker_process_id = int(lines[1])
            wrapper_process_id = int(lines[5])
            installer_process_id = int(lines[7])
        except ValueError:
            return None
        if min(
            supervisor_process_id,
            worker_process_id,
            wrapper_process_id,
            installer_process_id,
        ) <= 1:
            return None

        installer_identity = parse_process_identity(lines[2])
        supervisor_identity = parse_process_identity(lines[3])
        worker_identity = parse_process_identity(lines[4])
        wrapper_identity = parse_process_identity(lines[6])
        if any(
            identity is None
            for identity in (
                installer_identity,
                supervisor_identity,
                worker_identity,
                wrapper_identity,
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
    except OSError:
        return None


def read_process_details(process_id: int) -> tuple[str, int, int] | None:
    try:
        with open(f"/proc/{process_id}/stat", "r", encoding="ascii") as stat_file:
            status = stat_file.read()
    except (FileNotFoundError, ProcessLookupError):
        return None
    except OSError:
        return None

    command_end = status.rfind(")")
    if command_end < 0:
        return None
    fields = status[command_end + 1 :].split()
    if len(fields) <= 19:
        return None
    try:
        return fields[0], int(fields[1]), int(fields[19])
    except ValueError:
        return None


def read_process_state(process_id: int) -> tuple[str, int] | None:
    details = read_process_details(process_id)
    if details is None:
        return None
    state, _parent_process_id, start_time = details
    return state, start_time


def capture_process_identity(process_id: int) -> ProcessIdentity | None:
    process_state = read_process_state(process_id)
    boot_id = read_boot_id()
    if process_state is None or not boot_id:
        return None
    state, start_time = process_state
    if state == "Z":
        return None
    return ProcessIdentity(start_time, boot_id)


def process_matches_identity(process_id: int, identity: ProcessIdentity) -> bool:
    if read_boot_id() != identity.boot_id:
        return False
    details = read_process_details(process_id)
    if details is None:
        return False
    state, _parent_process_id, start_time = details
    return state != "Z" and start_time == identity.start_time


def process_parent_matches(process_id: int, expected_parent: int) -> bool:
    details = read_process_details(process_id)
    if details is None:
        return False
    state, parent_process_id, _start_time = details
    return state != "Z" and parent_process_id == expected_parent


def validate_lock_status(
    path: str,
    wrapper_process_id: int,
    installer_process_id: int,
    installer_identity: ProcessIdentity,
) -> LockStatus | None:
    status = read_lock_status(path)
    if status is None:
        return None
    if status.wrapper_process_id != wrapper_process_id:
        return None
    if status.installer_process_id != installer_process_id:
        return None
    if status.installer_identity != installer_identity:
        return None

    # Validate the complete live process chain and every start time. A PID
    # alone is not sufficient: it may be a zombie or an unrelated process
    # that reused the number after a helper exited.
    if not process_matches_identity(
        status.wrapper_process_id,
        status.wrapper_identity,
    ):
        return None
    if not process_parent_matches(status.wrapper_process_id, installer_process_id):
        return None
    if not process_matches_identity(
        status.supervisor_process_id,
        status.supervisor_identity,
    ):
        return None
    if not process_parent_matches(
        status.supervisor_process_id,
        status.wrapper_process_id,
    ):
        return None
    if not process_matches_identity(
        status.worker_process_id,
        status.worker_identity,
    ):
        return None
    if not process_parent_matches(
        status.worker_process_id,
        status.supervisor_process_id,
    ):
        return None
    if not process_matches_identity(installer_process_id, installer_identity):
        return None
    return status


class ProcessMonitor:
    def __init__(self, processes: list[tuple[str, int]]) -> None:
        self.targets: list[MonitoredProcess] = []
        self.poller = select.poll()
        self.descriptor_count = 0

        for label, process_id in processes:
            target = MonitoredProcess(label, process_id)
            target.identity = capture_process_identity(process_id)
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
                if (
                    target.identity is not None
                    and not process_matches_identity(process_id, target.identity)
                ):
                    os.close(target.descriptor)
                    target.descriptor = -1
                    target.exited = True
                else:
                    self.poller.register(target.descriptor, select.POLLIN)
                    self.descriptor_count += 1
            self.targets.append(target)

    def mark_exited(self, target: MonitoredProcess) -> None:
        target.exited = True
        if target.descriptor < 0:
            return
        try:
            self.poller.unregister(target.descriptor)
        except (KeyError, OSError):
            pass
        os.close(target.descriptor)
        target.descriptor = -1
        self.descriptor_count -= 1

    def wait(
        self,
        validation_callback: Callable[[], bool] | None = None,
    ) -> MonitoredProcess | None:
        while True:
            if CANCELLATION_REQUESTED:
                raise AcquisitionCancelled()

            # Check process state before the status callback. If a helper has
            # exited, its stale status must not be mistaken for status
            # corruption and the child must still be reaped by its parent.
            for target in self.targets:
                if target.exited:
                    return target
                if (
                    target.identity is not None
                    and not process_matches_identity(target.process_id, target.identity)
                ):
                    self.mark_exited(target)
                    return target

            if validation_callback is not None and not validation_callback():
                return None

            if self.descriptor_count == 0:
                time.sleep(0.1)
                continue

            events = self.poller.poll(100)
            if events:
                for descriptor, _event in events:
                    for target in self.targets:
                        if target.descriptor == descriptor:
                            self.mark_exited(target)
                            return target

    def signal(self, label: str, signal_number: int) -> None:
        for target in self.targets:
            if target.label != label:
                continue
            if target.exited:
                return
            if target.descriptor >= 0 and hasattr(signal, "pidfd_send_signal"):
                try:
                    signal.pidfd_send_signal(target.descriptor, signal_number)
                    return
                except ProcessLookupError:
                    target.exited = True
                    return
                except OSError:
                    pass
            if (
                target.identity is not None
                and process_matches_identity(target.process_id, target.identity)
            ):
                try:
                    os.kill(target.process_id, signal_number)
                    return
                except ProcessLookupError:
                    target.exited = True
                    return
                except PermissionError as error:
                    raise MonitoringUnavailable(
                        f"unable to signal {label} process {target.process_id}: {error}"
                    ) from error
            raise MonitoringUnavailable(
                f"unable to signal {label} process {target.process_id} safely"
            )
        raise ValueError(f"unknown monitored process: {label}")

    def wait_for(self, label: str) -> MonitoredProcess:
        target = next(
            (candidate for candidate in self.targets if candidate.label == label),
            None,
        )
        if target is None:
            raise ValueError(f"unknown monitored process: {label}")

        while not target.exited:
            if CANCELLATION_REQUESTED:
                raise AcquisitionCancelled()
            if (
                target.identity is not None
                and not process_matches_identity(target.process_id, target.identity)
            ):
                self.mark_exited(target)
                break

            if self.descriptor_count == 0:
                time.sleep(0.1)
                continue

            events = self.poller.poll(100)
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
                os.close(target.descriptor)
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


def terminate_child(process_id: int) -> None:
    details = read_process_details(process_id)
    if details is not None and details[0] != "Z":
        try:
            os.kill(process_id, signal.SIGUSR2)
        except ProcessLookupError:
            pass
    if reap_child(process_id):
        return
    details = read_process_details(process_id)
    if details is not None and details[0] != "Z":
        try:
            os.kill(process_id, signal.SIGKILL)
        except ProcessLookupError:
            pass
    reap_child(process_id)


def signal_installer_loss(monitor: ProcessMonitor) -> bool:
    try:
        monitor.signal("installer", signal.SIGUSR1)
        return True
    except MonitoringUnavailable:
        target = monitor.targets[0]
        if target.identity is None:
            return True
        return not process_matches_identity(target.process_id, target.identity)


def worker_loop(
    installer_process_id: int,
    installer_identity: ProcessIdentity,
    supervisor_process_id: int,
    status_path: str,
    ready_descriptor: int,
) -> None:
    configure_signal_handlers(allow_cancellation=True)
    if capture_process_identity(installer_process_id) != installer_identity:
        os._exit(1)

    monitor = ProcessMonitor(
        [
            ("installer", installer_process_id),
            ("supervisor", supervisor_process_id),
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
            if signal_installer_loss(monitor):
                monitor.wait_for("installer")
            installer_terminated = True
    finally:
        monitor.close()
    if installer_terminated:
        remove_status(status_path)


def supervisor_loop(
    installer_process_id: int,
    installer_identity: ProcessIdentity,
    wrapper_process_id: int,
    worker_process_id: int,
    status_path: str,
) -> None:
    monitor = ProcessMonitor(
        [
            ("installer", installer_process_id),
            ("wrapper", wrapper_process_id),
            ("worker", worker_process_id),
        ]
    )
    installer_terminated = False
    try:
        def status_is_valid() -> bool:
            return (
                validate_lock_status(
                    status_path,
                    wrapper_process_id,
                    installer_process_id,
                    installer_identity,
                )
                is not None
            )

        exited = monitor.wait(status_is_valid)
        if exited is None:
            # A missing, corrupt, or mismatched status file is an integrity
            # failure. Abort the installer, but retain the descriptor until the
            # installer has completed its cleanup.
            if signal_installer_loss(monitor):
                monitor.wait_for("installer")
            installer_terminated = True
        elif exited.label == "installer":
            installer_terminated = True
        else:
            if exited.label == "worker":
                reap_child(worker_process_id)
            if signal_installer_loss(monitor):
                monitor.wait_for("installer")
            installer_terminated = True
    finally:
        monitor.close()
        terminate_child(worker_process_id)
    if installer_terminated:
        remove_status(status_path)


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
    if not process_matches_identity(installer_process_id, installer_identity):
        return

    monitor = ProcessMonitor([("installer", installer_process_id)])
    try:
        target = monitor.targets[0]
        if target.identity != installer_identity or target.exited:
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
        f"schema={STATUS_SCHEMA_VERSION}\n"
        "ready=1\n"
    )


def hold_lock(
    lock_path: str,
    status_path: str,
    commit_path: str,
    installer_process_id: int,
    installer_identity: ProcessIdentity,
    wrapper_process_id: int,
) -> None:
    global COMMIT_PATH

    COMMIT_PATH = commit_path
    configure_signal_handlers(allow_cancellation=True)
    if capture_process_identity(installer_process_id) != installer_identity:
        fail("installer process identity changed before lock helper startup")
    if wrapper_process_id != os.getppid():
        fail(
            "lock helper is not a child of the lock guardian "
            f"(expected {wrapper_process_id}, actual {os.getppid()})"
        )

    lock_descriptor = find_lock_descriptor(lock_path)
    wrapper_identity = capture_process_identity(wrapper_process_id)
    supervisor_identity = capture_process_identity(os.getpid())
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
                os.getppid(),
                status_path,
                ready_write,
            )
        except BaseException:
            os._exit(1)
        os._exit(0)

    os.close(ready_write)
    worker_ready = wait_for_ready(ready_read)
    os.close(ready_read)
    if not worker_ready:
        terminate_child(worker_process_id)
        fail("lock worker did not become ready")

    worker_identity = capture_process_identity(worker_process_id)
    if worker_identity is None:
        terminate_child(worker_process_id)
        fail("unable to capture the lock worker identity")
    if not process_parent_matches(worker_process_id, os.getpid()):
        terminate_child(worker_process_id)
        fail("lock worker is not a child of the lock supervisor")

    status = LockStatus(
        installer_process_id=installer_process_id,
        installer_identity=installer_identity,
        wrapper_process_id=wrapper_process_id,
        wrapper_identity=wrapper_identity,
        supervisor_process_id=os.getpid(),
        supervisor_identity=supervisor_identity,
        worker_process_id=worker_process_id,
        worker_identity=worker_identity,
    )
    try:
        write_status(status_path, encode_status(status))
    except BaseException:
        terminate_child(worker_process_id)
        raise

    try:
        supervisor_loop(
            installer_process_id,
            installer_identity,
            wrapper_process_id,
            worker_process_id,
            status_path,
        )
    finally:
        os.close(lock_descriptor)


def main() -> None:
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
        status = validate_lock_status(
            sys.argv[2],
            int(sys.argv[3]),
            int(sys.argv[4]),
            installer_identity,
        )
        if status is None:
            raise SystemExit(1)
        print(f"{status.supervisor_process_id} {status.worker_process_id}")
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
            "INSTALLER_IDENTITY INSTALLER_PID or lock-holder.py hold LOCK_PATH "
            "STATUS_PATH COMMIT_PATH INSTALLER_PID INSTALLER_IDENTITY WRAPPER_PID"
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
    except (OSError, MonitoringUnavailable, ValueError) as error:
        fail(str(error))
