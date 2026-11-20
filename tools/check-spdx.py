#!/usr/bin/env python3

# SPDX-License-Identifier: MIT

import subprocess
import sys
from pathlib import Path


SOURCE_SUFFIXES = {".bash", ".bats", ".py", ".sh"}
COMMENT_SUFFIXES = {".md", ".psv", ".yaml", ".yml"}
SPECIAL_FILES = {".gitignore", "Makefile"}


def tracked_files() -> list[str]:
    output = subprocess.check_output(["git", "ls-files", "-z"])
    return [name for name in output.decode().split("\0") if name]


def expected_marker(name: str) -> str | None:
    path = Path(name)
    if path.suffix in SOURCE_SUFFIXES or name in SPECIAL_FILES or path.suffix == ".psv":
        return "# SPDX-License-Identifier: MIT"
    if path.suffix == ".md":
        return "<!-- SPDX-License-Identifier: MIT -->"
    if path.suffix in COMMENT_SUFFIXES:
        return "# SPDX-License-Identifier: MIT"
    return None


def main() -> int:
    failures: list[str] = []

    for name in tracked_files():
        marker = expected_marker(name)
        if marker is None:
            continue

        path = Path(name)
        if not path.is_file():
            failures.append(f"{name}: expected SPDX marker but file is missing")
            continue

        lines = path.read_text(encoding="utf-8").splitlines()
        search_start = 1 if lines and lines[0].startswith("#!") else 0
        header = lines[search_start : search_start + 5]
        matches = [line for line in header if "SPDX-License-Identifier:" in line]

        if matches != [marker]:
            failures.append(
                f"{name}: expected exactly one SPDX marker near the beginning of the file"
            )

        text = path.read_text(encoding="utf-8")
        legacy_marker = "Permission is hereby " + "granted, free of charge"
        if legacy_marker in text:
            failures.append(f"{name}: legacy MIT license block is still present")

    if failures:
        for failure in failures:
            print(f"license: {failure}", file=sys.stderr)
        return 1

    print("license: SPDX headers are valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
