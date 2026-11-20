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
declare -gA EXTRAS_DEPLOYMENT_BACKUPS=()
declare -gA EXTRAS_DEPLOYMENT_ATTEMPTED=()
declare -gA EXTRAS_DEPLOYMENT_REPLACED=()
declare -ga EXTRAS_DEPLOYMENT_TARGETS=()
declare -ga EXTRAS_DEPLOYMENT_TEMPORARIES=()
declare -g EXTRAS_DEPLOYMENT_COMPLETE=0
declare -g EXTRAS_DEPLOYMENT_DESTINATION_DIRECTORY=""
declare -g EXTRAS_DEPLOYMENT_BACKUP_DIRECTORY=""

function extras_cleanup_deployment_temporaries {
    local runtime_local_temporary

    for runtime_local_temporary in "${EXTRAS_DEPLOYMENT_TEMPORARIES[@]}"; do
        rm -f -- "${runtime_local_temporary}" 2>/dev/null || true
    done
    EXTRAS_DEPLOYMENT_TEMPORARIES=()
    return 0
}

function extras_restore_deployment {
    local target="${1}"
    local destination_directory="${2}"
    local backup_directory="${3}"
    local had_original="${4}"
    local destination="${destination_directory}/${target}"
    local backup="${backup_directory}/${target}"
    local temporary

    if [ "${EXTRAS_DEPLOYMENT_REPLACED[${target}]:-0}" != "1" ]; then
        return 0
    fi

    if [ "${had_original}" = "1" ]; then
        if [ ! -e "${backup}" ] && [ ! -L "${backup}" ]; then
            printf 'extras: rollback backup is missing for %s\n' "${target}" >&2
            return 1
        fi
        temporary=$(mktemp "${destination_directory}/.${target}.rollback.XXXXXX") || return 1
        if ! cp -a --remove-destination -- "${backup}" "${temporary}"; then
            rm -f -- "${temporary}"
            printf 'extras: unable to restore rollback backup for %s\n' "${target}" >&2
            return 1
        fi
        if ! mv -fT -- "${temporary}" "${destination}"; then
            rm -f -- "${temporary}"
            printf 'extras: unable to replace %s during rollback\n' "${target}" >&2
            return 1
        fi
    elif [ "${EXTRAS_DEPLOYMENT_ATTEMPTED[${target}]:-0}" = "1" ]; then
        if ! rm -f -- "${destination}"; then
            printf 'extras: unable to remove %s during rollback\n' "${target}" >&2
            return 1
        fi
    fi

    return 0
}

