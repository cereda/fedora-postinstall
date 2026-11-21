#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

declare -gA EXTRAS_DEPLOYMENT_ORIGINALS=()
declare -gA EXTRAS_DEPLOYMENT_BACKUPS=()
declare -gA EXTRAS_DEPLOYMENT_ATTEMPTED=()
declare -gA EXTRAS_DEPLOYMENT_ORIGINAL_IDENTITIES=()
declare -gA EXTRAS_DEPLOYMENT_STAGED_IDENTITIES=()
declare -gA EXTRAS_DEPLOYMENT_STAGED_PATHS=()
declare -gA EXTRAS_DEPLOYMENT_BACKUP_IDENTITIES=()
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
    local original_identity="${EXTRAS_DEPLOYMENT_ORIGINAL_IDENTITIES[${target}]:--}"
    local staged_identity="${EXTRAS_DEPLOYMENT_STAGED_IDENTITIES[${target}]:-}"
    local backup_identity="${EXTRAS_DEPLOYMENT_BACKUP_IDENTITIES[${target}]:--}"
    local rollback_status=0

    if [ "${EXTRAS_DEPLOYMENT_REPLACED[${target}]:-0}" != "1" ]; then
        return 0
    fi
    if [ -z "${staged_identity}" ]; then
        printf 'extras: rollback staged identity is missing for %s\n' "${target}" >&2
        return 1
    fi
    if [ "${had_original}" = "1" ] &&
        { [ "${original_identity}" = "-" ] || [ "${backup_identity}" = "-" ]; }; then
        printf 'extras: rollback identity is missing for %s\n' "${target}" >&2
        return 1
    fi

    if python3 "${SCRIPT_PATH}/common/runtime-file.py" rollback \
        "${destination}" "${backup}" "${original_identity}" "${staged_identity}" \
        "${backup_identity}" "${had_original}"; then
        return 0
    else
        rollback_status="${?}"
    fi

    if [ "${rollback_status}" -eq 3 ]; then
        printf 'extras: rollback skipped for %s because the destination changed; the recovery backup was retained\n' \
            "${target}" >&2
    else
        printf 'extras: unable to restore %s during rollback\n' "${target}" >&2
    fi
    return 1
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
    local had_original original_identity staged_identity backup_identity backup_original
    local backup_result backup_status replace_status hard_link_count
    local -A expected_original_identities=()

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

    # Capture the exact identity of every destination before changing any
    # entry. The backup helper verifies this identity again before moving the
    # original into the recovery directory.
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
        if [ -f "${destination}" ] && [ ! -L "${destination}" ]; then
            if ! hard_link_count=$(stat -c '%h' -- "${destination}"); then
                printf 'extras: unable to inspect deployment target: %s\n' \
                    "${destination}" >&2
                return 1
            fi
            if [ "${hard_link_count}" -ne 1 ]; then
                printf 'extras: deployment target has multiple hard links: %s\n' \
                    "${destination}" >&2
                return 1
            fi
        fi
        if { [ -e "${destination}" ] || [ -L "${destination}" ]; } &&
            [ ! -L "${destination}" ] && [ ! -f "${destination}" ]; then
            printf 'extras: deployment target is not a regular file: %s\n' "${destination}" >&2
            return 1
        fi

        if [ -e "${destination}" ] || [ -L "${destination}" ]; then
            if ! original_identity=$(stat -c '%d:%i' -- "${destination}"); then
                printf 'extras: unable to identify deployment target: %s\n' \
                    "${destination}" >&2
                return 1
            fi
        else
            original_identity="-"
        fi
        expected_original_identities["${target}"]="${original_identity}"
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
    EXTRAS_DEPLOYMENT_ORIGINAL_IDENTITIES=()
    EXTRAS_DEPLOYMENT_STAGED_IDENTITIES=()
    EXTRAS_DEPLOYMENT_STAGED_PATHS=()
    EXTRAS_DEPLOYMENT_BACKUP_IDENTITIES=()
    EXTRAS_DEPLOYMENT_REPLACED=()
    EXTRAS_DEPLOYMENT_TARGETS=()
    EXTRAS_DEPLOYMENT_TEMPORARIES=()

    # Stage every executable before moving any original out of the deployment
    # directory. A staging failure therefore leaves every destination intact.
    while IFS=$'\t' read -r target source tool; do
        destination="${destination_directory}/${target}"
        temporary=$(mktemp "${destination_directory}/.${target}.tmp.XXXXXX") || {
            printf 'extras: unable to create temporary file for %s\n' "${target}" >&2
            extras_cleanup_deployment_temporaries
            rm -rf -- "${backup_directory}"
            EXTRAS_DEPLOYMENT_BACKUP_DIRECTORY=""
            if declare -F runtime_leave_critical_section >/dev/null; then
                runtime_leave_critical_section "extras deployment" extras_rollback_deployment
            fi
            return 1
        }
        EXTRAS_DEPLOYMENT_TEMPORARIES+=("${temporary}")

        if ! install -m 0755 "${source}" "${temporary}"; then
            rm -f -- "${temporary}"
            printf 'extras: unable to stage deployment file: %s\n' "${target}" >&2
            extras_cleanup_deployment_temporaries
            rm -rf -- "${backup_directory}"
            EXTRAS_DEPLOYMENT_BACKUP_DIRECTORY=""
            if declare -F runtime_leave_critical_section >/dev/null; then
                runtime_leave_critical_section "extras deployment" extras_rollback_deployment
            fi
            return 1
        fi
        if ! staged_identity=$(stat -c '%d:%i' -- "${temporary}"); then
            rm -f -- "${temporary}"
            printf 'extras: unable to identify staged deployment file: %s\n' "${target}" >&2
            extras_cleanup_deployment_temporaries
            rm -rf -- "${backup_directory}"
            EXTRAS_DEPLOYMENT_BACKUP_DIRECTORY=""
            if declare -F runtime_leave_critical_section >/dev/null; then
                runtime_leave_critical_section "extras deployment" extras_rollback_deployment
            fi
            return 1
        fi

        EXTRAS_DEPLOYMENT_TARGETS+=("${target}")
        EXTRAS_DEPLOYMENT_STAGED_IDENTITIES["${target}"]="${staged_identity}"
        EXTRAS_DEPLOYMENT_STAGED_PATHS["${target}"]="${temporary}"
        EXTRAS_DEPLOYMENT_ATTEMPTED["${target}"]="1"
    done <"${EXTRAS_STAGE_LEDGER}"

    # Move each original into the private recovery directory. The move keeps
    # the original inode, so rollback can restore that exact identity. If a
    # target changes before this operation, the helper preserves the new entry
    # and aborts instead of treating it as the original.
    while IFS=$'\t' read -r target source tool; do
        destination="${destination_directory}/${target}"
        original_identity="${expected_original_identities[${target}]:--}"
        backup="${backup_directory}/${target}"
        EXTRAS_DEPLOYMENT_BACKUPS["${target}"]="${backup}"
        EXTRAS_DEPLOYMENT_ORIGINAL_IDENTITIES["${target}"]="${original_identity}"
        # backup-destination moves the original inode without copying it, so
        # the expected backup identity is known before the helper starts. Keep
        # it pre-populated in case a signal interrupts output capture after the
        # move but before the helper's identity report is recorded.
        EXTRAS_DEPLOYMENT_BACKUP_IDENTITIES["${target}"]="${original_identity}"
        if [ "${original_identity}" = "-" ]; then
            had_original=0
        else
            had_original=1
        fi
        EXTRAS_DEPLOYMENT_ORIGINALS["${target}"]="${had_original}"
        # Mark the transaction before the first namespace change. If a signal
        # arrives immediately after the helper moves an entry, rollback still
        # knows which original and staged identities belong to the target.
        EXTRAS_DEPLOYMENT_REPLACED["${target}"]="1"

        backup_result=""
        backup_status=0
        backup_result=$(python3 "${SCRIPT_PATH}/common/runtime-file.py" \
            backup-destination "${destination}" "${backup}" "${original_identity}") ||
            backup_status="${?}"
        if [[ "${backup_result}" == *$'\t'* ]]; then
            backup_original="-"
            backup_identity="-"
            IFS=$'\t' read -r backup_original backup_identity <<<"${backup_result}" ||
                true
            EXTRAS_DEPLOYMENT_ORIGINAL_IDENTITIES["${target}"]="${backup_original}"
            EXTRAS_DEPLOYMENT_BACKUP_IDENTITIES["${target}"]="${backup_identity}"
        fi
        if [ "${backup_status}" -eq 0 ]; then
            backup_identity="${EXTRAS_DEPLOYMENT_BACKUP_IDENTITIES[${target}]:--}"
            if { [ "${had_original}" = "1" ] &&
                [ "${backup_identity}" != "${original_identity}" ]; } ||
                { [ "${had_original}" = "0" ] &&
                    [ "${backup_identity}" != "-" ]; }; then
                printf 'extras: backup identity changed unexpectedly for %s\n' \
                    "${target}" >&2
                backup_status=1
            fi
        fi
        if [ "${backup_status}" -ne 0 ]; then
            printf 'extras: unable to back up existing file: %s\n' "${destination}" >&2
            extras_rollback_deployment || true
            extras_cleanup_deployment_temporaries
            if declare -F runtime_leave_critical_section >/dev/null; then
                runtime_leave_critical_section "extras deployment" extras_rollback_deployment
            fi
            return 1
        fi
    done <"${EXTRAS_STAGE_LEDGER}"

    # Install with RENAME_NOREPLACE. A concurrent replacement that appears
    # after backup makes this operation fail without overwriting that entry.
    while IFS=$'\t' read -r target source tool; do
        destination="${destination_directory}/${target}"
        staged_identity="${EXTRAS_DEPLOYMENT_STAGED_IDENTITIES[${target}]:-}"
        temporary="${EXTRAS_DEPLOYMENT_STAGED_PATHS[${target}]:-}"
        if [ -z "${temporary}" ] || [ -z "${staged_identity}" ]; then
            printf 'extras: staged deployment identity is missing for %s\n' "${target}" >&2
            extras_rollback_deployment || true
            extras_cleanup_deployment_temporaries
            if declare -F runtime_leave_critical_section >/dev/null; then
                runtime_leave_critical_section "extras deployment" extras_rollback_deployment
            fi
            return 1
        fi
        replace_status=0
        python3 "${SCRIPT_PATH}/common/runtime-file.py" replace-destination \
            "${temporary}" "${destination}" "${staged_identity}" || replace_status="${?}"
        if [ "${replace_status}" -ne 0 ]; then
            printf 'extras: unable to deploy executable: %s\n' "${target}" >&2
            extras_rollback_deployment || true
            extras_cleanup_deployment_temporaries
            if declare -F runtime_leave_critical_section >/dev/null; then
                runtime_leave_critical_section "extras deployment" extras_rollback_deployment
            fi
            return 1
        fi
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
