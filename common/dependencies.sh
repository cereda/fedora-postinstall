#!/usr/bin/env bash

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

function require_command {
    local command_name="${1}"
    local purpose="${2:-required by this script}"

    if ! command -v "${command_name}" > /dev/null 2>&1; then
        text "Required command '${command_name}' was not found (${purpose})."
        text "Install it first, for example with: sudo dnf install ${command_name}"
        exit 1
    fi
}

function require_runtime_dependencies {
    require_command "rpm" "needed to detect the Fedora version"
    require_command "wget" "needed to download installers and tools"
    require_command "curl" "needed by several installers"
    require_command "tar" "needed to extract downloaded archives"
    require_command "unzip" "needed to extract downloaded ZIP archives"
    require_command "sha256sum" "needed to verify downloaded tools"
    require_command "install" "needed to deploy command line tools"
    require_command "mktemp" "needed to create isolated temporary directories"
    require_command "jq" "needed to inspect the command line tool manifest"
    require_command "git" "needed by several installers"
    require_command "realpath" "needed to validate configuration paths"
}
