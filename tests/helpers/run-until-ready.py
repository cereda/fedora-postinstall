#!/usr/bin/env python3

# SPDX-License-Identifier: MIT

"""Run a command, signal it after a readiness marker, and preserve its status."""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import time


def main(argv: list[str]) -> int:
    if (
        len(argv) < 8
        or argv[0] != "--signal"
        or argv[2] != "--ready"
        or argv[4] != "--timeout"
        or argv[6] != "--"
    ):
        print("run-until-ready: invalid arguments", file=sys.stderr)
        return 64

    signal_name = argv[1]
    ready_path = argv[3]
    try:
        signal_number = getattr(signal, f"SIG{signal_name}")
    except AttributeError:
        print("run-until-ready: unsupported signal", file=sys.stderr)
        return 64

    try:
        timeout = float(argv[5])
    except ValueError:
        print("run-until-ready: invalid timeout", file=sys.stderr)
        return 64
    command = argv[7:]
    if not command:
        print("run-until-ready: a command is required", file=sys.stderr)
        return 64

    try:
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            close_fds=True,
            start_new_session=True,
        )
    except OSError as error:
        print(f"run-until-ready: unable to start command: {error}", file=sys.stderr)
        return 69

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(ready_path):
            break
        if process.poll() is not None:
            output = process.stdout.read() if process.stdout is not None else b""
            if output:
                sys.stdout.buffer.write(output)
                sys.stdout.buffer.flush()
            return process.returncode if process.returncode is not None else 1
        time.sleep(0.05)
    else:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except OSError:
            pass
        output = process.stdout.read() if process.stdout is not None else b""
        if output:
            sys.stdout.buffer.write(output)
            sys.stdout.buffer.flush()
        print("run-until-ready: readiness marker timed out", file=sys.stderr)
        return 124

    try:
        os.kill(process.pid, signal_number)
    except OSError as error:
        print(f"run-until-ready: unable to signal command: {error}", file=sys.stderr)
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except OSError:
            pass
        process.wait()
        return 69

    try:
        output = process.communicate(timeout=max(timeout, 15.0))[0]
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except OSError:
            pass
        output = process.communicate()[0]
        if output:
            sys.stdout.buffer.write(output)
            sys.stdout.buffer.flush()
        print("run-until-ready: signaled command timed out", file=sys.stderr)
        return 124
    if output:
        sys.stdout.buffer.write(output)
        sys.stdout.buffer.flush()

    status = process.returncode
    if status is None:
        return 1
    if status < 0:
        return 128 + (-status)
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
