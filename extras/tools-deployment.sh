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

declare -gA EXTRAS_DEPLOYMENT_ORIGINALS=()

function extras_restore_deployment {
    local target="${1}"
    local destination_directory="${2}"
    local backup_directory="${3}"
    local had_original="${4}"
    local destination="${destination_directory}/${target}"
    local backup="${backup_directory}/${target}"
    local temporary

    if [ "${had_original}" = "1" ]; then
        if [ ! -e "${backup}" ] && [ ! -L "${backup}" ]; then
            printf 'extras: rollback backup is missing for %s\n' "${target}" >&2
            return 1
        fi
        temporary=$(mktemp "${destination_directory}/.${target}.rollback.XXXXXX") || return 1
        if ! cp -a --remove-destination -- "${backup}" "${temporary}"; then
            rm -f -- "${temporary}"
            return 1
        fi
        if ! mv -fT -- "${temporary}" "${destination}"; then
            rm -f -- "${temporary}"
            return 1
        fi
    elif ! rm -f -- "${destination}"; then
        return 1
    fi

    return 0
}

function deploy_extras_tools {
    local destination_directory="${EXTRAS_DEPLOYMENT_DIRECTORY:-${HOME}/.local/bin}"
    local backup_directory="${EXTRAS_WORKSPACE}/backups"
    local target source tool destination temporary
    local had_original replaced_targets=()
    local line

    if [ ! -d "${EXTRAS_WORKSPACE}" ]; then
        printf 'extras: deployment workspace is not initialized\n' >&2
        return 1
    fi

    if [ ! -s "${EXTRAS_STAGE_LEDGER}" ]; then
        printf 'extras: no staged executables to deploy\n' >&2
        return 1
    fi

    if ! mkdir -p "${destination_directory}" "${backup_directory}"; then
        printf 'extras: unable to create deployment directories\n' >&2
        return 1
    fi

    while IFS=$'\t' read -r target source tool; do
        if ! [[ "${target}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
            printf 'extras: invalid deployment target: %s\n' "${target}" >&2
            return 1
        fi
        if [ ! -f "${source}" ] || [ -L "${source}" ]; then
            printf 'extras: invalid staged executable for tool "%s"\n' "${tool}" >&2
            return 1
        fi
        destination="${destination_directory}/${target}"
        if [ -d "${destination}" ] && [ ! -L "${destination}" ]; then
            printf 'extras: deployment target is a directory: %s\n' "${destination}" >&2
            return 1
        fi
        if { [ -e "${destination}" ] || [ -L "${destination}" ]; } &&
            [ ! -L "${destination}" ] && [ ! -f "${destination}" ]; then
            printf 'extras: deployment target is not a regular file: %s\n' "${destination}" >&2
            return 1
        fi

        had_original=0
        if [ -e "${destination}" ] || [ -L "${destination}" ]; then
            if ! cp -a -- "${destination}" "${backup_directory}/${target}"; then
                printf 'extras: unable to back up existing file: %s\n' "${destination}" >&2
                return 1
            fi
            had_original=1
        fi
        EXTRAS_DEPLOYMENT_ORIGINALS["${target}"]="${had_original}"
    done < "${EXTRAS_STAGE_LEDGER}"

    while IFS=$'\t' read -r target source tool; do
        destination="${destination_directory}/${target}"

        temporary=$(mktemp "${destination_directory}/.${target}.tmp.XXXXXX") || {
            printf 'extras: unable to create temporary file for %s\n' "${target}" >&2
            for line in "${replaced_targets[@]}"; do
                extras_restore_deployment "${line}" "${destination_directory}" \
                    "${backup_directory}" "${EXTRAS_DEPLOYMENT_ORIGINALS[${line}]:-0}" || true
            done
            return 1
        }
        if ! install -m 0755 "${source}" "${temporary}"; then
            rm -f -- "${temporary}"
            printf 'extras: unable to stage deployment file: %s\n' "${target}" >&2
            for line in "${replaced_targets[@]}"; do
                extras_restore_deployment "${line}" "${destination_directory}" \
                    "${backup_directory}" "${EXTRAS_DEPLOYMENT_ORIGINALS[${line}]:-0}" || true
            done
            return 1
        fi
        if ! mv -fT -- "${temporary}" "${destination}"; then
            rm -f -- "${temporary}"
            printf 'extras: unable to deploy executable: %s\n' "${target}" >&2

            for line in "${replaced_targets[@]}"; do
                extras_restore_deployment "${line}" "${destination_directory}" \
                    "${backup_directory}" "${EXTRAS_DEPLOYMENT_ORIGINALS[${line}]:-0}" || true
            done
            return 1
        fi

        replaced_targets+=("${target}")
    done < "${EXTRAS_STAGE_LEDGER}"

    return 0
}
