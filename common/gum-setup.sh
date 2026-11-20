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

# fixed version
GUM_VERSION="2.0.2"

GUM=$(command -v gum || true)

function cleanup_gum_bootstrap {
    if [ -n "${GUM_BOOTSTRAP_DIRECTORY:-}" ] && [ -d "${GUM_BOOTSTRAP_DIRECTORY}" ]; then
        rm -rf -- "${GUM_BOOTSTRAP_DIRECTORY}"
    fi
}

# gum is not available, so download a pinned, checksum-verified release into an
# isolated temporary directory. The directory is removed when the installer exits.
if [ -z "${GUM}" ]; then
    if ! command -v curl > /dev/null 2>&1 || ! command -v sha256sum > /dev/null 2>&1; then
        printf 'gum is required, but curl and sha256sum are unavailable\n' >&2
        exit 1
    fi

    case "$(uname -m)" in
        x86_64|amd64)
            GUM_ARCHIVE="gum_${GUM_VERSION}_Linux_x86_64.tar.gz"
            GUM_ARCHIVE_DIRECTORY="gum_${GUM_VERSION}_Linux_x86_64"
            GUM_CHECKSUM="d842e06d93dbed90af48cb8dd10698db6f22e331fc40346bb37bbc753109edc2"
            ;;
        aarch64|arm64)
            GUM_ARCHIVE="gum_${GUM_VERSION}_Linux_arm64.tar.gz"
            GUM_ARCHIVE_DIRECTORY="gum_${GUM_VERSION}_Linux_arm64"
            GUM_CHECKSUM="8ebf8b54ec1e8c81f2bb58b59ff9b70998186a4d11375f0cf357b80e0ccfa1d5"
            ;;
        *)
            printf 'gum does not publish a release for architecture %s\n' "$(uname -m)" >&2
            exit 1
            ;;
    esac

    GUM_LINK="https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/${GUM_ARCHIVE}"

    echo "╭───────────────────────────────────────────────────────────────────╮"
    echo "│ This script relies on 'gum' -- a tool that provides ready-to-use  │"
    echo "│ utilities to help users write useful, interactive scripts. Please │"
    echo "│ wait while the binary is downloaded from GitHub and extracted to  │"
    echo "│ a temporary directory.                                            │"
    echo "╰───────────────────────────────────────────────────────────────────╯"

    if ! GUM_BOOTSTRAP_DIRECTORY=$(mktemp -d \
        "${TMPDIR:-/tmp}/fedora-postinstall-gum.XXXXXXXX"); then
        printf 'Unable to create a temporary directory for gum\n' >&2
        exit 1
    fi
    trap 'cleanup_gum_bootstrap' EXIT

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
        exit 1
    fi

    actual_checksum=$(sha256sum "${GUM_BOOTSTRAP_DIRECTORY}/${GUM_ARCHIVE}")
    actual_checksum="${actual_checksum%% *}"
    if [ "${actual_checksum}" != "${GUM_CHECKSUM}" ]; then
        printf 'Checksum verification failed for gum %s\n' "${GUM_VERSION}" >&2
        exit 1
    fi

    if ! tar \
        --extract \
        --gzip \
        --file "${GUM_BOOTSTRAP_DIRECTORY}/${GUM_ARCHIVE}" \
        --directory "${GUM_BOOTSTRAP_DIRECTORY}" \
        --no-same-owner \
        --no-same-permissions; then
        printf 'Unable to extract gum %s\n' "${GUM_VERSION}" >&2
        exit 1
    fi

    GUM_PATH="${GUM_BOOTSTRAP_DIRECTORY}/${GUM_ARCHIVE_DIRECTORY}/gum"
    if [ ! -f "${GUM_PATH}" ] || [ -L "${GUM_PATH}" ]; then
        printf 'Unable to locate the gum executable in the downloaded archive\n' >&2
        exit 1
    fi

    GUM="${GUM_BOOTSTRAP_DIRECTORY}/gum"
    if ! install -m 0755 "${GUM_PATH}" "${GUM}"; then
        printf 'Unable to prepare the gum executable\n' >&2
        exit 1
    fi
fi
