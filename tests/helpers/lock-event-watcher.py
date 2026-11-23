#!/usr/bin/env python3

# SPDX-License-Identifier: MIT

import ctypes
import os
import select
import struct
import sys


IN_MOVED_TO = 0x00000080
INOTIFY_HEADER = struct.Struct("=iIII")


def write_event(descriptor: int, event: bytes) -> None:
    offset = 0
    while offset < len(event):
        written = os.write(descriptor, event[offset:])
        if written <= 0:
            raise OSError("unable to publish lock event")
        offset += written


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: lock-event-watcher.py CACHE_DIRECTORY EVENT_FD", file=sys.stderr)
        return 64

    cache_directory = sys.argv[1]
    event_fd = int(sys.argv[2])

    libc = ctypes.CDLL(None, use_errno=True)
    libc.inotify_init1.argtypes = [ctypes.c_int]
    libc.inotify_init1.restype = ctypes.c_int
    libc.inotify_add_watch.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint32,
    ]
    libc.inotify_add_watch.restype = ctypes.c_int

    watch_fd = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
    if watch_fd < 0:
        return 1
    watch_id = libc.inotify_add_watch(
        watch_fd,
        os.fsencode(cache_directory),
        IN_MOVED_TO,
    )
    if watch_id < 0:
        os.close(watch_fd)
        return 1

    try:
        write_event(event_fd, b"W\tready\n")
        poller = select.poll()
        poller.register(watch_fd, select.POLLIN)
        while True:
            poller.poll()
            data = os.read(watch_fd, 65536)
            offset = 0
            while offset < len(data):
                _watch_id, mask, _cookie, name_length = INOTIFY_HEADER.unpack_from(
                    data,
                    offset,
                )
                offset += INOTIFY_HEADER.size
                raw_name = data[offset : offset + name_length]
                offset += name_length
                name = raw_name.split(b"\0", 1)[0].decode("utf-8")

                if not mask & IN_MOVED_TO:
                    continue
                if not name.startswith(".postinstall-lock-"):
                    continue
                if not name.endswith(".decision"):
                    continue

                decision_path = os.path.join(cache_directory, name)
                with open(decision_path, "rb") as decision_file:
                    decision_state = decision_file.read(64).decode("ascii")
                write_event(
                    event_fd,
                    f"D\t{decision_state}\t{decision_path}\n".encode("ascii"),
                )
                return 0
    finally:
        os.close(watch_fd)


if __name__ == "__main__":
    raise SystemExit(main())
