#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

function require_command {
    local command_name="${1}"
    local purpose="${2:-required by this script}"

    if ! command -v "${command_name}" >/dev/null 2>&1; then
        printf "Required command '%s' was not found (%s).\n" \
            "${command_name}" "${purpose}" >&2
        printf 'Install it first, for example with: sudo dnf install %s\n' \
            "${command_name}" >&2
        return 1
    fi
}

function require_runtime_dependencies {
    require_command "rpm" "needed to detect the Fedora version" || return 1
    require_command "wget" "needed to download installers and tools" || return 1
    require_command "curl" "needed by several installers" || return 1
    require_command "tar" "needed to extract downloaded archives" || return 1
    require_command "unzip" "needed to extract downloaded ZIP archives" || return 1
    require_command "python3" "needed to safely extract downloaded archives" || return 1
    require_command "sha256sum" "needed to verify downloaded tools" || return 1
    require_command "install" "needed to deploy command line tools" || return 1
    require_command "mktemp" "needed to create isolated temporary directories" || return 1
    require_command "jq" "needed to inspect the command line tool manifest" || return 1
    require_command "git" "needed by several installers" || return 1
    require_command "realpath" "needed to validate configuration paths" || return 1
    require_command "flock" "needed to serialize post-installation runs" || return 1
}
