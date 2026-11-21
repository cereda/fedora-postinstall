#!/usr/bin/env python3

# SPDX-License-Identifier: MIT

import ctypes
import errno
import hashlib
import os
import secrets
import stat
import sys
import time


def fail(message: str) -> None:
    print(f"runtime-file: {message}", file=sys.stderr)
    raise SystemExit(1)


RENAME_NOREPLACE = 1

_RENAMEAT2 = None


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


def metadata_identity(metadata: os.stat_result) -> str:
    return f"{metadata.st_dev}:{metadata.st_ino}"


def identities_match(first: os.stat_result, second: os.stat_result) -> bool:
    return first.st_dev == second.st_dev and first.st_ino == second.st_ino


def sync_directory(descriptor: int, description: str) -> bool:
    try:
        os.fsync(descriptor)
        return True
    except OSError as error:
        print(
            f"runtime-file: unable to sync {description}: {error}",
            file=sys.stderr,
        )
        return False


def inspect_parent(
    descriptor: int,
    component: str,
    path: str,
    allow_sticky: bool = True,
) -> None:
    metadata = os.fstat(descriptor)
    mode = stat.S_IMODE(metadata.st_mode)

    if metadata.st_uid not in {0, os.geteuid()}:
        fail(f"parent directory is not owned by the current user or root: {path}")

    if mode & 0o022 and not (allow_sticky and mode & stat.S_ISVTX):
        fail(f"parent directory is writable by another user: {path}")


def open_parent(path: str, strict_final_parent: bool = False) -> int:
    absolute = os.path.abspath(path)
    parent = os.path.dirname(absolute)
    components = [component for component in parent.split(os.sep) if component]

    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
    descriptor = os.open(os.sep, flags)

    try:
        inspect_parent(descriptor, "", path)
        for component in components:
            if component in {".", ".."}:
                fail(f"unsafe parent path: {path}")
            try:
                metadata = os.stat(
                    component,
                    dir_fd=descriptor,
                    follow_symlinks=False,
                )
                if stat.S_ISLNK(metadata.st_mode):
                    fail(f"parent path must not contain symbolic links: {path}")
            except FileNotFoundError:
                pass
            except OSError as error:
                if error.errno == errno.ELOOP:
                    fail(f"parent path must not contain symbolic links: {path}")
                raise

            try:
                child = os.open(
                    component,
                    flags,
                    dir_fd=descriptor,
                )
            except FileNotFoundError:
                try:
                    os.mkdir(component, 0o700, dir_fd=descriptor)
                except FileExistsError:
                    pass
                try:
                    child = os.open(
                        component,
                        flags,
                        dir_fd=descriptor,
                    )
                except OSError as error:
                    if error.errno == errno.ELOOP:
                        fail(f"parent path must not contain symbolic links: {path}")
                    raise
            except OSError as error:
                if error.errno == errno.ELOOP:
                    fail(f"parent path must not contain symbolic links: {path}")
                raise
            inspect_parent(child, component, path)
            os.close(descriptor)
            descriptor = child
    except BaseException:
        os.close(descriptor)
        raise

    if strict_final_parent:
        try:
            inspect_parent(descriptor, "", path, allow_sticky=False)
        except BaseException:
            os.close(descriptor)
            raise

    return descriptor


def inspect_existing(parent: int, name: str, path: str) -> bool:
    try:
        descriptor = os.open(
            name,
            os.O_PATH | os.O_CLOEXEC | os.O_NOFOLLOW,
            dir_fd=parent,
        )
    except FileNotFoundError:
        return False
    except OSError as error:
        if error.errno == errno.ELOOP:
            fail(f"path must not be a symbolic link: {path}")
        raise

    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            fail(f"path is not a regular file: {path}")
        if metadata.st_nlink != 1:
            fail(f"path has multiple hard links: {path}")
        if metadata.st_uid != os.geteuid():
            fail(f"path is not owned by the current user: {path}")
    finally:
        os.close(descriptor)

    return True


def open_regular_file(path: str) -> int:
    absolute = os.path.abspath(path)
    name = os.path.basename(absolute)
    if not name or name in {".", ".."}:
        fail(f"invalid file name: {path}")

    parent = open_parent(path, strict_final_parent=True)
    descriptor = -1
    try:
        flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
        try:
            descriptor = os.open(name, flags, dir_fd=parent)
        except OSError as error:
            if error.errno == errno.ELOOP:
                fail(f"path must not be a symbolic link: {path}")
            raise

        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            fail(f"path is not a regular file: {path}")
        if metadata.st_nlink != 1:
            fail(f"path has multiple hard links: {path}")
        if metadata.st_uid != os.geteuid():
            fail(f"path is not owned by the current user: {path}")
        return descriptor
    except BaseException:
        if descriptor >= 0:
            os.close(descriptor)
        raise
    finally:
        os.close(parent)


def open_existing_directory(path: str) -> int:
    absolute = os.path.abspath(path)
    name = os.path.basename(absolute)
    if not name or name in {".", ".."}:
        fail(f"invalid directory name: {path}")

    parent = open_parent(path)
    descriptor = -1
    try:
        flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
        try:
            descriptor = os.open(name, flags, dir_fd=parent)
        except OSError as error:
            if error.errno == errno.ELOOP:
                fail(f"directory must not be a symbolic link: {path}")
            raise

        metadata = os.fstat(descriptor)
        if not stat.S_ISDIR(metadata.st_mode):
            fail(f"path is not a directory: {path}")
        if metadata.st_uid != os.geteuid():
            fail(f"directory is not owned by the current user: {path}")
        if stat.S_IMODE(metadata.st_mode) & 0o022:
            fail(f"directory is writable by another user: {path}")
        os.fchmod(descriptor, 0o700)
        inspect_parent(descriptor, name, path, allow_sticky=False)
        return descriptor
    except BaseException:
        if descriptor >= 0:
            os.close(descriptor)
        raise
    finally:
        os.close(parent)


