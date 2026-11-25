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

function extras_deployment_entry_exists {
    local deployment_entry_path="${1:-}"

    [ -n "${deployment_entry_path}" ] || return 1
    [ -e "${deployment_entry_path}" ] || [ -L "${deployment_entry_path}" ]
}

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
        # A signal can arrive after the backup helper moved the original but
        # before the wrapper recorded success. In that narrow case the backup
        # file itself is the durable indication that restoration is required.
        if [ "${had_original}" != "1" ] ||
            ! extras_deployment_entry_exists "${backup}"; then
            return 0
        fi
    fi
    if [ -z "${staged_identity}" ]; then
        ui_error "The staged rollback identity is missing for ${target}."
        return 1
    fi
    if [ "${had_original}" = "1" ] &&
        { [ "${original_identity}" = "-" ] || [ "${backup_identity}" = "-" ]; }; then
        ui_error "The rollback identity is missing for ${target}."
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
        if extras_deployment_entry_exists "${backup}"; then
            ui_warning "Rollback skipped for ${target} because the destination or recovery backup changed; the recovery backup remains in ${backup_directory}."
        else
            ui_warning "Rollback skipped for ${target} because the destination or recovery backup changed; no recovery backup was available."
        fi
    elif extras_deployment_entry_exists "${backup}"; then
        ui_error "Could not restore ${target} during rollback; the recovery backup remains in ${backup_directory}."
    else
        ui_error "Could not restore ${target} during rollback; no recovery backup was available."
    fi
    return "${rollback_status}"
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
            ui_error "The rollback backup path is missing for ${target}."
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
        if find "${EXTRAS_DEPLOYMENT_BACKUP_DIRECTORY}" \
            -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
            ui_error "The rollback was incomplete; recovery backups remain in ${EXTRAS_DEPLOYMENT_BACKUP_DIRECTORY}."
        else
            ui_error "The rollback was incomplete; no restorable recovery backup remains in ${EXTRAS_DEPLOYMENT_BACKUP_DIRECTORY}."
        fi
        return 1
    fi

    if ! rm -rf -- "${EXTRAS_DEPLOYMENT_BACKUP_DIRECTORY}"; then
        ui_error "Could not remove the empty rollback backup directory ${EXTRAS_DEPLOYMENT_BACKUP_DIRECTORY}; the restored files are unaffected."
        return 1
    fi

    EXTRAS_DEPLOYMENT_BACKUP_DIRECTORY=""
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
        ui_error "The command-line tool deployment workspace is not initialized."
        return 1
    fi

    if [ ! -s "${EXTRAS_STAGE_LEDGER}" ]; then
        ui_error "No staged commands are ready to deploy."
        return 1
    fi

    if ! mkdir -p "${destination_directory}"; then
        ui_error "Could not create the deployment directory ${destination_directory}."
        return 1
    fi

    # Capture the exact identity of every destination before changing any
    # entry. The backup helper verifies this identity again before moving the
    # original into the recovery directory.
    while IFS=$'\t' read -r target source tool; do
        if ! [[ "${target}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
            ui_error "Invalid deployment target: ${target}."
            return 1
        fi
        if [ ! -f "${source}" ] || [ -L "${source}" ]; then
            ui_error "Invalid staged command for command-line tool ${tool}."
            return 1
        fi
        destination="${destination_directory}/${target}"
        if [ -d "${destination}" ] && [ ! -L "${destination}" ]; then
            ui_error "The deployment target is a directory: ${destination}."
            return 1
        fi
        if [ -f "${destination}" ] && [ ! -L "${destination}" ]; then
            if ! hard_link_count=$(stat -c '%h' -- "${destination}"); then
                ui_error "Could not inspect the deployment target: ${destination}."
                return 1
            fi
            if [ "${hard_link_count}" -ne 1 ]; then
                ui_error "The deployment target has multiple hard links: ${destination}."
                return 1
            fi
        fi
        if { [ -e "${destination}" ] || [ -L "${destination}" ]; } &&
            [ ! -L "${destination}" ] && [ ! -f "${destination}" ]; then
            ui_error "The deployment target is not a regular file: ${destination}."
            return 1
        fi

        if [ -e "${destination}" ] || [ -L "${destination}" ]; then
            if ! original_identity=$(stat -c '%d:%i' -- "${destination}"); then
                ui_error "Could not identify the deployment target: ${destination}."
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
        ui_error "Could not create the rollback backup directory. No commands were replaced."
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
            ui_error "Could not create a temporary file for ${target}. No commands were replaced."
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
            ui_error "Could not stage the deployment file ${target}. No commands were replaced."
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
            ui_error "Could not identify the staged deployment file ${target}. No commands were replaced."
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
                ui_error "The backup identity changed unexpectedly for ${target}."
                backup_status=1
            fi
        fi
        if [ "${backup_status}" -eq 0 ] && [ "${had_original}" = "1" ]; then
            EXTRAS_DEPLOYMENT_REPLACED["${target}"]="1"
        fi
        if [ "${backup_status}" -ne 0 ]; then
            ui_error "Could not back up the existing file: ${destination}."
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
            ui_error "The staged deployment identity is missing for ${target}."
            extras_rollback_deployment || true
            extras_cleanup_deployment_temporaries
            if declare -F runtime_leave_critical_section >/dev/null; then
                runtime_leave_critical_section "extras deployment" extras_rollback_deployment
            fi
            return 1
        fi
        replace_status=0
        # Mark the transaction immediately before the destination namespace
        # can change. For a target without an original, rollback removes the
        # newly installed entry; for a backed-up target, it restores the
        # original by exact identity.
        EXTRAS_DEPLOYMENT_REPLACED["${target}"]="1"
        python3 "${SCRIPT_PATH}/common/runtime-file.py" replace-destination \
            "${temporary}" "${destination}" "${staged_identity}" || replace_status="${?}"
        if [ "${replace_status}" -ne 0 ]; then
            ui_error "Could not deploy the command ${target}."
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
        ui_warning "Could not remove the rollback backups in ${backup_directory}. They remain available for recovery."
    else
        EXTRAS_DEPLOYMENT_BACKUP_DIRECTORY=""
    fi
    return 0
}
