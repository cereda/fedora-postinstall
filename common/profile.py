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

import json
import os
import re
import stat
import sys
from typing import Any


PROFILE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
MODULE_PATTERN = re.compile(r"^[A-Za-z0-9_*?./-]+$")
TOOL_NAME = re.compile(r"^[a-z0-9][a-z0-9-]*$")
FLAVORS = {"workstation", "silverblue"}
TOP_LEVEL_KEYS = {"schema_version", "name", "description", "flavors", "modules", "extras"}
MODULE_KEYS = {"include", "exclude"}
EXTRAS_KEYS = {"tools"}


class ProfileError(ValueError):
    pass


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ProfileError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def require_string_array(value: Any, field: str, validator: re.Pattern[str]) -> list[str]:
    if not isinstance(value, list):
        raise ProfileError(f"{field} must be an array")
    result: list[str] = []
    seen: set[str] = set()
    for item in value:
        if not isinstance(item, str) or not validator.fullmatch(item):
            raise ProfileError(f"{field} contains an invalid value")
        if item in seen:
            raise ProfileError(f"{field} contains a duplicate value: {item}")
        seen.add(item)
        result.append(item)
    return result


def validate_profile(document: Any) -> dict[str, Any]:
    if not isinstance(document, dict):
        raise ProfileError("profile must be a JSON object")

    unknown = set(document) - TOP_LEVEL_KEYS
    if unknown:
        raise ProfileError(f"unknown profile field: {sorted(unknown)[0]}")

    version = document.get("schema_version")
    if isinstance(version, bool) or version != 1:
        raise ProfileError("schema_version must be exactly 1")

    name = document.get("name")
    if not isinstance(name, str) or not PROFILE_NAME.fullmatch(name):
        raise ProfileError("name must be a valid profile identifier")

    description = document.get("description")
    if not isinstance(description, str):
        raise ProfileError("description must be a string")

    normalized: dict[str, Any] = {
        "schema_version": 1,
        "name": name,
        "description": description,
    }

    if "flavors" in document:
        flavors = require_string_array(document["flavors"], "flavors", re.compile(r"^[A-Za-z0-9_-]+$"))
        if not flavors or any(flavor not in FLAVORS for flavor in flavors):
            raise ProfileError("flavors must contain workstation and/or silverblue")
        normalized["flavors"] = flavors

    if "modules" in document:
        modules = document["modules"]
        if not isinstance(modules, dict):
            raise ProfileError("modules must be an object")
        unknown = set(modules) - MODULE_KEYS
        if unknown:
            raise ProfileError(f"unknown modules field: {sorted(unknown)[0]}")
        normalized_modules: dict[str, list[str]] = {}
        for key in ("include", "exclude"):
            if key in modules:
                normalized_modules[key] = require_string_array(
                    modules[key], f"modules.{key}", MODULE_PATTERN
                )
        normalized["modules"] = normalized_modules

    if "extras" in document:
        extras = document["extras"]
        if not isinstance(extras, dict):
            raise ProfileError("extras must be an object")
        unknown = set(extras) - EXTRAS_KEYS
        if unknown:
            raise ProfileError(f"unknown extras field: {sorted(unknown)[0]}")
        normalized_extras: dict[str, list[str]] = {}
        if "tools" in extras:
            normalized_extras["tools"] = require_string_array(
                extras["tools"], "extras.tools", TOOL_NAME
            )
        normalized["extras"] = normalized_extras

    return normalized


def inspect_file(path: str) -> None:
    metadata = os.lstat(path)
    if stat.S_ISLNK(metadata.st_mode):
        raise ProfileError("profile must not be a symbolic link")
    if not stat.S_ISREG(metadata.st_mode):
        raise ProfileError("profile must be a regular file")
    if metadata.st_uid not in {0, os.geteuid()}:
        raise ProfileError("profile must be owned by the current user or root")
    if metadata.st_size > 1024 * 1024:
        raise ProfileError("profile is larger than 1 MiB")


def main() -> None:
    if len(sys.argv) != 2:
        print("profile.py: usage: profile.py PROFILE", file=sys.stderr)
        raise SystemExit(65)

    path = sys.argv[1]
    try:
        inspect_file(path)
        with open(path, encoding="utf-8") as stream:
            document = json.load(stream, object_pairs_hook=unique_object)
        normalized = validate_profile(document)
    except (OSError, UnicodeError, json.JSONDecodeError, ProfileError) as error:
        print(f"profile: invalid profile: {error}", file=sys.stderr)
        raise SystemExit(65)

    json.dump(normalized, sys.stdout, ensure_ascii=False, sort_keys=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