def write_all(descriptor: int, content: bytes) -> None:
    offset = 0
    while offset < len(content):
        offset += os.write(descriptor, content[offset:])


def write_stream(directory: str) -> None:
    directory_descriptor = open_existing_directory(directory)
    descriptor = -1
    name = ""
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
            name = f".artifact-{secrets.token_hex(16)}.tmp"
            try:
                descriptor = os.open(name, flags, 0o600, dir_fd=directory_descriptor)
                break
            except FileExistsError:
                continue
        if descriptor < 0:
            fail(f"unable to create a unique file in: {directory}")

        digest = hashlib.sha256()
        while True:
            chunk = sys.stdin.buffer.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            write_all(descriptor, chunk)

        os.fchmod(descriptor, 0o600)
        os.fsync(descriptor)
        print(f"{digest.hexdigest()}\t{os.path.abspath(os.path.join(directory, name))}")
    except BaseException:
        if descriptor >= 0:
            os.close(descriptor)
            descriptor = -1
        if name:
            try:
                os.unlink(name, dir_fd=directory_descriptor)
            except FileNotFoundError:
                pass
        raise
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(directory_descriptor)


def copy_private(source: str, destination: str) -> None:
    source_descriptor = open_regular_file(source)
    destination_absolute = os.path.abspath(destination)
    destination_name = os.path.basename(destination_absolute)
    if not destination_name or destination_name in {".", ".."}:
        os.close(source_descriptor)
        fail(f"invalid destination file name: {destination}")

    destination_parent = -1
    destination_descriptor = -1
    destination_created = False
    destination_identity = None
    try:
        destination_parent = open_parent(destination, strict_final_parent=True)
        flags = (
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | os.O_CLOEXEC
            | os.O_NOFOLLOW
            | os.O_NONBLOCK
        )
        try:
            destination_descriptor = os.open(
                destination_name,
                flags,
                0o600,
                dir_fd=destination_parent,
            )
            destination_created = True
            destination_identity = os.fstat(destination_descriptor)
        except OSError as error:
            if error.errno == errno.ELOOP:
                fail(f"destination must not be a symbolic link: {destination}")
            raise

        digest = hashlib.sha256()
        while True:
            chunk = os.read(source_descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            write_all(destination_descriptor, chunk)

        os.fchmod(destination_descriptor, 0o600)
        os.fsync(destination_descriptor)
        print(digest.hexdigest())
    except BaseException:
        if destination_descriptor >= 0:
            os.close(destination_descriptor)
            destination_descriptor = -1
        if destination_parent >= 0 and destination_created:
            try:
                current_metadata = os.stat(
                    destination_name,
                    dir_fd=destination_parent,
                    follow_symlinks=False,
                )
                if (
                    destination_identity is not None
                    and current_metadata.st_dev == destination_identity.st_dev
                    and current_metadata.st_ino == destination_identity.st_ino
                ):
                    os.unlink(destination_name, dir_fd=destination_parent)
            except FileNotFoundError:
                pass
        raise
    finally:
        if destination_descriptor >= 0:
            os.close(destination_descriptor)
        if destination_parent >= 0:
            os.close(destination_parent)
        os.close(source_descriptor)


def remove_verified_source(
    parent: int,
    name: str,
    expected_metadata: os.stat_result,
) -> None:
    """Remove the copied source, or restore a concurrent replacement.

    Cleanup runs only after the destination is committed. Every failure is
    therefore reported as a warning and must not turn a successful publication
    into a failed one.
    """
    quarantine_name = ""
    for _ in range(100):
        candidate = f".{name}.source.{secrets.token_hex(16)}"
        try:
            os.stat(candidate, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            quarantine_name = candidate
            break
    if not quarantine_name:
        print(
            "runtime-file: published artifact but could not prepare source cleanup for: "
            f"{name}",
            file=sys.stderr,
        )
        return

    try:
        rename_noreplace(parent, name, parent, quarantine_name)
    except FileNotFoundError:
        return
    except OSError as error:
        print(
            f"runtime-file: published artifact but could not remove source: {error}",
            file=sys.stderr,
        )
        return

    sync_directory(parent, "the source directory")

    try:
        quarantined_metadata = os.stat(
            quarantine_name,
            dir_fd=parent,
            follow_symlinks=False,
        )
    except OSError as error:
        print(
            "runtime-file: published artifact but could not inspect quarantined source "
            f"at {os.path.join(os.path.dirname(name), quarantine_name)}: {error}",
            file=sys.stderr,
        )
        return

    if not identities_match(quarantined_metadata, expected_metadata):
        try:
            rename_noreplace(parent, quarantine_name, parent, name)
        except FileExistsError:
            print(
                "runtime-file: published artifact but a replacement source was preserved at "
                f"{os.path.join(os.path.dirname(name), quarantine_name)}",
                file=sys.stderr,
            )
            return
        except OSError as error:
            print(
                "runtime-file: published artifact but a replacement source remains at "
                f"{os.path.join(os.path.dirname(name), quarantine_name)}: {error}",
                file=sys.stderr,
            )
            return
        sync_directory(parent, "the source directory")
        print(
            "runtime-file: published artifact but a replacement source was preserved at "
            f"{os.path.join(os.path.dirname(name), name)}",
            file=sys.stderr,
        )
        return

    try:
        os.unlink(quarantine_name, dir_fd=parent)
    except OSError as error:
        print(
            "runtime-file: published artifact but the verified source remains at "
            f"{os.path.join(os.path.dirname(name), quarantine_name)}: {error}",
            file=sys.stderr,
        )
        return
    sync_directory(parent, "the source directory")


def publish_file(source: str, destination: str, expected_checksum: str) -> None:
    if len(expected_checksum) != 64 or any(
        character not in "0123456789abcdef" for character in expected_checksum
    ):
        fail(f"invalid expected SHA-256 checksum: {expected_checksum}")

    source_descriptor = open_regular_file(source)
    source_absolute = os.path.abspath(source)
    source_name = os.path.basename(source_absolute)
    destination_absolute = os.path.abspath(destination)
    destination_name = os.path.basename(destination_absolute)
    if not source_name or source_name in {".", ".."}:
        os.close(source_descriptor)
        fail(f"invalid source file name: {source}")
    if not destination_name or destination_name in {".", ".."}:
        os.close(source_descriptor)
        fail(f"invalid destination file name: {destination}")
    if source_absolute == destination_absolute:
        os.close(source_descriptor)
        fail("source and destination must be different paths")

    source_parent = -1
    destination_parent = -1
    destination_descriptor = -1
    temporary_name = ""
    try:
        source_parent = open_parent(source, strict_final_parent=True)
        destination_parent = open_parent(destination, strict_final_parent=True)

        source_metadata = os.fstat(source_descriptor)
        current_source_metadata = os.stat(
            source_name,
            dir_fd=source_parent,
            follow_symlinks=False,
        )
        if stat.S_ISLNK(current_source_metadata.st_mode):
            fail(f"source must not be a symbolic link: {source}")
        if not stat.S_ISREG(current_source_metadata.st_mode):
            fail(f"source is not a regular file: {source}")
        if current_source_metadata.st_nlink != 1:
            fail(f"source has multiple hard links: {source}")
        if current_source_metadata.st_uid != os.geteuid():
            fail(f"source is not owned by the current user: {source}")
        if (
            current_source_metadata.st_dev != source_metadata.st_dev
            or current_source_metadata.st_ino != source_metadata.st_ino
        ):
            fail(f"source changed while it was being copied: {source}")

        try:
            destination_metadata = os.stat(
                destination_name,
                dir_fd=destination_parent,
                follow_symlinks=False,
            )
            if stat.S_ISLNK(destination_metadata.st_mode):
                fail(f"destination must not be a symbolic link: {destination}")
            if not stat.S_ISREG(destination_metadata.st_mode):
                fail(f"destination is not a regular file: {destination}")
            if destination_metadata.st_nlink != 1:
                fail(f"destination has multiple hard links: {destination}")
            if destination_metadata.st_uid != os.geteuid():
                fail(f"destination is not owned by the current user: {destination}")
        except FileNotFoundError:
            pass

        flags = (
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | os.O_CLOEXEC
            | os.O_NOFOLLOW
            | os.O_NONBLOCK
        )
        for _ in range(100):
            temporary_name = f".artifact-{secrets.token_hex(16)}.tmp"
            try:
                destination_descriptor = os.open(
                    temporary_name,
                    flags,
                    0o600,
                    dir_fd=destination_parent,
                )
                break
            except FileExistsError:
                continue
        if destination_descriptor < 0:
            fail(f"unable to create a unique destination file in: {destination}")

        digest = hashlib.sha256()
        while True:
            chunk = os.read(source_descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            write_all(destination_descriptor, chunk)

        actual_checksum = digest.hexdigest()
        if actual_checksum != expected_checksum:
            fail(f"source checksum does not match the expected SHA-256 checksum: {source}")

        os.fchmod(destination_descriptor, 0o600)
        os.fsync(destination_descriptor)
        os.close(destination_descriptor)
        destination_descriptor = -1

        current_source_metadata = os.stat(
            source_name,
            dir_fd=source_parent,
            follow_symlinks=False,
        )
        if (
            current_source_metadata.st_dev != source_metadata.st_dev
            or current_source_metadata.st_ino != source_metadata.st_ino
        ):
            fail(f"source changed while it was being published: {source}")

        os.replace(
            temporary_name,
            destination_name,
            src_dir_fd=destination_parent,
            dst_dir_fd=destination_parent,
        )
        temporary_name = ""
        os.fsync(destination_parent)

        # The source is removed only after the destination has been published.
        # Cleanup is deliberately best-effort: a failure after the atomic
        # destination commit must not report the publication as failed.
        try:
            remove_verified_source(source_parent, source_name, source_metadata)
        except Exception as error:
            print(
                "runtime-file: published artifact but source cleanup failed: "
                f"{error}",
                file=sys.stderr,
            )
        print(actual_checksum)
    except BaseException:
        if destination_descriptor >= 0:
            os.close(destination_descriptor)
            destination_descriptor = -1
        if temporary_name and destination_parent >= 0:
            try:
                os.unlink(temporary_name, dir_fd=destination_parent)
            except FileNotFoundError:
                pass
        raise
    finally:
        if destination_parent >= 0:
            os.close(destination_parent)
        if source_parent >= 0:
            os.close(source_parent)
        os.close(source_descriptor)


def parse_file_identity(value: str) -> tuple[int, int]:
    try:
        device, inode = value.split(":", 1)
        return int(device), int(inode)
    except (ValueError, TypeError) as error:
        fail(f"invalid file identity: {value}")
    raise AssertionError("unreachable")


def backup_destination(
    destination: str,
    backup: str,
    expected_identity: str,
) -> int:
    """Move the exact destination entry into the recovery directory."""
    destination_absolute = os.path.abspath(destination)
    destination_name = os.path.basename(destination_absolute)
    backup_absolute = os.path.abspath(backup)
    backup_name = os.path.basename(backup_absolute)
    if not destination_name or not backup_name:
        fail("invalid deployment destination or backup name")

    destination_parent = open_parent(destination, strict_final_parent=True)
    backup_parent = open_parent(backup, strict_final_parent=True)
    try:
        try:
            current_metadata = os.stat(
                destination_name,
                dir_fd=destination_parent,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            current_metadata = None

        if expected_identity == "-":
            if current_metadata is not None:
                print(
                    "runtime-file: deployment target appeared before backup and was preserved: "
                    f"{destination}",
                    file=sys.stderr,
                )
                return 3
            print("-\t-", flush=True)
            return 0

        expected_device, expected_inode = parse_file_identity(expected_identity)
        if current_metadata is None:
            print(
                "runtime-file: deployment target disappeared before backup: "
                f"{destination}",
                file=sys.stderr,
            )
            return 3
        if (
            current_metadata.st_dev != expected_device
            or current_metadata.st_ino != expected_inode
        ):
            print(
                "runtime-file: deployment target changed before backup and was preserved: "
                f"{destination}",
                file=sys.stderr,
            )
            return 3
        if not (
            stat.S_ISREG(current_metadata.st_mode)
            or stat.S_ISLNK(current_metadata.st_mode)
        ):
            fail(f"deployment target is not a regular file or symbolic link: {destination}")
        if stat.S_ISREG(current_metadata.st_mode) and current_metadata.st_nlink != 1:
            fail(f"deployment target has multiple hard links: {destination}")

        try:
            rename_noreplace(
                destination_parent,
                destination_name,
                backup_parent,
                backup_name,
            )
        except FileExistsError:
            fail(f"rollback backup already exists: {backup}")

        backup_metadata = os.stat(
            backup_name,
            dir_fd=backup_parent,
            follow_symlinks=False,
        )
        original_identity = metadata_identity(current_metadata)
        backup_identity = metadata_identity(backup_metadata)
        print(f"{original_identity}\t{backup_identity}", flush=True)

        if not identities_match(current_metadata, backup_metadata):
            try:
                rename_noreplace(
                    backup_parent,
                    backup_name,
                    destination_parent,
                    destination_name,
                )
            except FileExistsError:
                print(
                    "runtime-file: concurrent deployment replacement was preserved at "
                    f"{backup}",
                    file=sys.stderr,
                )
            except OSError as error:
                print(
                    "runtime-file: concurrent deployment replacement remains at "
                    f"{backup}: {error}",
                    file=sys.stderr,
                )
            else:
                destination_synced = sync_directory(
                    destination_parent,
                    "the deployment directory",
                )
                backup_synced = sync_directory(backup_parent, "the backup directory")
                if not destination_synced or not backup_synced:
                    return 1
            print(
                "runtime-file: deployment target changed during backup: "
                f"{destination}",
                file=sys.stderr,
            )
            return 3

        destination_synced = sync_directory(
            destination_parent,
            "the deployment directory",
        )
        backup_synced = sync_directory(backup_parent, "the backup directory")
        return 0 if destination_synced and backup_synced else 1
    finally:
        os.close(destination_parent)
        os.close(backup_parent)


def replace_destination(
    staged: str,
    destination: str,
    expected_identity: str,
) -> int:
    """Install a staged file only when the destination name is still free."""
    staged_absolute = os.path.abspath(staged)
    staged_name = os.path.basename(staged_absolute)
    destination_absolute = os.path.abspath(destination)
    destination_name = os.path.basename(destination_absolute)
    if not staged_name or not destination_name:
        fail("invalid staged file or deployment destination name")

    staged_descriptor = open_regular_file(staged)
    staged_parent = open_parent(staged, strict_final_parent=True)
    destination_parent = open_parent(destination, strict_final_parent=True)
    try:
        staged_metadata = os.fstat(staged_descriptor)
        expected_device, expected_inode = parse_file_identity(expected_identity)
        if (
            staged_metadata.st_dev != expected_device
            or staged_metadata.st_ino != expected_inode
        ):
            fail(f"staged deployment file changed before replacement: {staged}")
        if not identities_match(
            staged_metadata,
            os.stat(
                staged_name,
                dir_fd=staged_parent,
                follow_symlinks=False,
            ),
        ):
            fail(f"staged deployment file changed before replacement: {staged}")
        if not identities_match(
            os.fstat(staged_parent),
            os.fstat(destination_parent),
        ):
            fail("staged deployment file is not in the destination directory")

        os.fsync(staged_descriptor)
        if not sync_directory(destination_parent, "the deployment directory"):
            raise OSError(errno.EIO, "unable to sync the deployment directory")
        try:
            rename_noreplace(
                destination_parent,
                staged_name,
                destination_parent,
                destination_name,
            )
        except FileExistsError:
            print(
                "runtime-file: deployment target changed before replacement and was preserved: "
                f"{destination}",
                file=sys.stderr,
            )
            return 2

        if not sync_directory(destination_parent, "the deployment directory"):
            raise OSError(errno.EIO, "unable to sync the deployment directory")
        installed_metadata = os.stat(
            destination_name,
            dir_fd=destination_parent,
            follow_symlinks=False,
        )
        if not identities_match(staged_metadata, installed_metadata):
            raise OSError(errno.EIO, "installed deployment file identity changed")
        print(metadata_identity(staged_metadata))
        return 0
    finally:
        os.close(staged_descriptor)
        os.close(staged_parent)
        os.close(destination_parent)


def rollback_destination(
    destination: str,
    backup: str,
    original_identity: str,
    staged_identity: str,
    backup_identity: str,
    had_original: bool,
) -> int:
    """Restore an original by exact identity without replacing a concurrent entry."""
    destination_absolute = os.path.abspath(destination)
    destination_name = os.path.basename(destination_absolute)
    backup_absolute = os.path.abspath(backup)
    backup_name = os.path.basename(backup_absolute)
    if not destination_name or not backup_name:
        fail("invalid rollback destination or backup name")

    staged_device, staged_inode = parse_file_identity(staged_identity)
    destination_parent = open_parent(destination, strict_final_parent=True)
    backup_parent = -1
    quarantine_name = ""
    preserve_quarantine = False
    try:
        if had_original:
            backup_parent = open_parent(backup, strict_final_parent=True)
            original_device, original_inode = parse_file_identity(original_identity)
            expected_backup_device, expected_backup_inode = parse_file_identity(
                backup_identity
            )

            try:
                current_metadata = os.stat(
                    destination_name,
                    dir_fd=destination_parent,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                current_metadata = None

            if current_metadata is not None and (
                current_metadata.st_dev == original_device
                and current_metadata.st_ino == original_inode
            ):
                print(
                    f"runtime-file: rollback destination was already restored by identity: {destination}",
                    file=sys.stderr,
                )
                return 0

            if current_metadata is not None and not (
                current_metadata.st_dev == staged_device
                and current_metadata.st_ino == staged_inode
            ):
                print(
                    "runtime-file: rollback skipped because the destination changed: "
                    f"{destination}",
                    file=sys.stderr,
                )
                return 3

            try:
                backup_metadata = os.stat(
                    backup_name,
                    dir_fd=backup_parent,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                fail(f"rollback backup is missing: {backup}")
            if (
                backup_metadata.st_dev != expected_backup_device
                or backup_metadata.st_ino != expected_backup_inode
            ):
                print(
                    "runtime-file: rollback skipped because the backup identity changed: "
                    f"{backup}",
                    file=sys.stderr,
                )
                return 3
            if (
                backup_metadata.st_dev != original_device
                or backup_metadata.st_ino != original_inode
            ):
                print(
                    "runtime-file: rollback skipped because the backup is not the original: "
                    f"{backup}",
                    file=sys.stderr,
                )
                return 3

            if current_metadata is None:
                try:
                    rename_noreplace(
                        backup_parent,
                        backup_name,
                        destination_parent,
                        destination_name,
                    )
                except FileExistsError:
                    print(
                        "runtime-file: rollback skipped because the destination changed: "
                        f"{destination}",
                        file=sys.stderr,
                    )
                    return 3
                sync_ok = sync_directory(backup_parent, "the backup directory")
                sync_ok = sync_directory(destination_parent, "the deployment directory") and sync_ok
                return 0 if sync_ok else 1

            for _ in range(100):
                candidate = f".{destination_name}.rollback.{secrets.token_hex(16)}"
                try:
                    os.stat(
                        candidate,
                        dir_fd=destination_parent,
                        follow_symlinks=False,
                    )
                except FileNotFoundError:
                    quarantine_name = candidate
                    break
            if not quarantine_name:
                fail(f"unable to prepare a rollback quarantine for: {destination}")

            try:
                rename_noreplace(
                    destination_parent,
                    destination_name,
                    destination_parent,
                    quarantine_name,
                )
            except FileNotFoundError:
                print(
                    "runtime-file: rollback skipped because the destination changed: "
                    f"{destination}",
                    file=sys.stderr,
                )
                return 3

            sync_ok = sync_directory(destination_parent, "the deployment directory")
            detached_metadata = os.stat(
                quarantine_name,
                dir_fd=destination_parent,
                follow_symlinks=False,
            )
            if not (
                detached_metadata.st_dev == staged_device
                and detached_metadata.st_ino == staged_inode
            ):
                try:
                    rename_noreplace(
                        destination_parent,
                        quarantine_name,
                        destination_parent,
                        destination_name,
                    )
                except FileExistsError:
                    preserve_quarantine = True
                    print(
                        "runtime-file: concurrent destination replacement was preserved at "
                        f"{os.path.join(os.path.dirname(destination_absolute), quarantine_name)}",
                        file=sys.stderr,
                    )
                except OSError as error:
                    preserve_quarantine = True
                    print(
                        "runtime-file: concurrent destination replacement remains at "
                        f"{os.path.join(os.path.dirname(destination_absolute), quarantine_name)}: {error}",
                        file=sys.stderr,
                    )
                else:
                    quarantine_name = ""
                    sync_ok = sync_directory(
                        destination_parent,
                        "the deployment directory",
                    ) and sync_ok
                print(
                    "runtime-file: rollback skipped because the destination changed: "
                    f"{destination}",
                    file=sys.stderr,
                )
                return 3

            try:
                rename_noreplace(
                    backup_parent,
                    backup_name,
                    destination_parent,
                    destination_name,
                )
            except FileExistsError:
                preserve_quarantine = True
                print(
                    "runtime-file: rollback skipped because a concurrent destination was preserved; "
                    f"the original remains at {backup} and the staged file remains at "
                    f"{os.path.join(os.path.dirname(destination_absolute), quarantine_name)}",
                    file=sys.stderr,
                )
                sync_ok = sync_directory(
                    destination_parent,
                    "the deployment directory",
                ) and sync_ok
                return 3
            except OSError as error:
                try:
                    rename_noreplace(
                        destination_parent,
                        quarantine_name,
                        destination_parent,
                        destination_name,
                    )
                except FileExistsError:
                    preserve_quarantine = True
                    print(
                        "runtime-file: the staged file remains at "
                        f"{os.path.join(os.path.dirname(destination_absolute), quarantine_name)}: {error}",
                        file=sys.stderr,
                    )
                else:
                    quarantine_name = ""
                sync_ok = sync_directory(
                    destination_parent,
                    "the deployment directory",
                ) and sync_ok
                print(
                    f"runtime-file: unable to restore the original destination: {destination}",
                    file=sys.stderr,
                )
                return 1

            sync_ok = sync_directory(backup_parent, "the backup directory") and sync_ok
            sync_ok = sync_directory(destination_parent, "the deployment directory") and sync_ok
            restored_metadata = os.stat(
                destination_name,
                dir_fd=destination_parent,
                follow_symlinks=False,
            )
            if not (
                restored_metadata.st_dev == original_device
                and restored_metadata.st_ino == original_inode
            ):
                print(
                    "runtime-file: restored destination does not have the original identity: "
                    f"{destination}",
                    file=sys.stderr,
                )
                return 1

            try:
                os.unlink(quarantine_name, dir_fd=destination_parent)
                quarantine_name = ""
            except OSError as error:
                print(
                    "runtime-file: the staged file remains at "
                    f"{os.path.join(os.path.dirname(destination_absolute), quarantine_name)}: {error}",
                    file=sys.stderr,
                )
                sync_ok = False
            sync_ok = sync_directory(destination_parent, "the deployment directory") and sync_ok
            return 0 if sync_ok else 1

        try:
            current_metadata = os.stat(
                destination_name,
                dir_fd=destination_parent,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            print(
                f"runtime-file: rollback destination is already absent: {destination}",
                file=sys.stderr,
            )
            return 0

        if not (
            current_metadata.st_dev == staged_device
            and current_metadata.st_ino == staged_inode
        ):
            print(
                "runtime-file: rollback skipped because the destination changed: "
                f"{destination}",
                file=sys.stderr,
            )
            return 3

        for _ in range(100):
            candidate = f".{destination_name}.rollback.{secrets.token_hex(16)}"
            try:
                os.stat(
                    candidate,
                    dir_fd=destination_parent,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                quarantine_name = candidate
                break
        if not quarantine_name:
            fail(f"unable to prepare a rollback quarantine for: {destination}")

        try:
            rename_noreplace(
                destination_parent,
                destination_name,
                destination_parent,
                quarantine_name,
            )
        except FileNotFoundError:
            print(
                "runtime-file: rollback skipped because the destination changed: "
                f"{destination}",
                file=sys.stderr,
            )
            return 3

        sync_ok = sync_directory(destination_parent, "the deployment directory")
        detached_metadata = os.stat(
            quarantine_name,
            dir_fd=destination_parent,
            follow_symlinks=False,
        )
        if not (
            detached_metadata.st_dev == staged_device
            and detached_metadata.st_ino == staged_inode
        ):
            try:
                rename_noreplace(
                    destination_parent,
                    quarantine_name,
                    destination_parent,
                    destination_name,
                )
            except FileExistsError:
                preserve_quarantine = True
                print(
                    "runtime-file: concurrent destination replacement was preserved at "
                    f"{os.path.join(os.path.dirname(destination_absolute), quarantine_name)}",
                    file=sys.stderr,
                )
            except OSError as error:
                preserve_quarantine = True
                print(
                    "runtime-file: concurrent destination replacement remains at "
                    f"{os.path.join(os.path.dirname(destination_absolute), quarantine_name)}: {error}",
                    file=sys.stderr,
                )
            else:
                quarantine_name = ""
                sync_ok = sync_directory(
                    destination_parent,
                    "the deployment directory",
                ) and sync_ok
            print(
                "runtime-file: rollback skipped because the destination changed: "
                f"{destination}",
                file=sys.stderr,
            )
            return 3

        try:
            os.unlink(quarantine_name, dir_fd=destination_parent)
            quarantine_name = ""
        except OSError as error:
            print(
                "runtime-file: the staged file remains at "
                f"{os.path.join(os.path.dirname(destination_absolute), quarantine_name)}: {error}",
                file=sys.stderr,
            )
            sync_ok = False
        sync_ok = sync_directory(destination_parent, "the deployment directory") and sync_ok

        try:
            os.stat(
                destination_name,
                dir_fd=destination_parent,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            return 0 if sync_ok else 1
        print(
            "runtime-file: rollback skipped because a concurrent destination appeared: "
            f"{destination}",
            file=sys.stderr,
        )
        return 3
    finally:
        if quarantine_name and not preserve_quarantine:
            try:
                os.unlink(quarantine_name, dir_fd=destination_parent)
            except FileNotFoundError:
                pass
            except OSError:
                pass
        os.close(destination_parent)
        if backup_parent >= 0:
            os.close(backup_parent)


def prune_partials(directory: str) -> None:
    """Remove stale interrupted-download files without touching cache versions."""
    directory_descriptor = open_existing_directory(directory)
    temporary_cutoff = time.time() - 3600
    changed = False
    try:
        for name in os.listdir(directory_descriptor):
            if not name.startswith(".artifact-") or not name.endswith(".tmp"):
                continue
            try:
                metadata = os.stat(
                    name,
                    dir_fd=directory_descriptor,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                continue
            if not stat.S_ISREG(metadata.st_mode):
                continue
            if metadata.st_nlink != 1 or metadata.st_uid != os.geteuid():
                continue
            if metadata.st_mtime >= temporary_cutoff:
                continue
            try:
                os.unlink(name, dir_fd=directory_descriptor)
                changed = True
            except FileNotFoundError:
                continue
        if changed:
            os.fsync(directory_descriptor)
    finally:
        os.close(directory_descriptor)


def prune_versions(directory: str, keep_name: str) -> None:
    """Evict old visible artifact versions while preserving helper namespaces."""
    directory_descriptor = open_existing_directory(directory)
    changed = False
    try:
        for name in os.listdir(directory_descriptor):
            if name == keep_name:
                continue
            # Hidden entries belong to the partial, source, and quarantine
            # namespaces and are intentionally retained for recovery.
            if name.startswith("."):
                continue
            if ".source." in name or ".quarantine." in name:
                continue
            try:
                metadata = os.stat(
                    name,
                    dir_fd=directory_descriptor,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                continue
            if not stat.S_ISREG(metadata.st_mode):
                continue
            if metadata.st_nlink != 1 or metadata.st_uid != os.geteuid():
                continue
            try:
                os.unlink(name, dir_fd=directory_descriptor)
                changed = True
            except FileNotFoundError:
                continue
        if changed:
            os.fsync(directory_descriptor)
    finally:
        os.close(directory_descriptor)


def prune_directory(directory: str, keep_name: str) -> None:
    # Kept as a compatibility alias. Cache-version eviction is intentionally
    # performed only after a successful publication.
    del keep_name
    prune_partials(directory)


def find_verified_artifact(directory: str, expected_checksum: str) -> bool:
    if len(expected_checksum) != 64 or any(
        character not in "0123456789abcdef" for character in expected_checksum
    ):
        fail(f"invalid expected SHA-256 checksum: {expected_checksum}")

    directory_descriptor = open_existing_directory(directory)
    try:
        for name in sorted(os.listdir(directory_descriptor)):
            if not name.startswith(".artifact-") or not name.endswith(".tmp"):
                continue
            try:
                metadata = os.stat(
                    name,
                    dir_fd=directory_descriptor,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                continue
            if not stat.S_ISREG(metadata.st_mode):
                continue
            if metadata.st_nlink != 1 or metadata.st_uid != os.geteuid():
                continue

            descriptor = -1
            try:
                descriptor = os.open(
                    name,
                    os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
                    dir_fd=directory_descriptor,
                )
                current_metadata = os.fstat(descriptor)
                if (
                    current_metadata.st_dev != metadata.st_dev
                    or current_metadata.st_ino != metadata.st_ino
                ):
                    continue
                digest = hashlib.sha256()
                while True:
                    chunk = os.read(descriptor, 1024 * 1024)
                    if not chunk:
                        break
                    digest.update(chunk)
                if digest.hexdigest() != expected_checksum:
                    continue
                print(os.path.abspath(os.path.join(directory, name)))
                return True
            finally:
                if descriptor >= 0:
                    os.close(descriptor)
    finally:
        os.close(directory_descriptor)
    return False


def prune_lock_state(directory: str, scope: str, keep_name: str) -> None:
    if len(scope) != 16 or any(character not in "0123456789abcdef" for character in scope):
        fail(f"invalid lock scope: {scope}")

    directory_descriptor = open_existing_directory(directory)
    scope_prefix = f".postinstall-lock-{scope}-"
    try:
        for name in os.listdir(directory_descriptor):
            if name == keep_name or not name.startswith(scope_prefix):
                continue
            try:
                metadata = os.stat(
                    name,
                    dir_fd=directory_descriptor,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                continue
            if not stat.S_ISREG(metadata.st_mode):
                continue
            if metadata.st_nlink != 1 or metadata.st_uid != os.geteuid():
                continue
            try:
                os.unlink(name, dir_fd=directory_descriptor)
            except FileNotFoundError:
                continue
        os.fsync(directory_descriptor)
    finally:
        os.close(directory_descriptor)


def ensure_directory(path: str) -> None:
    absolute = os.path.abspath(path)
    name = os.path.basename(absolute)
    if not name or name in {".", ".."}:
        fail(f"invalid directory name: {path}")

    parent = open_parent(path)
    child = -1
    try:
        try:
            metadata = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if stat.S_ISLNK(metadata.st_mode):
                fail(f"directory must not be a symbolic link: {path}")
        except FileNotFoundError:
            pass

        flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
        try:
            child = os.open(name, flags, dir_fd=parent)
        except FileNotFoundError:
            try:
                os.mkdir(name, 0o700, dir_fd=parent)
            except FileExistsError:
                pass
            try:
                child = os.open(name, flags, dir_fd=parent)
            except OSError as error:
                if error.errno == errno.ELOOP:
                    fail(f"directory must not be a symbolic link: {path}")
                raise
        except OSError as error:
            if error.errno == errno.ELOOP:
                fail(f"directory must not be a symbolic link: {path}")
            raise

        metadata = os.fstat(child)
        if not stat.S_ISDIR(metadata.st_mode):
            fail(f"path is not a directory: {path}")
        if metadata.st_uid != os.geteuid():
            fail(f"directory is not owned by the current user: {path}")
        if stat.S_IMODE(metadata.st_mode) & 0o022:
            fail(f"directory is writable by another user: {path}")
        os.fchmod(child, 0o700)
        inspect_parent(child, name, path, allow_sticky=False)
    finally:
        if child >= 0:
            os.close(child)
        os.close(parent)


def create_lock(path: str) -> None:
    absolute = os.path.abspath(path)
    name = os.path.basename(absolute)
    if not name or name in {".", ".."}:
        fail(f"invalid file name: {path}")

    parent = open_parent(path, strict_final_parent=True)
    try:
        try:
            metadata = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if stat.S_ISLNK(metadata.st_mode):
                fail(f"path must not be a symbolic link: {path}")
        except FileNotFoundError:
            pass

        inspect_existing(parent, name, path)

        flags = (
            os.O_RDWR
            | os.O_CREAT
            | os.O_CLOEXEC
            | os.O_NOFOLLOW
            | os.O_NONBLOCK
        )
        descriptor = os.open(name, flags, 0o600, dir_fd=parent)
        try:
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode):
                fail(f"path is not a regular file: {path}")
            if metadata.st_nlink != 1:
                fail(f"path has multiple hard links: {path}")
            if metadata.st_uid != os.geteuid():
                fail(f"path is not owned by the current user: {path}")
            os.fchmod(descriptor, 0o600)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        os.close(parent)


def append(path: str, content: bytes) -> None:
    absolute = os.path.abspath(path)
    name = os.path.basename(absolute)
    if not name or name in {".", ".."}:
        fail(f"invalid file name: {path}")

    parent = open_parent(path)
    try:
        try:
            metadata = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if stat.S_ISLNK(metadata.st_mode):
                fail(f"path must not be a symbolic link: {path}")
        except FileNotFoundError:
            pass

        inspect_existing(parent, name, path)

        flags = (
            os.O_WRONLY
            | os.O_APPEND
            | os.O_CREAT
            | os.O_CLOEXEC
            | os.O_NOFOLLOW
            | os.O_NONBLOCK
        )
        descriptor = os.open(name, flags, 0o600, dir_fd=parent)
        try:
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode):
                fail(f"path is not a regular file: {path}")
            if metadata.st_nlink != 1:
                fail(f"path has multiple hard links: {path}")
            if metadata.st_uid != os.geteuid():
                fail(f"path is not owned by the current user: {path}")

            offset = 0
            while offset < len(content):
                offset += os.write(descriptor, content[offset:])
            os.fchmod(descriptor, 0o600)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        os.close(parent)


def read(path: str) -> None:
    absolute = os.path.abspath(path)
    name = os.path.basename(absolute)
    if not name or name in {".", ".."}:
        fail(f"invalid file name: {path}")

    parent = open_parent(path)
    try:
        flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
        try:
            descriptor = os.open(name, flags, dir_fd=parent)
        except FileNotFoundError:
            fail(f"path does not exist: {path}")
        except OSError as error:
            if error.errno == errno.ELOOP:
                fail(f"path must not be a symbolic link: {path}")
            raise

        try:
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode):
                fail(f"path is not a regular file: {path}")
            if metadata.st_nlink != 1:
                fail(f"path has multiple hard links: {path}")
            if metadata.st_uid != os.geteuid():
                fail(f"path is not owned by the current user: {path}")

            while True:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                sys.stdout.buffer.write(chunk)
        finally:
            os.close(descriptor)
    finally:
        os.close(parent)


def main() -> None:
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    expected_arguments = {
        "append": 3,
        "backup-destination": 5,
        "copy": 4,
        "create-lock": 3,
        "ensure-directory": 3,
        "find-verified": 4,
        "publish": 5,
        "prune": 4,
        "prune-partials": 3,
        "prune-versions": 4,
        "prune-lock-state": 5,
        "read": 3,
        "replace-destination": 5,
        "rollback": 8,
        "validate-file": 3,
        "write": 3,
    }
    usage = (
        "usage: runtime-file.py append|create-lock|ensure-directory|read|"
        "validate-file|write PATH or copy SOURCE DESTINATION or "
        "backup-destination DESTINATION BACKUP IDENTITY or "
        "replace-destination STAGED DESTINATION IDENTITY or "
        "publish SOURCE DESTINATION SHA256 or find-verified DIRECTORY SHA256 or "
        "prune-partials DIRECTORY or prune/prune-versions DIRECTORY KEEP_NAME or "
        "rollback DESTINATION BACKUP ORIGINAL_IDENTITY STAGED_IDENTITY "
        "BACKUP_IDENTITY HAD_ORIGINAL or "
        "prune-lock-state DIRECTORY SCOPE KEEP_NAME"
    )

    if command not in expected_arguments or len(sys.argv) != expected_arguments[command]:
        fail(usage)

    try:
        if command == "append":
            append(sys.argv[2], sys.stdin.buffer.read())
        elif command == "backup-destination":
            status = backup_destination(sys.argv[2], sys.argv[3], sys.argv[4])
            raise SystemExit(status)
        elif command == "copy":
            copy_private(sys.argv[2], sys.argv[3])
        elif command == "create-lock":
            create_lock(sys.argv[2])
        elif command == "ensure-directory":
            ensure_directory(sys.argv[2])
        elif command == "find-verified":
            if not find_verified_artifact(sys.argv[2], sys.argv[3]):
                raise SystemExit(1)
        elif command == "publish":
            publish_file(sys.argv[2], sys.argv[3], sys.argv[4])
        elif command == "prune":
            prune_directory(sys.argv[2], sys.argv[3])
        elif command == "prune-partials":
            prune_partials(sys.argv[2])
        elif command == "prune-versions":
            prune_versions(sys.argv[2], sys.argv[3])
        elif command == "prune-lock-state":
            prune_lock_state(sys.argv[2], sys.argv[3], sys.argv[4])
        elif command == "read":
            read(sys.argv[2])
        elif command == "replace-destination":
            status = replace_destination(sys.argv[2], sys.argv[3], sys.argv[4])
            raise SystemExit(status)
        elif command == "rollback":
            had_original = sys.argv[7]
            if had_original not in {"0", "1"}:
                fail(f"invalid original-file state: {had_original}")
            status = rollback_destination(
                sys.argv[2],
                sys.argv[3],
                sys.argv[4],
                sys.argv[5],
                sys.argv[6],
                had_original == "1",
            )
            raise SystemExit(status)
        elif command == "validate-file":
            absolute = os.path.abspath(sys.argv[2])
            name = os.path.basename(absolute)
            if not name or name in {".", ".."}:
                fail(f"invalid file name: {sys.argv[2]}")
            parent = open_parent(sys.argv[2], strict_final_parent=True)
            try:
                inspect_existing(parent, name, sys.argv[2])
            finally:
                os.close(parent)
        elif command == "write":
            write_stream(sys.argv[2])
    except OSError as error:
        fail(str(error))


if __name__ == "__main__":
    main()
