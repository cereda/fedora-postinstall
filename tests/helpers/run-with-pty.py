#!/usr/bin/env python3

# SPDX-License-Identifier: MIT

"""Run a command with a pseudo-terminal and preserve its exit status."""

from __future__ import annotations

import errno
import os
import pty
import subprocess
import sys
import termios
import tty


def main(argv: list[str]) -> int:
    input_text = ""
    input_provided = False
    stdin_only = False
    stderr_tty = False
    while argv and argv[0].startswith("--"):
        option = argv.pop(0)
        if option == "--input":
            if not argv:
                print("run-with-pty: --input requires a value", file=sys.stderr)
                return 64
            input_text = argv.pop(0)
            input_provided = True
        elif option == "--stdin-only":
            stdin_only = True
        elif option == "--stderr-tty":
            stderr_tty = True
        elif option == "--":
            break
        else:
            print(f"run-with-pty: unsupported option: {option}", file=sys.stderr)
            return 64
    if not argv:
        print("run-with-pty: a command is required", file=sys.stderr)
        return 64

    controller, terminal = pty.openpty()
    try:
        attributes = termios.tcgetattr(terminal)
        attributes[1] &= ~termios.OPOST
        termios.tcsetattr(terminal, termios.TCSANOW, attributes)
        tty.setraw(terminal)

        process = subprocess.Popen(
            argv,
            stdin=terminal,
            stdout=None if stdin_only else terminal,
            stderr=terminal if stderr_tty else (None if stdin_only else terminal),
            close_fds=True,
            start_new_session=True,
        )
    except OSError as error:
        os.close(controller)
        os.close(terminal)
        print(f"run-with-pty: unable to start command: {error}", file=sys.stderr)
        return 69

    os.close(terminal)
    if input_provided:
        payload = input_text.encode("utf-8")
        if not payload.endswith(b"\n"):
            payload += b"\n"
        try:
            os.write(controller, payload)
        except OSError:
            pass
    try:
        while True:
            try:
                chunk = os.read(controller, 65536)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            destination = (
                sys.stderr.buffer if stderr_tty and stdin_only else sys.stdout.buffer
            )
            destination.write(chunk)
            destination.flush()
    finally:
        os.close(controller)

    status = process.wait()
    if status < 0:
        return 128 + (-status)
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
