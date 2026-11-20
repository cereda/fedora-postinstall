#!/usr/bin/env python3

# MIT License
#
# Copyright (c) 2026, Paulo Cereda
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

import errno
import os
import stat
import sys


def fail(message: str) -> None:
    print(f"runtime-file: {message}", file=sys.stderr)
    raise SystemExit(1)


def inspect_parent(descriptor: int, component: str, path: str) -> None:
    metadata = os.fstat(descriptor)
    mode = stat.S_IMODE(metadata.st_mode)

    if metadata.st_uid not in {0, os.geteuid()}:
        fail(f"parent directory is not owned by the current user or root: {path}")

    if mode & 0o022 and not mode & stat.S_ISVTX:
        fail(f"parent directory is writable by another user: {path}")


def open_parent(path: str) -> int:
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


def append(path: str, content: bytes) -> None:
    absolute = os.path.abspath(path)
    name = os.path.basename(absolute)
    if not name or name in {".", ".."}:
        fail(f"invalid file name: {path}")

    parent = open_parent(path)
    try:
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
    if len(sys.argv) != 3:
        fail("usage: runtime-file.py append|read PATH")

    try:
        if sys.argv[1] == "append":
            append(sys.argv[2], sys.stdin.buffer.read())
        elif sys.argv[1] == "read":
            read(sys.argv[2])
        else:
            fail("usage: runtime-file.py append|read PATH")
    except OSError as error:
        fail(str(error))


if __name__ == "__main__":
    main()