function extras_rollback_deployment {
    local target backup had_original
    local status=0
    local index

    if [ "${EXTRAS_DEPLOYMENT_COMPLETE}" -eq 1 ]; then
        return 0
    fi

    if [ -z "${EXTRAS_DEPLOYMENT_DESTINATION_DIRECTORY}" ] ||
        [ -z "${EXTRAS_DEPLOYMENT_BACKUP_DIRECTORY}" ]; then
        return 0
    fi

    for ((index = ${#EXTRAS_DEPLOYMENT_TARGETS[@]} - 1; index >= 0; index--)); do
        target="${EXTRAS_DEPLOYMENT_TARGETS[index]}"
        had_original="${EXTRAS_DEPLOYMENT_ORIGINALS[${target}]:-0}"
        backup="${EXTRAS_DEPLOYMENT_BACKUPS[${target}]:-}"

        if [ "${had_original}" = "1" ] && [ -z "${backup}" ]; then
            printf 'extras: rollback backup path is missing for %s\n' "${target}" >&2
            status=1
            continue
        fi

        if ! extras_restore_deployment "${target}" \
            "${EXTRAS_DEPLOYMENT_DESTINATION_DIRECTORY}" \
            "${EXTRAS_DEPLOYMENT_BACKUP_DIRECTORY}" "${had_original}"; then
            status=1
            continue
        fi

    done

    if [ "${status}" -ne 0 ]; then
        printf 'extras: rollback was incomplete; backups remain in %s\n' \
            "${EXTRAS_DEPLOYMENT_BACKUP_DIRECTORY}" >&2
        return 1
    fi

    if ! rm -rf -- "${EXTRAS_DEPLOYMENT_BACKUP_DIRECTORY}"; then
        printf 'extras: unable to remove rollback backups in %s\n' \
            "${EXTRAS_DEPLOYMENT_BACKUP_DIRECTORY}" >&2
        return 1
    fi

    EXTRAS_DEPLOYMENT_COMPLETE=1
    return 0
}

function deploy_extras_tools {
    local destination_directory="${EXTRAS_DEPLOYMENT_DIRECTORY:-${HOME}/.local/bin}"
    local backup_directory
    local target source tool destination temporary
    local had_original

    if [ ! -d "${EXTRAS_WORKSPACE}" ]; then
        printf 'extras: deployment workspace is not initialized\n' >&2
        return 1
    fi

    if [ ! -s "${EXTRAS_STAGE_LEDGER}" ]; then
        printf 'extras: no staged executables to deploy\n' >&2
        return 1
    fi

    if ! mkdir -p "${destination_directory}"; then
        printf 'extras: unable to create the deployment directory\n' >&2
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
    done <"${EXTRAS_STAGE_LEDGER}"

    if declare -F runtime_enter_critical_section >/dev/null; then
        runtime_enter_critical_section "extras deployment"
    fi

    if ! backup_directory=$(mktemp -d \
        "${destination_directory}/.fedora-postinstall-backups.XXXXXXXX"); then
        printf 'extras: unable to create the rollback backup directory\n' >&2
        if declare -F runtime_leave_critical_section >/dev/null; then
            runtime_leave_critical_section "extras deployment" extras_rollback_deployment
        fi
        return 1
    fi
    chmod 0700 "${backup_directory}" 2>/dev/null || true

    EXTRAS_DEPLOYMENT_COMPLETE=0
    EXTRAS_DEPLOYMENT_DESTINATION_DIRECTORY="${destination_directory}"
    EXTRAS_DEPLOYMENT_BACKUP_DIRECTORY="${backup_directory}"
    EXTRAS_DEPLOYMENT_ORIGINALS=()
    EXTRAS_DEPLOYMENT_BACKUPS=()
    EXTRAS_DEPLOYMENT_ATTEMPTED=()
    EXTRAS_DEPLOYMENT_REPLACED=()
    EXTRAS_DEPLOYMENT_TARGETS=()
    EXTRAS_DEPLOYMENT_TEMPORARIES=()

    while IFS=$'\t' read -r target source tool; do
        destination="${destination_directory}/${target}"
        had_original=0
        if [ -e "${destination}" ] || [ -L "${destination}" ]; then
            if ! cp -a -- "${destination}" "${backup_directory}/${target}"; then
                printf 'extras: unable to back up existing file: %s\n' "${destination}" >&2
                rm -rf -- "${backup_directory}"
                EXTRAS_DEPLOYMENT_BACKUP_DIRECTORY=""
                if declare -F runtime_leave_critical_section >/dev/null; then
                    runtime_leave_critical_section "extras deployment" extras_rollback_deployment
                fi
                return 1
            fi
            had_original=1
        fi
        EXTRAS_DEPLOYMENT_ORIGINALS["${target}"]="${had_original}"
        EXTRAS_DEPLOYMENT_BACKUPS["${target}"]="${backup_directory}/${target}"
        EXTRAS_DEPLOYMENT_TARGETS+=("${target}")
    done <"${EXTRAS_STAGE_LEDGER}"

    while IFS=$'\t' read -r target source tool; do
        destination="${destination_directory}/${target}"
        EXTRAS_DEPLOYMENT_ATTEMPTED["${target}"]="1"

        temporary=$(mktemp "${destination_directory}/.${target}.tmp.XXXXXX") || {
            printf 'extras: unable to create temporary file for %s\n' "${target}" >&2
            extras_rollback_deployment || true
            if declare -F runtime_leave_critical_section >/dev/null; then
                runtime_leave_critical_section "extras deployment" extras_rollback_deployment
            fi
            return 1
        }
        EXTRAS_DEPLOYMENT_TEMPORARIES+=("${temporary}")

        if ! install -m 0755 "${source}" "${temporary}"; then
            rm -f -- "${temporary}"
            printf 'extras: unable to stage deployment file: %s\n' "${target}" >&2
            extras_rollback_deployment || true
            if declare -F runtime_leave_critical_section >/dev/null; then
                runtime_leave_critical_section "extras deployment" extras_rollback_deployment
            fi
            return 1
        fi
        if ! mv -fT -- "${temporary}" "${destination}"; then
            rm -f -- "${temporary}"
            printf 'extras: unable to deploy executable: %s\n' "${target}" >&2
            extras_rollback_deployment || true
            if declare -F runtime_leave_critical_section >/dev/null; then
                runtime_leave_critical_section "extras deployment" extras_rollback_deployment
            fi
            return 1
        fi
        EXTRAS_DEPLOYMENT_REPLACED["${target}"]="1"
    done <"${EXTRAS_STAGE_LEDGER}"

    # Leave the critical section before committing. If a signal was deferred,
    # the rollback callback restores the original files before shutdown.
    if declare -F runtime_leave_critical_section >/dev/null; then
        runtime_leave_critical_section "extras deployment" extras_rollback_deployment
    fi

    # The deployment is committed once every destination has been replaced.
    # Failure to remove the now-unused backups must not roll back a committed
    # deployment; the cleanup callback will retry removing them.
    EXTRAS_DEPLOYMENT_COMPLETE=1
    if ! rm -rf -- "${backup_directory}"; then
        printf 'extras: unable to remove rollback backups in %s\n' \
            "${backup_directory}" >&2
    else
        EXTRAS_DEPLOYMENT_BACKUP_DIRECTORY=""
    fi
    return 0
}
