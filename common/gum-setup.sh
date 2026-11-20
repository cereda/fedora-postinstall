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

GUM=$(command -v gum || true)

function cleanup_gum_bootstrap {
    if [ -n "${GUM_BOOTSTRAP_DIRECTORY:-}" ] && [ -d "${GUM_BOOTSTRAP_DIRECTORY}" ]; then
        rm -rf -- "${GUM_BOOTSTRAP_DIRECTORY}"
    fi
}

# gum is not available, so download a pinned, checksum-verified release into an
# isolated temporary directory. The directory is removed when the installer exits.
if [ -z "${GUM}" ]; then
    if ! command -v curl >/dev/null 2>&1 || ! command -v sha256sum >/dev/null 2>&1; then
        printf 'gum is required, but curl and sha256sum are unavailable\n' >&2
        return 1
    fi

    if ! GUM_ARCHITECTURE=$(runtime_selected_architecture); then
        printf 'gum does not publish a release for architecture %s\n' \
            "${POSTINSTALL_ARCHITECTURE:-$(uname -m)}" >&2
        return 1
    fi

    GUM_MANIFEST_FILE="${SCRIPT_PATH}/extras/tools-manifest.json"
    if [ ! -f "${GUM_MANIFEST_FILE}" ] || [ -L "${GUM_MANIFEST_FILE}" ]; then
        printf 'Unable to load the authoritative gum manifest\n' >&2
        return 1
    fi

    if ! GUM_ENTRY=$(jq -ce --arg architecture "${GUM_ARCHITECTURE}" \
        '.tools.gum.assets[$architecture] // .tools.gum.assets.any // empty' \
        "${GUM_MANIFEST_FILE}"); then
        printf 'gum is not available for architecture %s\n' "${GUM_ARCHITECTURE}" >&2
        return 1
    fi

    GUM_VERSION=$(jq -r '.tools.gum.version' "${GUM_MANIFEST_FILE}")
    GUM_LINK=$(jq -r '.url' <<<"${GUM_ENTRY}")
    GUM_CHECKSUM=$(jq -r '.sha256' <<<"${GUM_ENTRY}")
    GUM_MEMBER=$(jq -r '.files | keys[0]' <<<"${GUM_ENTRY}")
    GUM_ARCHIVE=$(basename -- "${GUM_LINK}")

    if [[ ! "${GUM_LINK}" =~ ^https:// ]] ||
        ! [[ "${GUM_CHECKSUM}" =~ ^[0-9a-f]{64}$ ]] ||
        [ -z "${GUM_MEMBER}" ]; then
        printf 'The authoritative gum manifest entry is invalid\n' >&2
        return 1
    fi

    echo "╭───────────────────────────────────────────────────────────────────╮"
    echo "│ This script relies on 'gum' -- a tool that provides ready-to-use  │"
    echo "│ utilities to help users write useful, interactive scripts. Please │"
    echo "│ wait while the binary is downloaded from GitHub and extracted to  │"
    echo "│ a temporary directory.                                            │"
    echo "╰───────────────────────────────────────────────────────────────────╯"

    if ! GUM_BOOTSTRAP_DIRECTORY=$(mktemp -d \
        "${TMPDIR:-/tmp}/fedora-postinstall-gum.XXXXXXXX"); then
        printf 'Unable to create a temporary directory for gum\n' >&2
        return 1
    fi
    if ! runtime_register_cleanup "gum-bootstrap" cleanup_gum_bootstrap; then
        printf 'Unable to register the gum bootstrap cleanup\n' >&2
        return 1
    fi

    if ! curl \
        --fail \
        --location \
        --silent \
        --show-error \
        --retry 3 \
        --retry-delay 2 \
        --connect-timeout 20 \
        --max-time 300 \
        --proto '=https' \
        --tlsv1.2 \
        --output "${GUM_BOOTSTRAP_DIRECTORY}/${GUM_ARCHIVE}" \
        "${GUM_LINK}"; then
        printf 'Unable to download gum %s\n' "${GUM_VERSION}" >&2
        return 1
    fi

    actual_checksum=$(sha256sum "${GUM_BOOTSTRAP_DIRECTORY}/${GUM_ARCHIVE}")
    actual_checksum="${actual_checksum%% *}"
    if [ "${actual_checksum}" != "${GUM_CHECKSUM}" ]; then
        printf 'Checksum verification failed for gum %s\n' "${GUM_VERSION}" >&2
        return 1
    fi

    if ! python3 "${SCRIPT_PATH}/extras/archive-extract.py" \
        --archive "${GUM_BOOTSTRAP_DIRECTORY}/${GUM_ARCHIVE}" \
        --type tar.gz \
        --destination "${GUM_BOOTSTRAP_DIRECTORY}/extracted" \
        --members "${GUM_MEMBER}"; then
        printf 'Unable to extract gum %s\n' "${GUM_VERSION}" >&2
        return 1
    fi

    GUM_PATH="${GUM_BOOTSTRAP_DIRECTORY}/extracted/${GUM_MEMBER}"
    if [ ! -f "${GUM_PATH}" ] || [ -L "${GUM_PATH}" ]; then
        printf 'Unable to locate the gum executable in the downloaded archive\n' >&2
        return 1
    fi

    GUM="${GUM_BOOTSTRAP_DIRECTORY}/gum"
    if ! install -m 0755 "${GUM_PATH}" "${GUM}"; then
        printf 'Unable to prepare the gum executable\n' >&2
        return 1
    fi
fi
