#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

declare -gA RUNTIME_CLEANUP_CALLBACKS=()
declare -ga RUNTIME_CLEANUP_ORDER=()
declare -g RUNTIME_INITIALIZED=0
declare -g RUNTIME_CLEANING=0
declare -g RUNTIME_CLEANED=0
declare -g RUNTIME_CRITICAL_DEPTH=0
declare -g RUNTIME_PENDING_SIGNAL_STATUS=0
declare -g RUNTIME_PENDING_SIGNAL_NAME=""
declare -g RUNTIME_MODULE_ACTIVE_DEPTH=0
declare -g RUNTIME_MODULE_ERROR_COUNT=0
declare -g RUNTIME_MODULE_FIRST_ERROR_STATUS=0
declare -g RUNTIME_MODULE_FIRST_ERROR_COMMAND=""
declare -g RUNTIME_MODULE_FAILURE_STATUS=0
declare -g RUNTIME_MODULE_FAILURE_MODULE=""
declare -g RUNTIME_MODULE_TOTAL=0
declare -g RUNTIME_MODULE_COMPLETED=0
declare -g RUNTIME_MODULE_SKIPPED=0
declare -g RUNTIME_MODULE_FAILED=0
declare -g RUNTIME_MODULE_FAILED_NAME=""
declare -g RUNTIME_OPERATION_FAILED=0
declare -g RUNTIME_MODULE_CURRENT=0
declare -g RUNTIME_START_EPOCH=0
declare -g RUNTIME_SUMMARY_RENDERED=0
declare -g RUNTIME_SUMMARY_PENDING=0
declare -g RUNTIME_SUMMARY_OPERATION=""
declare -g RUNTIME_SUMMARY_TOTAL=0
declare -g RUNTIME_SUMMARY_COMPLETED=0
declare -g RUNTIME_SUMMARY_SKIPPED=0
declare -g RUNTIME_SUMMARY_FAILED=0
declare -g RUNTIME_CLEANUP_FAILURE_STATUS=0
declare -g RUNTIME_OPERATION_LABEL="Operation"
declare -ga RUNTIME_MODULE_ERROR_STACK=()
declare -ga RUNTIME_MODULE_STACK=()
declare -ga RUNTIME_PROFILE_MODULES=()
declare -g RUNTIME_PROFILE_ENABLED=0
declare -g RUNTIME_PROFILE_FILE=""
declare -g RUNTIME_RUN_ID=""
declare -g RUNTIME_LOCK_ACQUIRED=0
declare -g RUNTIME_LOCK_ACQUIRING=0
declare -g RUNTIME_LOCK_HELD=0
declare -g RUNTIME_LOCK_DECISION_FILE=""
declare -g RUNTIME_LOCK_DECISION_STATE="unknown"
declare -g RUNTIME_LOCK_DEVICE=""
declare -g RUNTIME_LOCK_INODE=""
declare -g RUNTIME_LOCK_INSTALLER_PID=""
declare -g RUNTIME_LOCK_INSTALLER_IDENTITY=""
declare -g RUNTIME_LOCK_FILE_FD=""
declare -g RUNTIME_LOCK_SCOPE_FD=""
declare -g RUNTIME_LOCK_OWNER_PID=""
declare -g RUNTIME_LOCK_OWNER_IDENTITY=""
declare -g RUNTIME_LOCK_OWNER_FILE_FD=""
declare -g RUNTIME_LOCK_OWNER_SCOPE_FD=""
declare -g RUNTIME_LOCK_OWNER_STATUS_FILE=""
declare -g RUNTIME_LOCK_SENTINEL_PID=""
declare -g RUNTIME_LOCK_SENTINEL_IDENTITY=""
declare -g RUNTIME_LOCK_SENTINEL_STATUS_FILE=""
declare -g RUNTIME_LOCK_SENTINEL_ACK_FILE=""
declare -g RUNTIME_LOCK_OWNER_RETIREMENT_MARKER_FILE=""
declare -g RUNTIME_LOCK_SENTINEL_ARMED=0
declare -g RUNTIME_LOCK_SUPPORT_TEARDOWN_ACTIVE=0
declare -g RUNTIME_LOCK_OWNER_RETIREMENT_ACK=0
declare -g RUNTIME_LOCK_FILE_IDENTITY=""
declare -g RUNTIME_LOCK_SCOPE_IDENTITY=""
declare -g RUNTIME_LOCK_HOLDER_PID=""
declare -g RUNTIME_LOCK_HOLDER_IDENTITY=""
declare -g RUNTIME_LOCK_WORKER_PID=""
declare -g RUNTIME_LOCK_WORKER_IDENTITY=""
declare -g RUNTIME_LOCK_WATCHDOG_PID=""
declare -g RUNTIME_LOCK_WATCHDOG_IDENTITY=""
declare -g RUNTIME_LOCK_PID=""
declare -g RUNTIME_LOCK_GUARDIAN_IDENTITY=""
declare -g RUNTIME_LOCK_PGID=""
declare -g RUNTIME_LOCK_STATUS_FILE=""
declare -g RUNTIME_LOCK_TEARDOWN_ACTIVE=0
declare -g RUNTIME_PENDING_LOCK_LOSS=0
declare -g RUNTIME_STATE_SCHEMA_VERSION=1

function runtime_is_true {
    case "${1:-}" in
    1 | true | TRUE | yes | YES | on | ON) return 0 ;;
    *) return 1 ;;
    esac
}

function runtime_is_dry_run {
    runtime_is_true "${POSTINSTALL_DRY_RUN:-0}"
}

function runtime_is_resume {
    runtime_is_true "${POSTINSTALL_RESUME:-0}"
}

function runtime_normalize_architecture {
    local runtime_local_value="${1:-}"

    case "${runtime_local_value,,}" in
    x86_64)
        printf '%s\n' "x86_64"
        ;;
    aarch64)
        printf '%s\n' "aarch64"
        ;;
    *)
        return 1
        ;;
    esac
}

function runtime_detect_architecture {
    local runtime_local_machine

    runtime_local_machine=$(uname -m) || return 1
    runtime_normalize_architecture "${runtime_local_machine}"
}

function runtime_selected_architecture {
    local runtime_local_architecture="${POSTINSTALL_ARCHITECTURE:-}"

    if [ -n "${runtime_local_architecture}" ]; then
        runtime_normalize_architecture "${runtime_local_architecture}"
        return $?
    fi
    runtime_detect_architecture
}

function runtime_profile_allows_module {
    local runtime_local_module="${1:-}"
    local runtime_local_selected

    if [ "${RUNTIME_PROFILE_ENABLED}" -ne 1 ]; then
        return 0
    fi
    for runtime_local_selected in "${RUNTIME_PROFILE_MODULES[@]}"; do
        if [ "${runtime_local_selected}" = "${runtime_local_module}" ]; then
            return 0
        fi
    done
    return 1
}

function runtime_module_error_handler {
    local runtime_local_status="${?}"
    local runtime_local_command="${BASH_COMMAND}"

    if [ "${RUNTIME_CLEANING}" -eq 1 ] || [ "${RUNTIME_MODULE_ACTIVE_DEPTH}" -eq 0 ]; then
        return 0
    fi

    # A nested module already reported its own failure. Stop the complete
    # installer immediately; continuing would allow a parent module to mask
    # the child failure with a later successful command.
    if [ "${RUNTIME_MODULE_FAILURE_STATUS}" -ne 0 ]; then
        exit "${RUNTIME_MODULE_FAILURE_STATUS}"
    fi

    # Command substitutions run in a subshell. Their parent command reports the
    # same failure in the main shell, where it can be handled safely.
    if [ "${BASH_SUBSHELL}" -gt 0 ]; then
        return 0
    fi

    RUNTIME_MODULE_ERROR_COUNT=$((RUNTIME_MODULE_ERROR_COUNT + 1))
    if [ "${RUNTIME_MODULE_FIRST_ERROR_STATUS}" -eq 0 ]; then
        RUNTIME_MODULE_FIRST_ERROR_STATUS="${runtime_local_status}"
        RUNTIME_MODULE_FIRST_ERROR_COMMAND="${runtime_local_command}"
    fi
    runtime_log "ERROR" "Command '${runtime_local_command}' failed with status ${runtime_local_status}." \
        "runtime.module.failed"

    # Stop at the first unhandled failure. Continuing would allow later
    # commands to run against a partially completed system state.
    if [ "${#RUNTIME_MODULE_STACK[@]}" -gt 0 ]; then
        runtime_record_module_failure "${runtime_local_status}" \
            "${RUNTIME_MODULE_STACK[${#RUNTIME_MODULE_STACK[@]} - 1]}"
    fi
    exit "${runtime_local_status}"
}

function runtime_module_error_begin {
    local runtime_local_module="${1:-unknown}"

    RUNTIME_MODULE_ERROR_STACK+=("${RUNTIME_MODULE_ERROR_COUNT}")
    RUNTIME_MODULE_STACK+=("${runtime_local_module}")
    RUNTIME_MODULE_ACTIVE_DEPTH=$((RUNTIME_MODULE_ACTIVE_DEPTH + 1))
    return 0
}

function runtime_module_error_end {
    local runtime_local_baseline
    local runtime_local_stack_length

    runtime_local_stack_length="${#RUNTIME_MODULE_ERROR_STACK[@]}"
    if [ "${runtime_local_stack_length}" -gt 0 ]; then
        runtime_local_baseline="${RUNTIME_MODULE_ERROR_STACK[runtime_local_stack_length - 1]}"
        RUNTIME_MODULE_ERROR_STACK=("${RUNTIME_MODULE_ERROR_STACK[@]:0:runtime_local_stack_length-1}")
    else
        runtime_local_baseline="${RUNTIME_MODULE_ERROR_COUNT}"
    fi

    runtime_local_stack_length="${#RUNTIME_MODULE_STACK[@]}"
    if [ "${runtime_local_stack_length}" -gt 0 ]; then
        RUNTIME_MODULE_STACK=("${RUNTIME_MODULE_STACK[@]:0:runtime_local_stack_length-1}")
    fi
    if [ "${RUNTIME_MODULE_ACTIVE_DEPTH}" -gt 0 ]; then
        RUNTIME_MODULE_ACTIVE_DEPTH=$((RUNTIME_MODULE_ACTIVE_DEPTH - 1))
    fi

    if [ "${RUNTIME_MODULE_ERROR_COUNT}" -gt "${runtime_local_baseline}" ]; then
        return "${RUNTIME_MODULE_FIRST_ERROR_STATUS:-1}"
    fi
    return 0
}

function runtime_initialize {
    if [ "${RUNTIME_INITIALIZED}" -eq 1 ]; then
        return 0
    fi

    if [ -z "${SCRIPT_PATH:-}" ]; then
        SCRIPT_PATH=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd -P) || return 1
    fi

    if [ -z "${POSTINSTALL_STATE_FILE:-}" ]; then
        POSTINSTALL_STATE_FILE="${XDG_STATE_HOME:-${HOME}/.local/state}/fedora-postinstall/state.tsv"
    fi

    case "${POSTINSTALL_LOG_FORMAT:-plain}" in
    plain)
        POSTINSTALL_LOG_FORMAT="plain"
        ;;
    json)
        POSTINSTALL_LOG_FORMAT="json"
        ;;
    *)
        printf 'runtime: invalid log format: %s\n' \
            "${POSTINSTALL_LOG_FORMAT}" >&2
        return 1
        ;;
    esac
    case "${POSTINSTALL_LOG_LEVEL:-info}" in
    debug | info | warn | error) ;;
    *)
        printf 'runtime: invalid log level: %s\n' \
            "${POSTINSTALL_LOG_LEVEL}" >&2
        return 1
        ;;
    esac

    if [ -z "${RUNTIME_RUN_ID}" ]; then
        RUNTIME_RUN_ID="$(date -u +'%Y%m%dT%H%M%SZ')-$$-${RANDOM}"
    fi
    RUNTIME_START_EPOCH=$(date +%s) || RUNTIME_START_EPOCH=0
    RUNTIME_INITIALIZED=1
    set -E
    set -o pipefail
    trap 'runtime_module_error_handler' ERR
    trap 'runtime_cleanup' EXIT
    trap 'runtime_handle_signal 130 INT' INT
    trap 'runtime_handle_signal 143 TERM' TERM
    trap 'runtime_handle_signal 129 HUP' HUP
    trap 'runtime_handle_lock_loss 141 lock-loss' USR1
    # Linux has no SIGUSR3; both Bash and Python use SIGRTMIN for the
    # identity-bound owner-loss notification. SIGRTMIN+1 reports support loss.
    trap 'runtime_handle_owner_loss' SIGRTMIN
    trap 'runtime_handle_support_loss' SIGRTMIN+1
    runtime_log "INFO" "Runtime initialized." "runtime.initialized" || return 1
    return 0
}

function runtime_prepare_cache_directory {
    local runtime_local_helper="${SCRIPT_PATH}/common/runtime-file.py"

    if [ -z "${POSTINSTALL_CACHE_DIR:-}" ]; then
        printf 'runtime: cache directory is not configured\n' >&2
        return 73
    fi
    if [ ! -f "${runtime_local_helper}" ] || [ -L "${runtime_local_helper}" ]; then
        printf 'runtime: secure file helper is unavailable\n' >&2
        return 69
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        printf 'runtime: python3 is unavailable\n' >&2
        return 69
    fi
    if ! python3 "${runtime_local_helper}" ensure-directory \
        "${POSTINSTALL_CACHE_DIR}"; then
        printf 'runtime: unable to prepare cache directory: %s\n' \
            "${POSTINSTALL_CACHE_DIR}" >&2
        return 73
    fi
    return 0
}

function runtime_prepare_lock_file {
    local runtime_local_helper="${SCRIPT_PATH}/common/runtime-file.py"

    if [ -z "${POSTINSTALL_LOCK_FILE:-}" ]; then
        printf 'runtime: lock file is not configured\n' >&2
        return 73
    fi
    if [ ! -f "${runtime_local_helper}" ] || [ -L "${runtime_local_helper}" ]; then
        printf 'runtime: secure file helper is unavailable\n' >&2
        return 69
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        printf 'runtime: python3 is unavailable\n' >&2
        return 69
    fi
    if ! python3 "${runtime_local_helper}" create-lock "${POSTINSTALL_LOCK_FILE}"; then
        printf 'runtime: unable to prepare lock file: %s\n' \
            "${POSTINSTALL_LOCK_FILE}" >&2
        return 73
    fi
    return 0
}

function runtime_capture_process_identity {
    local runtime_identity_pid="${1:-}"
    local runtime_identity_boot_id
    local runtime_identity_stat
    local runtime_identity_fields_text
    local runtime_identity_start_time
    local -a runtime_identity_fields=()

    if ! [[ "${runtime_identity_pid}" =~ ^[0-9]+$ ]] ||
        [ "${runtime_identity_pid}" -le 1 ]; then
        return 1
    fi
    if ! IFS= read -r runtime_identity_boot_id \
        <"/proc/sys/kernel/random/boot_id"; then
        return 1
    fi
    if ! IFS= read -r runtime_identity_stat \
        <"/proc/${runtime_identity_pid}/stat"; then
        return 1
    fi

    # The command name in /proc/PID/stat may itself contain spaces or
    # parentheses. The final ") " separates it from field 3 (state); field 22
    # (start time) is therefore index 19 in the remaining field array.
    runtime_identity_fields_text="${runtime_identity_stat##*) }"
    read -r -a runtime_identity_fields <<<"${runtime_identity_fields_text}"
    if [ "${#runtime_identity_fields[@]}" -le 19 ]; then
        return 1
    fi
    if [ "${runtime_identity_fields[0]}" = "Z" ]; then
        return 1
    fi
    runtime_identity_start_time="${runtime_identity_fields[19]}"
    if ! [[ "${runtime_identity_start_time}" =~ ^[0-9]+$ ]] ||
        [ "${runtime_identity_start_time}" -le 0 ]; then
        return 1
    fi

    printf '%s:%s\n' \
        "${runtime_identity_boot_id}" \
        "${runtime_identity_start_time}"
}

function runtime_process_group_id {
    local runtime_group_pid="${1:-}"
    local runtime_group_stat
    local runtime_group_fields_text
    local runtime_group_id
    local -a runtime_group_fields=()

    if ! [[ "${runtime_group_pid}" =~ ^[0-9]+$ ]] ||
        [ "${runtime_group_pid}" -le 1 ]; then
        return 1
    fi
    if ! IFS= read -r runtime_group_stat \
        <"/proc/${runtime_group_pid}/stat"; then
        return 1
    fi

    runtime_group_fields_text="${runtime_group_stat##*) }"
    read -r -a runtime_group_fields <<<"${runtime_group_fields_text}"
    if [ "${#runtime_group_fields[@]}" -le 2 ]; then
        return 1
    fi
    runtime_group_id="${runtime_group_fields[2]}"
    if ! [[ "${runtime_group_id}" =~ ^[0-9]+$ ]] ||
        [ "${runtime_group_id}" -le 1 ]; then
        return 1
    fi
    printf '%s\n' "${runtime_group_id}"
}

function runtime_capture_lock_file_identity {
    local runtime_local_holder="${SCRIPT_PATH}/common/lock-holder.py"
    local runtime_local_lock_path="${POSTINSTALL_LOCK_FILE:-}"
    local runtime_local_identity
    local runtime_local_device
    local runtime_local_inode

    if [ -z "${runtime_local_lock_path}" ] ||
        [ ! -f "${runtime_local_holder}" ] ||
        [ -L "${runtime_local_holder}" ] ||
        ! command -v python3 >/dev/null 2>&1; then
        return 1
    fi
    if ! runtime_local_identity=$(python3 "${runtime_local_holder}" \
        lock-identity "${runtime_local_lock_path}" 2>/dev/null); then
        return 1
    fi
    if ! [[ "${runtime_local_identity}" =~ ^([0-9]+):([0-9]+)$ ]]; then
        return 1
    fi

    runtime_local_device="${BASH_REMATCH[1]}"
    runtime_local_inode="${BASH_REMATCH[2]}"
    RUNTIME_LOCK_DEVICE="${runtime_local_device}"
    RUNTIME_LOCK_INODE="${runtime_local_inode}"
    return 0
}

function runtime_open_lock_scope_descriptor {
    local runtime_local_scope_path="${1:-}"
    local runtime_local_scope_fd
    local runtime_local_descriptor_metadata
    local runtime_local_path_metadata
    local runtime_local_descriptor_device
    local runtime_local_descriptor_inode
    local runtime_local_descriptor_uid
    local runtime_local_descriptor_mode
    local runtime_local_path_device
    local runtime_local_path_inode
    local runtime_local_path_uid
    local runtime_local_path_mode
    local runtime_local_scope_writable=0
    local runtime_local_scope_owner_valid=1

    if [ -z "${runtime_local_scope_path}" ] ||
        [ -L "${runtime_local_scope_path}" ] ||
        [ ! -d "${runtime_local_scope_path}" ]; then
        return 1
    fi
    if ! exec {runtime_local_scope_fd}<"${runtime_local_scope_path}"; then
        return 1
    fi
    if ! runtime_local_descriptor_metadata=$(stat -Lc '%d|%i|%u|%a' \
        "/proc/$$/fd/${runtime_local_scope_fd}" 2>/dev/null); then
        exec {runtime_local_scope_fd}>&- || true
        return 1
    fi
    if ! runtime_local_path_metadata=$(stat -c '%d|%i|%u|%a' \
        "${runtime_local_scope_path}" 2>/dev/null); then
        exec {runtime_local_scope_fd}>&- || true
        return 1
    fi
    IFS='|' read -r runtime_local_descriptor_device \
        runtime_local_descriptor_inode runtime_local_descriptor_uid \
        runtime_local_descriptor_mode <<<"${runtime_local_descriptor_metadata}"
    IFS='|' read -r runtime_local_path_device runtime_local_path_inode \
        runtime_local_path_uid runtime_local_path_mode <<<"${runtime_local_path_metadata}"

    # The secure file helper has already validated every parent component.
    # Recheck the opened descriptor and the final directory entry so a race
    # cannot silently substitute a different scope anchor.
    if ! [[ "${runtime_local_descriptor_mode}" =~ ^[0-7]+$ ]] ||
        ! [[ "${runtime_local_path_mode}" =~ ^[0-7]+$ ]]; then
        exec {runtime_local_scope_fd}>&- || true
        return 1
    fi
    if (((8#${runtime_local_descriptor_mode}) & 022)) ||
        (((8#${runtime_local_path_mode}) & 022)); then
        runtime_local_scope_writable=1
    fi
    if { [ "${runtime_local_descriptor_uid}" != "0" ] &&
        [ "${runtime_local_descriptor_uid}" != "${EUID}" ]; } ||
        { [ "${runtime_local_path_uid}" != "0" ] &&
            [ "${runtime_local_path_uid}" != "${EUID}" ]; }; then
        runtime_local_scope_owner_valid=0
    fi
    if [ "${runtime_local_descriptor_device}" != "${runtime_local_path_device}" ] ||
        [ "${runtime_local_descriptor_inode}" != "${runtime_local_path_inode}" ] ||
        [ "${runtime_local_descriptor_mode}" != "${runtime_local_path_mode}" ] ||
        [ "${runtime_local_scope_owner_valid}" -ne 1 ] ||
        [ "${runtime_local_scope_writable}" -ne 0 ]; then
        exec {runtime_local_scope_fd}>&- || true
        return 1
    fi
    if [ ! -d "/proc/$$/fd/${runtime_local_scope_fd}" ]; then
        exec {runtime_local_scope_fd}>&- || true
        return 1
    fi

    RUNTIME_LOCK_SCOPE_FD="${runtime_local_scope_fd}"
    return 0
}

function runtime_open_lock_file_descriptor {
    local runtime_local_lock_path="${1:-}"
    local runtime_local_expected_device="${2:-}"
    local runtime_local_expected_inode="${3:-}"
    local runtime_local_lock_fd
    local runtime_local_descriptor_metadata
    local runtime_local_path_metadata
    local runtime_local_descriptor_device
    local runtime_local_descriptor_inode
    local runtime_local_descriptor_uid
    local runtime_local_descriptor_links
    local runtime_local_path_device
    local runtime_local_path_inode
    local runtime_local_path_uid
    local runtime_local_path_links

    if [ -z "${runtime_local_lock_path}" ] ||
        [ -L "${runtime_local_lock_path}" ] ||
        [ ! -f "${runtime_local_lock_path}" ] ||
        ! [[ "${runtime_local_expected_device}" =~ ^[0-9]+$ ]] ||
        ! [[ "${runtime_local_expected_inode}" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    if ! exec {runtime_local_lock_fd}<>"${runtime_local_lock_path}"; then
        return 1
    fi
    if ! runtime_local_descriptor_metadata=$(stat -Lc '%d|%i|%u|%h' \
        "/proc/$$/fd/${runtime_local_lock_fd}" 2>/dev/null); then
        exec {runtime_local_lock_fd}>&- || true
        return 1
    fi
    if ! runtime_local_path_metadata=$(stat -c '%d|%i|%u|%h' \
        "${runtime_local_lock_path}" 2>/dev/null); then
        exec {runtime_local_lock_fd}>&- || true
        return 1
    fi
    IFS='|' read -r runtime_local_descriptor_device \
        runtime_local_descriptor_inode runtime_local_descriptor_uid \
        runtime_local_descriptor_links <<<"${runtime_local_descriptor_metadata}"
    IFS='|' read -r runtime_local_path_device runtime_local_path_inode \
        runtime_local_path_uid runtime_local_path_links <<<"${runtime_local_path_metadata}"

    if [ "${runtime_local_descriptor_device}" != "${runtime_local_expected_device}" ] ||
        [ "${runtime_local_descriptor_inode}" != "${runtime_local_expected_inode}" ] ||
        [ "${runtime_local_descriptor_device}" != "${runtime_local_path_device}" ] ||
        [ "${runtime_local_descriptor_inode}" != "${runtime_local_path_inode}" ] ||
        [ "${runtime_local_descriptor_uid}" != "${EUID}" ] ||
        [ "${runtime_local_path_uid}" != "${EUID}" ] ||
        [ "${runtime_local_descriptor_links}" != "1" ] ||
        [ "${runtime_local_path_links}" != "1" ] ||
        [ ! -f "/proc/$$/fd/${runtime_local_lock_fd}" ]; then
        exec {runtime_local_lock_fd}>&- || true
        return 1
    fi

    RUNTIME_LOCK_FILE_FD="${runtime_local_lock_fd}"
    return 0
}

function runtime_close_lock_descriptor {
    local runtime_local_fd="${1:-}"
    local runtime_local_close_fd

    if [ -z "${runtime_local_fd}" ]; then
        return 0
    fi
    if ! [[ "${runtime_local_fd}" =~ ^[0-9]+$ ]] ||
        [ "${runtime_local_fd}" -le 2 ] ||
        [ ! -d "/proc/$$/fd" ]; then
        return 1
    fi
    if [ ! -e "/proc/$$/fd/${runtime_local_fd}" ] &&
        [ ! -L "/proc/$$/fd/${runtime_local_fd}" ]; then
        return 0
    fi

    runtime_local_close_fd="${runtime_local_fd}"
    if ! exec {runtime_local_close_fd}>&-; then
        return 1
    fi
    if [ -e "/proc/$$/fd/${runtime_local_fd}" ] ||
        [ -L "/proc/$$/fd/${runtime_local_fd}" ]; then
        return 1
    fi
    return 0
}

function runtime_retain_validated_lock_status {
    local runtime_local_validation="${1:-}"
    local runtime_local_holder_pid
    local runtime_local_worker_pid
    local runtime_local_watchdog_pid
    local runtime_local_holder_identity
    local runtime_local_worker_identity
    local runtime_local_watchdog_identity
    local runtime_local_guardian_identity

    IFS=' ' read -r runtime_local_holder_pid runtime_local_worker_pid \
        runtime_local_watchdog_pid runtime_local_holder_identity \
        runtime_local_worker_identity runtime_local_watchdog_identity \
        runtime_local_guardian_identity <<<"${runtime_local_validation}"
    if ! [[ "${runtime_local_holder_pid}" =~ ^[0-9]+$ ]] ||
        ! [[ "${runtime_local_worker_pid}" =~ ^[0-9]+$ ]] ||
        ! [[ "${runtime_local_watchdog_pid}" =~ ^[0-9]+$ ]] ||
        ! [[ "${runtime_local_holder_identity}" =~ ^[^:[:space:]]+:[0-9]+$ ]] ||
        ! [[ "${runtime_local_worker_identity}" =~ ^[^:[:space:]]+:[0-9]+$ ]] ||
        ! [[ "${runtime_local_watchdog_identity}" =~ ^[^:[:space:]]+:[0-9]+$ ]] ||
        ! [[ "${runtime_local_guardian_identity}" =~ ^[^:[:space:]]+:[0-9]+$ ]]; then
        return 1
    fi

    # Retain the exact identities that accompanied the successful status
    # validation. A later validation replaces this snapshot so cleanup never
    # binds a numeric PID to a replacement process.
    RUNTIME_LOCK_HOLDER_PID="${runtime_local_holder_pid}"
    RUNTIME_LOCK_WORKER_PID="${runtime_local_worker_pid}"
    RUNTIME_LOCK_WATCHDOG_PID="${runtime_local_watchdog_pid}"
    RUNTIME_LOCK_HOLDER_IDENTITY="${runtime_local_holder_identity}"
    RUNTIME_LOCK_WORKER_IDENTITY="${runtime_local_worker_identity}"
    RUNTIME_LOCK_WATCHDOG_IDENTITY="${runtime_local_watchdog_identity}"
    RUNTIME_LOCK_GUARDIAN_IDENTITY="${runtime_local_guardian_identity}"
    return 0
}

function runtime_update_lock_decision_state {
    local runtime_local_holder="${SCRIPT_PATH}/common/lock-holder.py"
    local runtime_local_decision_file="${1:-}"
    local runtime_local_decision_state

    # The first authoritative winner is latched. A later transient read can
    # never erase a cancellation or commit that has already been observed.
    case "${RUNTIME_LOCK_DECISION_STATE:-unknown}" in
    committed | cancelled)
        return 0
        ;;
    esac
    if [ -z "${runtime_local_decision_file}" ] ||
        [ ! -f "${runtime_local_holder}" ] ||
        [ -L "${runtime_local_holder}" ] ||
        ! command -v python3 >/dev/null 2>&1; then
        return 1
    fi
    if ! runtime_local_decision_state=$(python3 "${runtime_local_holder}" \
        read-decision "${runtime_local_decision_file}" 2>/dev/null); then
        return 1
    fi
    case "${runtime_local_decision_state}" in
    committed | cancelled)
        RUNTIME_LOCK_DECISION_STATE="${runtime_local_decision_state}"
        ;;
    *)
        return 1
        ;;
    esac
    return 0
}

function runtime_claim_lock_cancellation {
    local runtime_local_holder="${SCRIPT_PATH}/common/lock-holder.py"
    local runtime_local_decision_file="${RUNTIME_LOCK_DECISION_FILE:-}"
    local runtime_local_decision_state

    if [ -z "${runtime_local_decision_file}" ] ||
        [ ! -f "${runtime_local_holder}" ] ||
        [ -L "${runtime_local_holder}" ] ||
        ! command -v python3 >/dev/null 2>&1; then
        return 1
    fi

    # Claim cancellation before notifying the guardian. The shared atomic
    # decision path still selects exactly one winner, but publishing first
    # removes the race where a helper failure could be classified before the
    # cancellation becomes authoritative.
    runtime_local_decision_state=$(python3 "${runtime_local_holder}" \
        claim-decision \
        "${runtime_local_decision_file}" \
        cancelled 2>/dev/null || true)
    case "${runtime_local_decision_state}" in
    cancelled)
        RUNTIME_LOCK_DECISION_STATE="cancelled"
        return 0
        ;;
    committed)
        RUNTIME_LOCK_DECISION_STATE="committed"
        return 1
        ;;
    *)
        return 1
        ;;
    esac
}

function runtime_request_lock_cancellation {
    local runtime_local_guardian_pid="${1:-${RUNTIME_LOCK_PID:-}}"
    local runtime_local_guardian_identity="${2:-${RUNTIME_LOCK_GUARDIAN_IDENTITY:-}}"

    # Publish the authoritative cancellation before asking the guardian to
    # stop the supervisor. The guardian and all helper observers therefore see
    # the same winner regardless of which process observes the exit first.
    if ! runtime_claim_lock_cancellation; then
        return 1
    fi

    if [ -n "${runtime_local_guardian_pid}" ] &&
        runtime_background_job_is_known "${runtime_local_guardian_pid}"; then
        runtime_signal_background_job \
            "${runtime_local_guardian_pid}" \
            CONT \
            "${runtime_local_guardian_identity}" || true
        runtime_signal_background_job \
            "${runtime_local_guardian_pid}" \
            USR2 \
            "${runtime_local_guardian_identity}" || true
    fi
    return 0
}

function runtime_process_identity_matches {
    local runtime_identity_pid="${1:-}"
    local runtime_identity_expected="${2:-}"
    local runtime_identity_current

    if [ -z "${runtime_identity_expected}" ]; then
        return 1
    fi
    if ! runtime_identity_current=$(runtime_capture_process_identity \
        "${runtime_identity_pid}"); then
        return 1
    fi
    [ "${runtime_identity_current}" = "${runtime_identity_expected}" ]
}

function runtime_background_job_is_running {
    local runtime_job_pid="${1:-}"
    local runtime_job_entry

    while IFS= read -r runtime_job_entry; do
        if [ "${runtime_job_entry}" = "${runtime_job_pid}" ]; then
            return 0
        fi
    done < <(jobs -pr)
    return 1
}

function runtime_background_job_is_known {
    local runtime_job_pid="${1:-}"
    local runtime_job_entry

    while IFS= read -r runtime_job_entry; do
        if [ "${runtime_job_entry}" = "${runtime_job_pid}" ]; then
            return 0
        fi
    done < <(jobs -p)
    return 1
}

function runtime_background_job_state {
    local runtime_job_pid="${1:-}"
    local runtime_job_expected_identity="${2:-}"
    local runtime_job_current_identity
    local runtime_job_stat
    local runtime_job_fields_text
    local runtime_job_process_state
    local runtime_job_result
    local -a runtime_job_fields=()

    if ! [[ "${runtime_job_pid}" =~ ^[0-9]+$ ]] ||
        [ "${runtime_job_pid}" -le 1 ]; then
        printf 'unknown\n'
        return 0
    fi
    if [ ! -e "/proc/${runtime_job_pid}/stat" ]; then
        printf 'exited\n'
        return 0
    fi
    if ! IFS= read -r runtime_job_stat <"/proc/${runtime_job_pid}/stat"; then
        printf 'unknown\n'
        return 0
    fi

    # The command name in /proc/PID/stat may contain spaces or parentheses.
    # The final ") " separates it from field 3 (state).
    runtime_job_fields_text="${runtime_job_stat##*) }"
    read -r -a runtime_job_fields <<<"${runtime_job_fields_text}"
    if [ "${#runtime_job_fields[@]}" -eq 0 ]; then
        printf 'unknown\n'
        return 0
    fi
    runtime_job_process_state="${runtime_job_fields[0]}"
    case "${runtime_job_process_state}" in
    T | t)
        runtime_job_result="stopped"
        ;;
    Z | z | X | x)
        runtime_job_result="exited"
        ;;
    *)
        runtime_job_result="running"
        ;;
    esac

    if [ -n "${runtime_job_expected_identity}" ] &&
        [ "${runtime_job_result}" != "exited" ]; then
        runtime_job_current_identity=$(runtime_capture_process_identity \
            "${runtime_job_pid}" 2>/dev/null || true)
        if [ -z "${runtime_job_current_identity}" ]; then
            runtime_job_result="unknown"
        elif [ "${runtime_job_current_identity}" != \
            "${runtime_job_expected_identity}" ]; then
            runtime_job_result="replaced"
        fi
    fi
    printf '%s\n' "${runtime_job_result}"
}

function runtime_background_job_is_stopped {
    local runtime_job_pid="${1:-}"
    local runtime_job_expected_identity="${2:-}"
    local runtime_job_state

    runtime_job_state=$(runtime_background_job_state \
        "${runtime_job_pid}" "${runtime_job_expected_identity}")
    [ "${runtime_job_state}" = "stopped" ]
}

function runtime_background_job_finished {
    local runtime_job_pid="${1:-}"
    local runtime_job_expected_identity="${2:-}"
    local runtime_job_state

    runtime_job_state=$(runtime_background_job_state \
        "${runtime_job_pid}" "${runtime_job_expected_identity}")
    case "${runtime_job_state}" in
    exited | replaced)
        return 0
        ;;
    *)
        return 1
        ;;
    esac
}

function runtime_background_job_spec {
    local runtime_job_pid="${1:-}"
    local runtime_job_line
    local runtime_job_spec
    local runtime_job_entry_pid

    while IFS= read -r runtime_job_line; do
        read -r runtime_job_spec runtime_job_entry_pid _ <<<"${runtime_job_line}"
        if [ "${runtime_job_entry_pid}" != "${runtime_job_pid}" ]; then
            continue
        fi
        runtime_job_spec="${runtime_job_spec#\[}"
        runtime_job_spec="${runtime_job_spec%%\]*}"
        runtime_job_spec="${runtime_job_spec#+}"
        runtime_job_spec="${runtime_job_spec%-}"
        if [[ "${runtime_job_spec}" =~ ^[0-9]+$ ]]; then
            printf '%s\n' "${runtime_job_spec}"
            return 0
        fi
    done < <(jobs -l)
    return 1
}

function runtime_signal_unidentified_background_job {
    local runtime_job_pid="${1:-}"
    local runtime_job_signal="${2:-}"
    local runtime_job_spec

    case "${runtime_job_signal}" in
    CONT | HUP | INT | KILL | TERM | USR1 | USR2) ;;
    *) return 1 ;;
    esac
    if ! runtime_job_spec=$(runtime_background_job_spec "${runtime_job_pid}"); then
        return 1
    fi

    # Resolve the target through the shell job table. A completed job has no
    # signalable job specification, so this cannot target a later process
    # that merely reused the numeric PID.
    kill "-${runtime_job_signal}" "%${runtime_job_spec}" 2>/dev/null
}

function runtime_signal_background_job {
    local runtime_job_pid="${1:-}"
    local runtime_job_signal="${2:-}"
    local runtime_job_expected_identity="${3:-}"
    local runtime_job_spec

    # The shell job table selects the target, but the recorded identity is
    # still mandatory. Signaling without it could target a replacement that
    # inherited the numeric PID after the original job exited.
    if [ -z "${runtime_job_expected_identity}" ]; then
        return 1
    fi
    if ! runtime_process_identity_matches \
        "${runtime_job_pid}" "${runtime_job_expected_identity}"; then
        return 1
    fi
    if ! runtime_job_spec=$(runtime_background_job_spec "${runtime_job_pid}"); then
        return 1
    fi
    kill "-${runtime_job_signal}" "%${runtime_job_spec}" 2>/dev/null
}

function runtime_wait_for_background_job {
    local runtime_job_pid="${1:-}"
    local runtime_job_expected_identity="${2:-}"
    local runtime_job_timeout="${3:-0}"
    local runtime_job_started="${SECONDS}"
    local runtime_job_status=0
    local runtime_job_second_status=0
    local runtime_job_state

    if [ -z "${runtime_job_expected_identity}" ]; then
        runtime_job_expected_identity=$(runtime_capture_process_identity \
            "${runtime_job_pid}" 2>/dev/null || true)
    fi

    while :; do
        if [ "${runtime_job_timeout}" -gt 0 ] &&
            [ "$((SECONDS - runtime_job_started))" -ge "${runtime_job_timeout}" ]; then
            return 124
        fi
        if ! runtime_background_job_is_known "${runtime_job_pid}"; then
            # The shell has already collected the job. A direct wait still
            # returns its remembered status and cannot block on a new process
            # that happens to reuse the numeric PID.
            wait "${runtime_job_pid}" 2>/dev/null
            return "${?}"
        fi

        runtime_job_state=$(runtime_background_job_state \
            "${runtime_job_pid}" "${runtime_job_expected_identity}")
        case "${runtime_job_state}" in
        stopped)
            # Bash's wait blocks while a child is stopped. Resume the
            # shell-owned job before polling again; the job specification,
            # rather than a reusable numeric PID, identifies the target.
            runtime_signal_background_job \
                "${runtime_job_pid}" CONT "${runtime_job_expected_identity}" || true
            sleep 0.05 || true
            continue
            ;;
        exited | replaced)
            wait "${runtime_job_pid}" 2>/dev/null
            runtime_job_status="${?}"
            if [ "${runtime_job_status}" -gt 128 ]; then
                # A signal can interrupt the wait after the child has exited.
                # Collect the remembered status once more when the process is
                # still known to have finished.
                runtime_job_state=$(runtime_background_job_state \
                    "${runtime_job_pid}" "${runtime_job_expected_identity}")
                if [ "${runtime_job_state}" = "exited" ] ||
                    [ "${runtime_job_state}" = "replaced" ]; then
                    wait "${runtime_job_pid}" 2>/dev/null
                    runtime_job_second_status="${?}"
                    if [ "${runtime_job_second_status}" -ne 127 ]; then
                        runtime_job_status="${runtime_job_second_status}"
                    fi
                fi
            fi
            return "${runtime_job_status}"
            ;;
        running | unknown)
            sleep 0.05 || true
            ;;
        *)
            sleep 0.05 || true
            ;;
        esac
    done
}

function runtime_validate_lock_support {
    local runtime_local_holder="${SCRIPT_PATH}/common/lock-holder.py"
    local runtime_local_status_file="${1:-}"
    local runtime_local_role="${2:-}"
    local runtime_local_process_id="${3:-}"
    local runtime_local_process_identity="${4:-}"
    local runtime_local_owner_id="${5:-${RUNTIME_LOCK_OWNER_PID:-}}"
    local runtime_local_owner_identity="${6:-${RUNTIME_LOCK_OWNER_IDENTITY:-}}"
    local runtime_local_peer_id
    local runtime_local_peer_identity

    if [ -z "${runtime_local_status_file}" ] ||
        [ -z "${runtime_local_role}" ] ||
        [ -z "${runtime_local_process_id}" ] ||
        [ -z "${runtime_local_process_identity}" ] ||
        [ -z "${runtime_local_owner_id}" ] ||
        [ -z "${runtime_local_owner_identity}" ] ||
        [ -z "${RUNTIME_LOCK_INSTALLER_PID:-}" ] ||
        [ -z "${RUNTIME_LOCK_INSTALLER_IDENTITY:-}" ] ||
        [ -z "${RUNTIME_LOCK_OWNER_FILE_FD:-}" ] ||
        [ -z "${RUNTIME_LOCK_OWNER_SCOPE_FD:-}" ] ||
        [ -z "${RUNTIME_LOCK_FILE_IDENTITY:-}" ] ||
        [ -z "${RUNTIME_LOCK_SCOPE_IDENTITY:-}" ] ||
        [ ! -f "${runtime_local_holder}" ] ||
        [ -L "${runtime_local_holder}" ]; then
        return 1
    fi

    case "${runtime_local_role}" in
    owner)
        runtime_local_peer_id="${RUNTIME_LOCK_SENTINEL_PID:-}"
        runtime_local_peer_identity="${RUNTIME_LOCK_SENTINEL_IDENTITY:-}"
        ;;
    sentinel)
        runtime_local_peer_id="${runtime_local_owner_id}"
        runtime_local_peer_identity="${runtime_local_owner_identity}"
        ;;
    *)
        return 1
        ;;
    esac
    if [ -z "${runtime_local_peer_id}" ] ||
        [ -z "${runtime_local_peer_identity}" ]; then
        return 1
    fi

    # Strict support readiness requires running processes. Resume every
    # distinct support identity through its verified pidfd before validation;
    # the installer itself is never resumed by a helper. A failed resume is a
    # failed readiness check, not a reason to accept a stopped process.
    if ! runtime_resume_lock_helper \
        "${runtime_local_process_id}" "${runtime_local_process_identity}"; then
        return 1
    fi
    if [ "${runtime_local_owner_id}" != "${runtime_local_process_id}" ] &&
        ! runtime_resume_lock_helper \
            "${runtime_local_owner_id}" "${runtime_local_owner_identity}"; then
        return 1
    fi
    if [ "${runtime_local_peer_id}" != "${runtime_local_process_id}" ] &&
        [ "${runtime_local_peer_id}" != "${runtime_local_owner_id}" ] &&
        ! runtime_resume_lock_helper \
            "${runtime_local_peer_id}" "${runtime_local_peer_identity}"; then
        return 1
    fi

    python3 "${runtime_local_holder}" \
        validate-support \
        "${runtime_local_status_file}" \
        "${runtime_local_role}" \
        "${RUNTIME_RUN_ID}" \
        "${runtime_local_process_id}" \
        "${runtime_local_process_identity}" \
        "${runtime_local_owner_id}" \
        "${runtime_local_owner_identity}" \
        "${runtime_local_peer_id}" \
        "${runtime_local_peer_identity}" \
        "${RUNTIME_LOCK_INSTALLER_PID}" \
        "${RUNTIME_LOCK_INSTALLER_IDENTITY}" \
        "${RUNTIME_LOCK_OWNER_FILE_FD}" \
        "${RUNTIME_LOCK_OWNER_SCOPE_FD}" \
        "${RUNTIME_LOCK_FILE_IDENTITY}" \
        "${RUNTIME_LOCK_SCOPE_IDENTITY}" >/dev/null 2>&1
}

function runtime_wait_for_lock_support {
    local runtime_local_status_file="${1:-}"
    local runtime_local_role="${2:-}"
    local runtime_local_process_id="${3:-}"
    local runtime_local_process_identity="${4:-}"
    local runtime_local_attempt

    for ((runtime_local_attempt = 0; runtime_local_attempt < 500; runtime_local_attempt++)); do
        if [ -s "${runtime_local_status_file}" ] &&
            runtime_validate_lock_support \
                "${runtime_local_status_file}" \
                "${runtime_local_role}" \
                "${runtime_local_process_id}" \
                "${runtime_local_process_identity}"; then
            return 0
        fi
        if ! runtime_process_identity_matches \
            "${runtime_local_process_id}" \
            "${runtime_local_process_identity}"; then
            return 1
        fi
        sleep 0.01 || true
    done
    return 1
}

function runtime_start_lock_owner {
    local runtime_local_holder="${SCRIPT_PATH}/common/lock-holder.py"
    local runtime_local_owner_pid=""
    local runtime_local_owner_identity=""
    local runtime_local_attempt

    if [ -z "${RUNTIME_LOCK_INSTALLER_PID:-}" ] ||
        [ -z "${RUNTIME_LOCK_INSTALLER_IDENTITY:-}" ] ||
        [ -z "${RUNTIME_RUN_ID:-}" ] ||
        [ -z "${RUNTIME_LOCK_OWNER_STATUS_FILE:-}" ] ||
        [ -z "${RUNTIME_LOCK_SENTINEL_STATUS_FILE:-}" ] ||
        [ -z "${RUNTIME_LOCK_OWNER_RETIREMENT_MARKER_FILE:-}" ] ||
        [ -z "${RUNTIME_LOCK_FILE_FD:-}" ] ||
        [ -z "${RUNTIME_LOCK_SCOPE_FD:-}" ] ||
        [ -z "${RUNTIME_LOCK_FILE_IDENTITY:-}" ] ||
        [ -z "${RUNTIME_LOCK_SCOPE_IDENTITY:-}" ] ||
        [ ! -f "${runtime_local_holder}" ] ||
        [ -L "${runtime_local_holder}" ]; then
        return 1
    fi

    # The owner receives the already-locked descriptors and monitors both the
    # installer and the sentinel. It reports only sentinel/support loss and
    # never reopens or unlocks the lock paths.
    python3 "${runtime_local_holder}" \
        hold-owner-ready \
        "${RUNTIME_LOCK_INSTALLER_IDENTITY}" \
        "${RUNTIME_LOCK_INSTALLER_PID}" \
        "${RUNTIME_RUN_ID}" \
        "${RUNTIME_LOCK_OWNER_STATUS_FILE}" \
        "${RUNTIME_LOCK_SENTINEL_STATUS_FILE}" \
        "${RUNTIME_LOCK_OWNER_RETIREMENT_MARKER_FILE}" \
        "${RUNTIME_LOCK_FILE_FD}" \
        "${RUNTIME_LOCK_SCOPE_FD}" \
        "${RUNTIME_LOCK_FILE_IDENTITY}" \
        "${RUNTIME_LOCK_SCOPE_IDENTITY}" >/dev/null 2>&1 &
    runtime_local_owner_pid="${!}"

    for ((runtime_local_attempt = 0; runtime_local_attempt < 100; runtime_local_attempt++)); do
        runtime_local_owner_identity=$(runtime_capture_process_identity \
            "${runtime_local_owner_pid}" 2>/dev/null || true)
        if [ -n "${runtime_local_owner_identity}" ]; then
            break
        fi
        sleep 0.01 || true
    done
    if [ -z "${runtime_local_owner_identity}" ]; then
        # The identity could not be established, so a numeric-PID signal
        # could hit a reused PID. Resolve the still-known shell job instead;
        # a completed job has no signalable job specification.
        runtime_signal_unidentified_background_job \
            "${runtime_local_owner_pid}" KILL || true
        runtime_wait_for_background_job \
            "${runtime_local_owner_pid}" "" 1 || true
        return 1
    fi

    RUNTIME_LOCK_OWNER_PID="${runtime_local_owner_pid}"
    RUNTIME_LOCK_OWNER_IDENTITY="${runtime_local_owner_identity}"
    RUNTIME_LOCK_OWNER_FILE_FD="${RUNTIME_LOCK_FILE_FD}"
    RUNTIME_LOCK_OWNER_SCOPE_FD="${RUNTIME_LOCK_SCOPE_FD}"

    return 0
}

function runtime_wait_for_lock_owner {
    if ! runtime_wait_for_lock_support \
        "${RUNTIME_LOCK_OWNER_STATUS_FILE}" \
        owner \
        "${RUNTIME_LOCK_OWNER_PID}" \
        "${RUNTIME_LOCK_OWNER_IDENTITY}"; then
        if ! runtime_terminate_lock_helper \
            "${RUNTIME_LOCK_OWNER_PID}" \
            "${RUNTIME_LOCK_OWNER_IDENTITY}"; then
            return 1
        fi
        wait "${RUNTIME_LOCK_OWNER_PID}" 2>/dev/null || true
        RUNTIME_LOCK_OWNER_PID=""
        RUNTIME_LOCK_OWNER_IDENTITY=""
        return 1
    fi
    return 0
}

function runtime_start_lock_sentinel {
    local runtime_local_holder="${SCRIPT_PATH}/common/lock-holder.py"
    local runtime_local_sentinel_pid=""
    local runtime_local_sentinel_identity=""
    local runtime_local_attempt

    if [ -z "${RUNTIME_LOCK_INSTALLER_PID:-}" ] ||
        [ -z "${RUNTIME_LOCK_INSTALLER_IDENTITY:-}" ] ||
        [ -z "${RUNTIME_LOCK_OWNER_PID:-}" ] ||
        [ -z "${RUNTIME_LOCK_OWNER_IDENTITY:-}" ] ||
        [ -z "${RUNTIME_RUN_ID:-}" ] ||
        [ -z "${RUNTIME_LOCK_SENTINEL_STATUS_FILE:-}" ] ||
        [ -z "${RUNTIME_LOCK_SENTINEL_ACK_FILE:-}" ] ||
        [ -z "${RUNTIME_LOCK_OWNER_RETIREMENT_MARKER_FILE:-}" ] ||
        [ -z "${RUNTIME_LOCK_OWNER_FILE_FD:-}" ] ||
        [ -z "${RUNTIME_LOCK_OWNER_SCOPE_FD:-}" ] ||
        [ -z "${RUNTIME_LOCK_FILE_IDENTITY:-}" ] ||
        [ -z "${RUNTIME_LOCK_SCOPE_IDENTITY:-}" ] ||
        [ ! -f "${runtime_local_holder}" ] ||
        [ -L "${runtime_local_holder}" ]; then
        return 1
    fi

    # The sentinel is independent of the helper group and the owner. It keeps
    # the exact inherited descriptors, watches the owner by identity, and uses
    # a verified pidfd to report unexpected owner loss to the installer.
    python3 "${runtime_local_holder}" \
        lock-sentinel \
        "${RUNTIME_RUN_ID}" \
        "${RUNTIME_LOCK_SENTINEL_STATUS_FILE}" \
        "${RUNTIME_LOCK_SENTINEL_ACK_FILE}" \
        "${RUNTIME_LOCK_OWNER_RETIREMENT_MARKER_FILE}" \
        "${RUNTIME_LOCK_OWNER_IDENTITY}" \
        "${RUNTIME_LOCK_OWNER_PID}" \
        "${RUNTIME_LOCK_INSTALLER_IDENTITY}" \
        "${RUNTIME_LOCK_INSTALLER_PID}" \
        "${RUNTIME_LOCK_OWNER_FILE_FD}" \
        "${RUNTIME_LOCK_OWNER_SCOPE_FD}" \
        "${RUNTIME_LOCK_FILE_IDENTITY}" \
        "${RUNTIME_LOCK_SCOPE_IDENTITY}" >/dev/null 2>&1 &
    runtime_local_sentinel_pid="${!}"

    for ((runtime_local_attempt = 0; runtime_local_attempt < 100; runtime_local_attempt++)); do
        runtime_local_sentinel_identity=$(runtime_capture_process_identity \
            "${runtime_local_sentinel_pid}" 2>/dev/null || true)
        if [ -n "${runtime_local_sentinel_identity}" ]; then
            break
        fi
        sleep 0.01 || true
    done
    if [ -z "${runtime_local_sentinel_identity}" ]; then
        # The identity could not be established, so a numeric-PID signal
        # could hit a reused PID. Resolve the still-known shell job instead;
        # a completed job has no signalable job specification.
        runtime_signal_unidentified_background_job \
            "${runtime_local_sentinel_pid}" KILL || true
        runtime_wait_for_background_job \
            "${runtime_local_sentinel_pid}" "" 1 || true
        return 1
    fi

    RUNTIME_LOCK_SENTINEL_PID="${runtime_local_sentinel_pid}"
    RUNTIME_LOCK_SENTINEL_IDENTITY="${runtime_local_sentinel_identity}"

    if ! runtime_wait_for_lock_support \
        "${RUNTIME_LOCK_SENTINEL_STATUS_FILE}" \
        sentinel \
        "${RUNTIME_LOCK_SENTINEL_PID}" \
        "${RUNTIME_LOCK_SENTINEL_IDENTITY}"; then
        if ! runtime_terminate_lock_helper \
            "${RUNTIME_LOCK_SENTINEL_PID}" \
            "${RUNTIME_LOCK_SENTINEL_IDENTITY}"; then
            RUNTIME_LOCK_SENTINEL_ARMED=1
            return 1
        fi
        wait "${RUNTIME_LOCK_SENTINEL_PID}" 2>/dev/null || true
        RUNTIME_LOCK_SENTINEL_PID=""
        RUNTIME_LOCK_SENTINEL_IDENTITY=""
        return 1
    fi
    RUNTIME_LOCK_SENTINEL_ARMED=1
    return 0
}

function runtime_start_lock_support {
    local runtime_local_file_identity
    local runtime_local_scope_identity

    if [ -z "${RUNTIME_LOCK_FILE_FD:-}" ] ||
        [ -z "${RUNTIME_LOCK_SCOPE_FD:-}" ]; then
        return 1
    fi

    runtime_local_file_identity=$(stat -Lc '%d:%i' \
        "/proc/$$/fd/${RUNTIME_LOCK_FILE_FD}" 2>/dev/null || true)
    runtime_local_scope_identity=$(stat -Lc '%d:%i' \
        "/proc/$$/fd/${RUNTIME_LOCK_SCOPE_FD}" 2>/dev/null || true)
    if [ -z "${runtime_local_file_identity}" ] ||
        [ -z "${runtime_local_scope_identity}" ]; then
        return 1
    fi
    RUNTIME_LOCK_FILE_IDENTITY="${runtime_local_file_identity}"
    RUNTIME_LOCK_SCOPE_IDENTITY="${runtime_local_scope_identity}"

    if ! runtime_start_lock_owner; then
        return 1
    fi
    if ! runtime_start_lock_sentinel; then
        if [ -n "${RUNTIME_LOCK_OWNER_PID:-}" ] &&
            ! runtime_terminate_lock_helper \
                "${RUNTIME_LOCK_OWNER_PID}" \
                "${RUNTIME_LOCK_OWNER_IDENTITY:-}"; then
            return 1
        fi
        if [ -n "${RUNTIME_LOCK_OWNER_PID:-}" ]; then
            wait "${RUNTIME_LOCK_OWNER_PID}" 2>/dev/null || true
        fi
        RUNTIME_LOCK_OWNER_PID=""
        RUNTIME_LOCK_OWNER_IDENTITY=""
        return 1
    fi
    if ! runtime_wait_for_lock_owner; then
        return 1
    fi
    if ! runtime_validate_lock_support \
        "${RUNTIME_LOCK_OWNER_STATUS_FILE}" \
        owner \
        "${RUNTIME_LOCK_OWNER_PID}" \
        "${RUNTIME_LOCK_OWNER_IDENTITY}" ||
        ! runtime_validate_lock_support \
            "${RUNTIME_LOCK_SENTINEL_STATUS_FILE}" \
            sentinel \
            "${RUNTIME_LOCK_SENTINEL_PID}" \
            "${RUNTIME_LOCK_SENTINEL_IDENTITY}"; then
        return 1
    fi

    # The Bash parent closes its copies only after both independent support
    # processes have inherited and validated the exact locked descriptors.
    if ! runtime_close_lock_descriptor "${RUNTIME_LOCK_FILE_FD}"; then
        return 1
    fi
    RUNTIME_LOCK_FILE_FD=""
    if ! runtime_close_lock_descriptor "${RUNTIME_LOCK_SCOPE_FD}"; then
        return 1
    fi
    RUNTIME_LOCK_SCOPE_FD=""

    # Revalidate after the parent closes its copies. This final check includes
    # the owner and sentinel identities and their inherited descriptor
    # identities, so a dead owner cannot be reported as a successful handoff.
    if ! runtime_validate_lock_support \
        "${RUNTIME_LOCK_OWNER_STATUS_FILE}" \
        owner \
        "${RUNTIME_LOCK_OWNER_PID}" \
        "${RUNTIME_LOCK_OWNER_IDENTITY}" ||
        ! runtime_validate_lock_support \
            "${RUNTIME_LOCK_SENTINEL_STATUS_FILE}" \
            sentinel \
            "${RUNTIME_LOCK_SENTINEL_PID}" \
            "${RUNTIME_LOCK_SENTINEL_IDENTITY}"; then
        return 1
    fi
    return 0
}

function runtime_acquire_install_lock {
    local runtime_local_flock
    local runtime_local_holder="${SCRIPT_PATH}/common/lock-holder.py"
    local runtime_local_helper="${SCRIPT_PATH}/common/runtime-file.py"
    local runtime_local_status
    local runtime_local_guardian_identity
    local runtime_local_guardian_pgid
    local runtime_local_installer_pgid
    local runtime_local_monitor_enabled=0
    local runtime_local_lock_scope
    local runtime_local_scope_path
    local runtime_local_scope_status
    local runtime_local_lock_status
    local runtime_local_lock_check_status
    local runtime_local_attempt
    local runtime_local_installer_pid="${BASHPID}"
    local runtime_local_installer_identity
    local runtime_local_validation
    local runtime_local_decision_file
    local runtime_local_decision_state
    local runtime_local_decision_status
    local runtime_local_cancelled=0
    local runtime_local_committed=0

    if [ "${RUNTIME_LOCK_HELD}" -eq 1 ]; then
        return 0
    fi
    RUNTIME_LOCK_ACQUIRED=0
    RUNTIME_LOCK_DECISION_STATE="unknown"
    RUNTIME_LOCK_DEVICE=""
    RUNTIME_LOCK_INODE=""
    RUNTIME_LOCK_OWNER_PID=""
    RUNTIME_LOCK_OWNER_IDENTITY=""
    RUNTIME_LOCK_OWNER_FILE_FD=""
    RUNTIME_LOCK_OWNER_SCOPE_FD=""
    RUNTIME_LOCK_OWNER_STATUS_FILE=""
    RUNTIME_LOCK_SENTINEL_PID=""
    RUNTIME_LOCK_SENTINEL_IDENTITY=""
    RUNTIME_LOCK_SENTINEL_STATUS_FILE=""
    RUNTIME_LOCK_SENTINEL_ACK_FILE=""
    RUNTIME_LOCK_OWNER_RETIREMENT_MARKER_FILE=""
    RUNTIME_LOCK_SENTINEL_ARMED=0
    RUNTIME_LOCK_SUPPORT_TEARDOWN_ACTIVE=0
    RUNTIME_LOCK_OWNER_RETIREMENT_ACK=0
    RUNTIME_LOCK_FILE_IDENTITY=""
    RUNTIME_LOCK_SCOPE_IDENTITY=""
    RUNTIME_LOCK_INSTALLER_PID=""
    RUNTIME_LOCK_INSTALLER_IDENTITY=""
    if [ -n "${RUNTIME_LOCK_FILE_FD:-}" ] ||
        [ -n "${RUNTIME_LOCK_SCOPE_FD:-}" ]; then
        printf 'runtime: installation lock descriptors are already retained\n' >&2
        return 73
    fi
    if ! runtime_local_flock=$(command -v flock 2>/dev/null); then
        printf 'runtime: flock is unavailable\n' >&2
        return 69
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        printf 'runtime: python3 is unavailable\n' >&2
        return 69
    fi
    if [ ! -f "${runtime_local_holder}" ] || [ -L "${runtime_local_holder}" ]; then
        printf 'runtime: lock holder is unavailable\n' >&2
        return 69
    fi
    if [ ! -f "${runtime_local_helper}" ] || [ -L "${runtime_local_helper}" ]; then
        printf 'runtime: secure file helper is unavailable\n' >&2
        return 69
    fi

    # Register the terminal lock cleanup before any helper can start. The
    # root flow also registers it explicitly, but keeping the contract here
    # closes the acquisition window for callers that use the runtime module
    # directly.
    runtime_register_cleanup "install-lock" runtime_release_install_lock || return 1

    # Install the lock-loss handler before starting the guardian. The guardian
    # can detect a helper failure before runtime_initialize installs the
    # process-wide traps.
    trap 'runtime_handle_lock_loss 141 lock-loss' USR1
    trap 'runtime_handle_owner_loss' SIGRTMIN
    trap 'runtime_handle_support_loss' SIGRTMIN+1

    runtime_prepare_cache_directory || return $?
    runtime_prepare_lock_file || return $?

    # Pin the identity of the lock file before any persistent helper starts.
    # Group teardown uses this device/inode pair to distinguish the original
    # descriptor owner from a process that merely inherited the same group ID.
    if ! runtime_capture_lock_file_identity; then
        printf 'runtime: unable to identify the installation lock file\n' >&2
        return 73
    fi

    # The parent shell initially owns both lock domains. The directory scope
    # lock prevents a replaced public pathname from creating a second
    # installer domain, while the public lock-file lock preserves the
    # established per-file behavior. After the helper tree is ready, the
    # descriptors move to a dedicated parent-controlled owner so unrelated
    # descendants cannot inherit and retain them.
    if ! runtime_local_scope_path=$(python3 -c \
        'import os, sys; print(os.path.dirname(os.path.abspath(sys.argv[1])))' \
        "${POSTINSTALL_LOCK_FILE}"); then
        printf 'runtime: unable to identify the installation lock scope\n' >&2
        return 73
    fi
    if ! runtime_open_lock_scope_descriptor "${runtime_local_scope_path}"; then
        printf 'runtime: unable to open the installation lock scope directory\n' >&2
        return 73
    fi
    if ! runtime_open_lock_file_descriptor \
        "${POSTINSTALL_LOCK_FILE}" \
        "${RUNTIME_LOCK_DEVICE}" \
        "${RUNTIME_LOCK_INODE}"; then
        printf 'runtime: unable to open the installation lock file\n' >&2
        runtime_close_lock_descriptor "${RUNTIME_LOCK_SCOPE_FD}" || true
        RUNTIME_LOCK_SCOPE_FD=""
        return 73
    fi

    "${runtime_local_flock}" \
        --exclusive \
        --nonblock \
        --conflict-exit-code 75 \
        "${RUNTIME_LOCK_SCOPE_FD}"
    runtime_local_scope_status="${?}"
    if [ "${runtime_local_scope_status}" -ne 0 ]; then
        runtime_close_lock_descriptor "${RUNTIME_LOCK_FILE_FD}" || true
        RUNTIME_LOCK_FILE_FD=""
        runtime_close_lock_descriptor "${RUNTIME_LOCK_SCOPE_FD}" || true
        RUNTIME_LOCK_SCOPE_FD=""
        if [ "${runtime_local_scope_status}" -eq 75 ]; then
            printf 'runtime: another installer is already running (lock scope: %s)\n' \
                "${runtime_local_scope_path}" >&2
            return 75
        fi
        printf 'runtime: unable to lock the installation lock scope directory\n' >&2
        return 73
    fi

    "${runtime_local_flock}" \
        --exclusive \
        --nonblock \
        --conflict-exit-code 75 \
        "${RUNTIME_LOCK_FILE_FD}"
    runtime_local_lock_status="${?}"
    if [ "${runtime_local_lock_status}" -ne 0 ]; then
        runtime_close_lock_descriptor "${RUNTIME_LOCK_FILE_FD}" || true
        RUNTIME_LOCK_FILE_FD=""
        runtime_close_lock_descriptor "${RUNTIME_LOCK_SCOPE_FD}" || true
        RUNTIME_LOCK_SCOPE_FD=""
        if [ "${runtime_local_lock_status}" -eq 75 ]; then
            printf 'runtime: another installer is already running (lock: %s)\n' \
                "${POSTINSTALL_LOCK_FILE}" >&2
            return 75
        fi
        printf 'runtime: unable to lock the installation lock file\n' >&2
        return 73
    fi
    RUNTIME_LOCK_HELD=1

    if [ -z "${RUNTIME_RUN_ID}" ]; then
        RUNTIME_RUN_ID="$(date -u +'%Y%m%dT%H%M%SZ')-$$-${RANDOM}"
    fi
    runtime_local_lock_scope=$(printf '%s' "${POSTINSTALL_LOCK_FILE}" |
        sha256sum | cut -c '1-16')
    if ! [[ "${runtime_local_lock_scope}" =~ ^[0-9a-f]{16}$ ]]; then
        printf 'runtime: unable to identify the installation lock scope\n' >&2
        return 73
    fi
    RUNTIME_LOCK_STATUS_FILE="${POSTINSTALL_CACHE_DIR}/.postinstall-lock-${runtime_local_lock_scope}-${RUNTIME_RUN_ID}.acquired"
    RUNTIME_LOCK_DECISION_FILE="${POSTINSTALL_CACHE_DIR}/.postinstall-lock-${runtime_local_lock_scope}-${RUNTIME_RUN_ID}.decision"
    RUNTIME_LOCK_OWNER_STATUS_FILE="${POSTINSTALL_CACHE_DIR}/.postinstall-lock-${runtime_local_lock_scope}-${RUNTIME_RUN_ID}.owner"
    RUNTIME_LOCK_SENTINEL_STATUS_FILE="${POSTINSTALL_CACHE_DIR}/.postinstall-lock-${runtime_local_lock_scope}-${RUNTIME_RUN_ID}.sentinel"
    RUNTIME_LOCK_SENTINEL_ACK_FILE="${POSTINSTALL_CACHE_DIR}/.postinstall-lock-${runtime_local_lock_scope}-${RUNTIME_RUN_ID}.sentinel-teardown"
    RUNTIME_LOCK_OWNER_RETIREMENT_MARKER_FILE="${POSTINSTALL_CACHE_DIR}/.postinstall-lock-${runtime_local_lock_scope}-${RUNTIME_RUN_ID}.owner-retiring"
    runtime_local_decision_file="${RUNTIME_LOCK_DECISION_FILE}"
    if ! rm -f -- \
        "${RUNTIME_LOCK_STATUS_FILE}" \
        "${RUNTIME_LOCK_DECISION_FILE}" \
        "${RUNTIME_LOCK_OWNER_STATUS_FILE}" \
        "${RUNTIME_LOCK_SENTINEL_STATUS_FILE}" \
        "${RUNTIME_LOCK_SENTINEL_ACK_FILE}" \
        "${RUNTIME_LOCK_OWNER_RETIREMENT_MARKER_FILE}"; then
        printf 'runtime: unable to prepare lock status file\n' >&2
        return 73
    fi

    # Capture the installer identity before any persistent helper starts. The
    # guardian verifies the same identity independently of the mutable status
    # file and passes it to the Python supervisor.
    if ! runtime_local_installer_identity=$(runtime_capture_process_identity \
        "${runtime_local_installer_pid}"); then
        printf 'runtime: unable to identify the installer process\n' >&2
        return 73
    fi
    RUNTIME_LOCK_INSTALLER_PID="${runtime_local_installer_pid}"
    RUNTIME_LOCK_INSTALLER_IDENTITY="${runtime_local_installer_identity}"

    RUNTIME_LOCK_ACQUIRING=1

    # The installer parent initially owns the already-locked public and scope
    # descriptors. The guardian inherits those exact descriptors and starts
    # a Python supervisor, which starts a worker and watchdog. The guardian
    # must not reopen or flock the public pathname: Python discovers the
    # exact inherited lock inode in the helper process. The guardian ignores
    # installer shutdown signals and detects supervisor exit without
    # consulting the status file. Once acquisition is validated, a dedicated
    # owner receives the same descriptors and the parent closes its copies.
    #
    # Launch the guardian in a dedicated process group. Bash job control is
    # enabled only for the launch and restored immediately afterwards; the
    # guardian disables it again so its supervisor and all descendants stay
    # in the same group. This gives cleanup one complete, identity-checkable
    # target even when a helper is stopped before publishing its status.
    case "$-" in
    *m*) runtime_local_monitor_enabled=1 ;;
    esac
    set -m
    (
        set +m
        umask 077
        trap - EXIT
        trap - ERR
        trap '' HUP TERM INT USR1

        runtime_guardian_cancel_requested=0
        runtime_guardian_abort_requested=0
        runtime_guardian_decision_state=""
        runtime_guardian_supervisor_pid=""
        runtime_guardian_supervisor_identity=""
        runtime_guardian_supervisor_status=0
        # Capture BASHPID in the guardian context. Inside an asynchronous
        # command's expansion, BASHPID would identify the command's child
        # process rather than this guardian.
        runtime_guardian_process_id="${BASHPID}"

        function runtime_guardian_cancel_acquisition {
            local runtime_guardian_claim_state

            runtime_guardian_claim_state=$(python3 "${runtime_local_holder}" \
                claim-decision \
                "${runtime_local_decision_file}" \
                cancelled 2>/dev/null || true)
            runtime_guardian_decision_state="${runtime_guardian_claim_state}"
            case "${runtime_guardian_claim_state}" in
            committed)
                # The installer already won the decision. A later USR2 is
                # intentionally harmless.
                return 0
                ;;
            cancelled)
                runtime_guardian_cancel_requested=1
                ;;
            *)
                # An unreadable or malformed existing decision is unknown,
                # not cancellation. Abort conservatively, but let the Python
                # supervisor classify the failure as a generic decision
                # error rather than a cancellation.
                runtime_guardian_abort_requested=1
                ;;
            esac
            if [ -n "${runtime_guardian_supervisor_pid}" ] &&
                runtime_background_job_is_known \
                    "${runtime_guardian_supervisor_pid}"; then
                # CONT is harmless for a running supervisor and is required
                # before USR2 can be handled by a stopped one. Do not infer
                # the supervisor state from a single sample: a stop can race
                # with that observation.
                runtime_signal_background_job \
                    "${runtime_guardian_supervisor_pid}" CONT \
                    "${runtime_guardian_supervisor_identity}" || true
                runtime_signal_background_job \
                    "${runtime_guardian_supervisor_pid}" USR2 \
                    "${runtime_guardian_supervisor_identity}" || true
            fi
        }
        trap 'runtime_guardian_cancel_acquisition' USR2

        runtime_guardian_installer_identity=$(runtime_capture_process_identity \
            "${runtime_local_installer_pid}") || exit 73
        if [ "${runtime_guardian_installer_identity}" != \
            "${runtime_local_installer_identity}" ]; then
            exit 73
        fi

        python3 \
            "${runtime_local_holder}" \
            hold \
            "${POSTINSTALL_LOCK_FILE}" \
            "${RUNTIME_LOCK_STATUS_FILE}" \
            "${runtime_local_decision_file}" \
            "${runtime_local_installer_pid}" \
            "${runtime_local_installer_identity}" \
            "${runtime_guardian_process_id}" &
        runtime_guardian_supervisor_pid="${!}"
        runtime_guardian_supervisor_identity=$(runtime_capture_process_identity \
            "${runtime_guardian_supervisor_pid}" 2>/dev/null || true)

        if [ "${runtime_guardian_cancel_requested}" -eq 1 ] ||
            [ "${runtime_guardian_abort_requested}" -eq 1 ]; then
            runtime_signal_background_job \
                "${runtime_guardian_supervisor_pid}" USR2 \
                "${runtime_guardian_supervisor_identity}" || true
        fi

        runtime_wait_for_background_job \
            "${runtime_guardian_supervisor_pid}" \
            "${runtime_guardian_supervisor_identity}" ||
            runtime_guardian_supervisor_status="${?}"

        # Supervisor exit is authoritative. The decision file distinguishes a
        # cancelled acquisition from a committed lock whose helpers failed.
        case "${runtime_guardian_decision_state}" in
        committed | cancelled) ;;
        *)
            runtime_guardian_decision_state=$(python3 "${runtime_local_holder}" \
                read-decision "${runtime_local_decision_file}" 2>/dev/null || true)
            ;;
        esac
        if [ "${runtime_guardian_decision_state}" = "cancelled" ]; then
            # The decision is already authoritative. Notify the installer so it
            # can fail acquisition with the cancellation status, then wait for
            # its termination before removing the decision. The USR1 handler
            # distinguishes this case by rereading the decision, so a
            # cancellation cannot be mistaken for a generic lock loss.
            python3 "${runtime_local_holder}" \
                signal-process \
                "${runtime_local_installer_pid}" \
                "${runtime_local_installer_identity}" \
                10 >/dev/null 2>&1 || true
            if ! python3 "${runtime_local_holder}" \
                await-installer \
                "${runtime_guardian_installer_identity}" \
                "${runtime_local_installer_pid}"; then
                printf 'runtime: unable to monitor installer after lock cancellation\n' >&2
                python3 "${runtime_local_holder}" signal-process \
                    "${runtime_local_installer_pid}" \
                    "${runtime_guardian_installer_identity}" \
                    10 >/dev/null 2>&1 || true
                while runtime_process_identity_matches \
                    "${runtime_local_installer_pid}" \
                    "${runtime_guardian_installer_identity}"; do
                    sleep 0.05
                done
            fi
            rm -f -- \
                "${RUNTIME_LOCK_STATUS_FILE}" \
                "${runtime_local_decision_file}" || true
            exit 73
        fi

        # A committed or unknown decision is a lock-loss condition. Notify a
        # live installer and wait through its cleanup before releasing the
        # guardian's descriptor or removing the decision.
        if ! python3 "${runtime_local_holder}" \
            await-installer \
            "${runtime_local_installer_identity}" \
            "${runtime_local_installer_pid}"; then
            printf 'runtime: unable to monitor installer after lock helper failure\n' >&2
            python3 "${runtime_local_holder}" signal-process \
                "${runtime_local_installer_pid}" \
                "${runtime_local_installer_identity}" \
                10 >/dev/null 2>&1 || true
            while runtime_process_identity_matches \
                "${runtime_local_installer_pid}" \
                "${runtime_local_installer_identity}"; do
                sleep 0.05
            done
        fi
        rm -f -- \
            "${RUNTIME_LOCK_STATUS_FILE}" \
            "${runtime_local_decision_file}" || true
        exit "${runtime_guardian_supervisor_status}"
    ) &
    RUNTIME_LOCK_PID="${!}"
    if [ "${runtime_local_monitor_enabled}" -eq 0 ]; then
        set +m
    fi

    runtime_local_guardian_identity=$(runtime_capture_process_identity \
        "${RUNTIME_LOCK_PID}" 2>/dev/null || true)
    RUNTIME_LOCK_GUARDIAN_IDENTITY="${runtime_local_guardian_identity}"
    runtime_local_guardian_pgid=$(runtime_process_group_id \
        "${RUNTIME_LOCK_PID}" 2>/dev/null || true)
    runtime_local_installer_pgid=$(runtime_process_group_id \
        "${runtime_local_installer_pid}" 2>/dev/null || true)
    if [ -z "${runtime_local_installer_pgid}" ] ||
        [ "${runtime_local_guardian_pgid}" != "${RUNTIME_LOCK_PID}" ] ||
        [ "${runtime_local_guardian_pgid}" = "${runtime_local_installer_pgid}" ]; then
        if [ -z "${runtime_local_guardian_pgid}" ] &&
            runtime_background_job_finished \
                "${RUNTIME_LOCK_PID}" "${runtime_local_guardian_identity}"; then
            runtime_local_status=73
            runtime_wait_for_background_job \
                "${RUNTIME_LOCK_PID}" "${runtime_local_guardian_identity}" ||
                runtime_local_status="${?}"
            RUNTIME_LOCK_PID=""
            RUNTIME_LOCK_GUARDIAN_IDENTITY=""
            RUNTIME_LOCK_ACQUIRING=0
            if [ "${runtime_local_status}" -eq 75 ]; then
                printf 'runtime: another installer is already running (lock: %s)\n' \
                    "${POSTINSTALL_LOCK_FILE}" >&2
                return 75
            fi
        else
            printf 'runtime: unable to isolate the installation lock helpers\n' >&2
            runtime_signal_background_job \
                "${RUNTIME_LOCK_PID}" KILL "${runtime_local_guardian_identity}" || true
            runtime_wait_for_background_job \
                "${RUNTIME_LOCK_PID}" "${runtime_local_guardian_identity}" || true
            RUNTIME_LOCK_PID=""
            RUNTIME_LOCK_GUARDIAN_IDENTITY=""
        fi
        RUNTIME_LOCK_ACQUIRING=0
        return 73
    fi
    RUNTIME_LOCK_PGID="${runtime_local_guardian_pgid}"

    for ((runtime_local_attempt = 0; runtime_local_attempt < 100; runtime_local_attempt++)); do
        if [ "${RUNTIME_PENDING_LOCK_LOSS}" -ne 0 ] ||
            [ "${RUNTIME_PENDING_SIGNAL_STATUS}" -ne 0 ]; then
            break
        fi
        if [ -s "${RUNTIME_LOCK_STATUS_FILE}" ]; then
            if ! runtime_local_validation=$(python3 "${runtime_local_holder}" \
                validate-status \
                "${RUNTIME_LOCK_STATUS_FILE}" \
                "${RUNTIME_LOCK_PID}" \
                "${runtime_local_installer_pid}" \
                "${runtime_local_installer_identity}"); then
                break
            fi
            if ! runtime_retain_validated_lock_status \
                "${runtime_local_validation}"; then
                break
            fi

            runtime_local_lock_check_status=0
            if "${runtime_local_flock}" \
                --exclusive \
                --nonblock \
                --conflict-exit-code 75 \
                "${POSTINSTALL_LOCK_FILE}" true; then
                runtime_local_lock_check_status=0
            else
                runtime_local_lock_check_status="${?}"
            fi
            if [ "${runtime_local_lock_check_status}" -ne 75 ]; then
                break
            fi

            # Revalidate after the conflict probe. This closes the startup
            # window in which a helper can die before acquisition is reported
            # as successful.
            sleep 0.05
            if ! runtime_local_validation=$(python3 "${runtime_local_holder}" \
                validate-status \
                "${RUNTIME_LOCK_STATUS_FILE}" \
                "${RUNTIME_LOCK_PID}" \
                "${runtime_local_installer_pid}" \
                "${runtime_local_installer_identity}"); then
                break
            fi
            if ! runtime_retain_validated_lock_status \
                "${runtime_local_validation}"; then
                break
            fi

            # State files from a previously interrupted run are stale once
            # this process owns the exclusive lock.
            if ! python3 "${runtime_local_helper}" prune-lock-state \
                "${POSTINSTALL_CACHE_DIR}" \
                "${runtime_local_lock_scope}" \
                "${RUNTIME_LOCK_STATUS_FILE##*/}" \
                "${RUNTIME_LOCK_DECISION_FILE##*/}"; then
                printf 'runtime: warning: unable to prune stale lock state files\n' >&2
            fi

            # Commit and cancellation publish to the same decision path. Only
            # one atomic publication can win, so a cancellation observed before
            # this claim makes acquisition fail.  The decision is tracked
            # explicitly: a successful rename followed by a failed directory
            # fsync still leaves an authoritative committed decision.
            runtime_local_decision_status=0
            runtime_local_decision_state=$(python3 "${runtime_local_holder}" \
                claim-decision \
                "${RUNTIME_LOCK_DECISION_FILE}" \
                committed) || runtime_local_decision_status="${?}"
            if [ "${runtime_local_decision_state}" = "committed" ]; then
                RUNTIME_LOCK_DECISION_STATE="committed"
                runtime_local_committed=1
            elif [ "${runtime_local_decision_state}" = "cancelled" ]; then
                RUNTIME_LOCK_DECISION_STATE="cancelled"
                runtime_local_cancelled=1
            fi
            if [ "${runtime_local_decision_status}" -ne 0 ]; then
                # The claim command can fail after renameat2() has published
                # the decision (for example, when the directory fsync fails).
                # Read the authoritative entry before deciding which failure
                # path to take.
                runtime_local_decision_state=$(python3 "${runtime_local_holder}" \
                    read-decision "${RUNTIME_LOCK_DECISION_FILE}" 2>/dev/null || true)
                if [ "${runtime_local_decision_state}" = "committed" ]; then
                    RUNTIME_LOCK_DECISION_STATE="committed"
                    runtime_local_committed=1
                    runtime_local_cancelled=0
                elif [ "${runtime_local_decision_state}" = "cancelled" ]; then
                    RUNTIME_LOCK_DECISION_STATE="cancelled"
                    runtime_local_cancelled=1
                    runtime_local_committed=0
                fi
                break
            fi
            if ! runtime_local_validation=$(python3 "${runtime_local_holder}" \
                validate-status \
                "${RUNTIME_LOCK_STATUS_FILE}" \
                "${RUNTIME_LOCK_PID}" \
                "${runtime_local_installer_pid}" \
                "${runtime_local_installer_identity}"); then
                break
            fi
            if ! runtime_retain_validated_lock_status \
                "${runtime_local_validation}"; then
                break
            fi

            if ! runtime_start_lock_support; then
                printf 'runtime: unable to start the installation lock support processes\n' >&2
                break
            fi

            # Revalidate after the owner and sentinel have inherited the exact
            # descriptors and the parent has closed its copies. Support startup
            # is asynchronous, so the preceding validation could otherwise be
            # stale by the time acquisition is reported as successful. This
            # final successful validation also replaces the retained helper
            # identity snapshot used by cleanup.
            if ! runtime_local_validation=$(python3 "${runtime_local_holder}" \
                validate-status \
                "${RUNTIME_LOCK_STATUS_FILE}" \
                "${RUNTIME_LOCK_PID}" \
                "${runtime_local_installer_pid}" \
                "${runtime_local_installer_identity}"); then
                break
            fi
            if ! runtime_retain_validated_lock_status \
                "${runtime_local_validation}"; then
                break
            fi
            if ! runtime_validate_lock_support \
                "${RUNTIME_LOCK_OWNER_STATUS_FILE}" \
                owner \
                "${RUNTIME_LOCK_OWNER_PID}" \
                "${RUNTIME_LOCK_OWNER_IDENTITY}" ||
                ! runtime_validate_lock_support \
                    "${RUNTIME_LOCK_SENTINEL_STATUS_FILE}" \
                    sentinel \
                    "${RUNTIME_LOCK_SENTINEL_PID}" \
                    "${RUNTIME_LOCK_SENTINEL_IDENTITY}"; then
                break
            fi

            RUNTIME_LOCK_ACQUIRING=0
            if [ "${RUNTIME_PENDING_LOCK_LOSS}" -ne 0 ]; then
                break
            fi
            RUNTIME_LOCK_ACQUIRED=1
            RUNTIME_LOCK_HELD=1
            return 0
        fi

        if runtime_background_job_is_stopped \
            "${RUNTIME_LOCK_PID}" "${runtime_local_guardian_identity}"; then
            # A stopped guardian still owns the locked descriptor. Resume the
            # shell-owned job so it can observe helper failure or cancellation.
            runtime_signal_background_job \
                "${RUNTIME_LOCK_PID}" CONT "${runtime_local_guardian_identity}" || true
            sleep 0.05
            continue
        fi
        if ! runtime_background_job_is_known "${RUNTIME_LOCK_PID}" ||
            runtime_background_job_finished \
                "${RUNTIME_LOCK_PID}" "${runtime_local_guardian_identity}"; then
            # The guardian job has completed. Its shell job table, rather than
            # a reusable numeric PID, is the authoritative link.
            break
        fi
        sleep 0.05
    done

    # Re-read the decision after every failed acquisition attempt.  The
    # decision file, rather than the exit status of the publishing helper, is
    # authoritative.  This also handles a published "committed" entry whose
    # directory fsync failed after renameat2() completed.
    case "${RUNTIME_LOCK_DECISION_STATE:-unknown}" in
    committed | cancelled)
        runtime_local_decision_state="${RUNTIME_LOCK_DECISION_STATE}"
        ;;
    *)
        runtime_local_decision_state=$(python3 "${runtime_local_holder}" \
            read-decision "${RUNTIME_LOCK_DECISION_FILE}" 2>/dev/null || true)
        ;;
    esac
    if [ "${runtime_local_decision_state}" = "committed" ]; then
        RUNTIME_LOCK_DECISION_STATE="committed"
        runtime_local_committed=1
        runtime_local_cancelled=0
    else
        # The acquisition is failing before a commit won. Publish the
        # cancellation before requesting guardian cancellation so every
        # observer sees the same authoritative classification. If the decision
        # was already cancelled, the idempotent claim still succeeds and the
        # guardian receives the matching request.
        if runtime_request_lock_cancellation \
            "${RUNTIME_LOCK_PID:-}" \
            "${runtime_local_guardian_identity:-}"; then
            RUNTIME_LOCK_DECISION_STATE="cancelled"
            runtime_local_cancelled=1
            runtime_local_committed=0
        else
            runtime_local_decision_state=$(python3 "${runtime_local_holder}" \
                read-decision "${RUNTIME_LOCK_DECISION_FILE}" 2>/dev/null || true)
            case "${runtime_local_decision_state}" in
            committed)
                RUNTIME_LOCK_DECISION_STATE="committed"
                runtime_local_committed=1
                runtime_local_cancelled=0
                ;;
            cancelled)
                RUNTIME_LOCK_DECISION_STATE="cancelled"
                runtime_local_cancelled=1
                runtime_local_committed=0
                ;;
            esac
        fi
    fi

    if [ "${runtime_local_committed}" -eq 1 ]; then
        # The commit already won.  Do not send USR2 (it is explicitly an
        # acquisition-only cancellation signal) and, most importantly, do not
        # wait for the guardian: the guardian may be waiting for this
        # installer, which would deadlock the acquisition failure path.
        # Resume the guardian unconditionally so a stop that raced the final
        # validation cannot leave it as the final descriptor owner.
        if [ -n "${RUNTIME_LOCK_PID}" ] &&
            runtime_background_job_is_known "${RUNTIME_LOCK_PID}"; then
            runtime_signal_background_job \
                "${RUNTIME_LOCK_PID}" CONT "${runtime_local_guardian_identity}" || true
        fi
        RUNTIME_LOCK_ACQUIRING=0
        if [ "${RUNTIME_INITIALIZED}" -eq 0 ]; then
            runtime_release_install_lock
        fi
        if [ "${RUNTIME_PENDING_SIGNAL_STATUS}" -ne 0 ]; then
            printf 'runtime: lock acquisition interrupted by %s\n' \
                "${RUNTIME_PENDING_SIGNAL_NAME}" >&2
            return "${RUNTIME_PENDING_SIGNAL_STATUS}"
        fi
        printf 'runtime: unable to lock file: %s (lock acquisition failed after commit)\n' \
            "${POSTINSTALL_LOCK_FILE}" >&2
        return 73
    fi

    if [ "${runtime_local_cancelled}" -eq 1 ]; then
        # The guardian keeps the decision and lock until the installer
        # terminates. Do not wait for the guardian here: it waits for this
        # installer, so waiting in both directions would deadlock. The
        # cancellation was claimed and the guardian was notified before this
        # branch was entered.
        RUNTIME_LOCK_ACQUIRING=0
        if [ "${RUNTIME_INITIALIZED}" -eq 0 ]; then
            runtime_release_install_lock
        fi
        # Keep the decision path available to the USR1 trap until this
        # installer terminates. The guardian removes the file only after it
        # observes that termination.
        RUNTIME_PENDING_LOCK_LOSS=1
        runtime_set_pending_signal_status 73 "lock-cancelled"
        printf 'runtime: installation lock acquisition was cancelled\n' >&2
        return 73
    fi

    # A failure before the commit is cancelled rather than allowed to wait
    # for the guardian.  The guardian can be waiting for the installer, and
    # waiting for it here would create the same two-way deadlock.  If the
    # guardian has already exited, collect its status so lock contention can
    # still be reported as status 75. Only an authoritative cancellation is
    # forwarded to the guardian; an unknown decision remains generic.
    if [ -n "${RUNTIME_LOCK_PID}" ] &&
        runtime_background_job_is_known "${RUNTIME_LOCK_PID}"; then
        runtime_signal_background_job \
            "${RUNTIME_LOCK_PID}" CONT "${runtime_local_guardian_identity}" || true
        if [ "${runtime_local_cancelled}" -eq 1 ]; then
            runtime_signal_background_job \
                "${RUNTIME_LOCK_PID}" USR2 "${runtime_local_guardian_identity}" || true
        fi
    fi
    runtime_local_status=73
    if [ -n "${RUNTIME_LOCK_PID}" ] &&
        { ! runtime_background_job_is_known "${RUNTIME_LOCK_PID}" ||
            runtime_background_job_finished \
                "${RUNTIME_LOCK_PID}" "${runtime_local_guardian_identity}"; }; then
        runtime_wait_for_background_job \
            "${RUNTIME_LOCK_PID}" "${runtime_local_guardian_identity}" ||
            runtime_local_status="${?}"
        if [ "${runtime_local_status}" -eq 0 ]; then
            runtime_local_status=73
        fi
    fi
    RUNTIME_LOCK_ACQUIRING=0
    if [ "${RUNTIME_INITIALIZED}" -eq 0 ]; then
        runtime_release_install_lock
    fi
    if [ "${runtime_local_cancelled}" -eq 1 ]; then
        RUNTIME_PENDING_LOCK_LOSS=1
        runtime_set_pending_signal_status 73 "lock-cancelled"
    fi

    if [ "${RUNTIME_PENDING_LOCK_LOSS}" -ne 0 ] &&
        [ "${RUNTIME_PENDING_SIGNAL_STATUS}" -ne 0 ]; then
        runtime_local_status="${RUNTIME_PENDING_SIGNAL_STATUS}"
    elif [ "${RUNTIME_PENDING_SIGNAL_STATUS}" -ne 0 ]; then
        runtime_local_status="${RUNTIME_PENDING_SIGNAL_STATUS}"
    fi
    if [ "${runtime_local_status}" -eq 75 ]; then
        printf 'runtime: another installer is already running (lock: %s)\n' \
            "${POSTINSTALL_LOCK_FILE}" >&2
        return 75
    fi
    if [ "${runtime_local_status}" -ne 73 ]; then
        printf 'runtime: lock acquisition interrupted by %s\n' \
            "${RUNTIME_PENDING_SIGNAL_NAME}" >&2
        return "${runtime_local_status}"
    fi
    printf 'runtime: unable to lock file: %s\n' \
        "${POSTINSTALL_LOCK_FILE}" >&2
    return 73
}

function runtime_resume_lock_helper {
    local runtime_local_pid="${1:-}"
    local runtime_local_identity="${2:-}"
    local runtime_local_holder="${SCRIPT_PATH}/common/lock-holder.py"

    if [ -z "${runtime_local_pid}" ] ||
        [ -z "${runtime_local_identity}" ] ||
        [ ! -f "${runtime_local_holder}" ] ||
        [ -L "${runtime_local_holder}" ]; then
        return 1
    fi
    python3 "${runtime_local_holder}" resume-process \
        "${runtime_local_pid}" "${runtime_local_identity}" >/dev/null 2>&1
}

function runtime_resume_lock_helpers {
    if [ -n "${RUNTIME_LOCK_PID:-}" ]; then
        runtime_signal_background_job \
            "${RUNTIME_LOCK_PID}" CONT "${RUNTIME_LOCK_GUARDIAN_IDENTITY:-}" || true
    fi
    runtime_resume_lock_helper \
        "${RUNTIME_LOCK_HOLDER_PID:-}" "${RUNTIME_LOCK_HOLDER_IDENTITY:-}"
    runtime_resume_lock_helper \
        "${RUNTIME_LOCK_WORKER_PID:-}" "${RUNTIME_LOCK_WORKER_IDENTITY:-}"
    runtime_resume_lock_helper \
        "${RUNTIME_LOCK_WATCHDOG_PID:-}" "${RUNTIME_LOCK_WATCHDOG_IDENTITY:-}"
    runtime_resume_lock_helper \
        "${RUNTIME_LOCK_OWNER_PID:-}" "${RUNTIME_LOCK_OWNER_IDENTITY:-}"
    runtime_resume_lock_helper \
        "${RUNTIME_LOCK_SENTINEL_PID:-}" "${RUNTIME_LOCK_SENTINEL_IDENTITY:-}"
}

function runtime_signal_lock_helper {
    local runtime_local_pid="${1:-}"
    local runtime_local_identity="${2:-}"
    local runtime_local_signal_number="${3:-}"
    local runtime_local_holder="${SCRIPT_PATH}/common/lock-holder.py"

    if [ -z "${runtime_local_pid}" ] ||
        [ -z "${runtime_local_identity}" ] ||
        ! [[ "${runtime_local_pid}" =~ ^[0-9]+$ ]] ||
        [ "${runtime_local_pid}" -le 1 ] ||
        [ "${runtime_local_pid}" = "${BASHPID}" ] ||
        ! [[ "${runtime_local_signal_number}" =~ ^[0-9]+$ ]] ||
        [ "${runtime_local_signal_number}" -le 0 ] ||
        [ ! -f "${runtime_local_holder}" ] ||
        [ -L "${runtime_local_holder}" ]; then
        return 1
    fi

    python3 "${runtime_local_holder}" \
        signal-process \
        "${runtime_local_pid}" \
        "${runtime_local_identity}" \
        "${runtime_local_signal_number}" >/dev/null 2>&1
}

function runtime_terminate_lock_helper {
    local runtime_local_pid="${1:-}"
    local runtime_local_identity="${2:-}"
    local runtime_local_mode="${3:-}"
    local runtime_local_holder="${SCRIPT_PATH}/common/lock-holder.py"
    local runtime_local_command="terminate-process"

    if [ -z "${runtime_local_pid}" ] && [ -z "${runtime_local_identity}" ]; then
        return 0
    fi
    if [ -z "${runtime_local_pid}" ] ||
        [ -z "${runtime_local_identity}" ] ||
        ! [[ "${runtime_local_pid}" =~ ^[0-9]+$ ]] ||
        [ "${runtime_local_pid}" -le 1 ] ||
        [ "${runtime_local_pid}" = "${BASHPID}" ] ||
        [ ! -f "${runtime_local_holder}" ] ||
        [ -L "${runtime_local_holder}" ]; then
        return 1
    fi
    if [ "${runtime_local_mode}" = "required" ]; then
        runtime_local_command="terminate-process-required"
    fi
    python3 "${runtime_local_holder}" "${runtime_local_command}" \
        "${runtime_local_pid}" "${runtime_local_identity}" >/dev/null 2>&1
}

function runtime_terminate_lock_group {
    local runtime_local_holder="${SCRIPT_PATH}/common/lock-holder.py"
    local runtime_local_pgid="${RUNTIME_LOCK_PGID:-}"
    local runtime_local_identity="${RUNTIME_LOCK_GUARDIAN_IDENTITY:-}"
    local runtime_local_device="${RUNTIME_LOCK_DEVICE:-}"
    local runtime_local_inode="${RUNTIME_LOCK_INODE:-}"

    if ! [[ "${runtime_local_pgid}" =~ ^[0-9]+$ ]] ||
        [ "${runtime_local_pgid}" -le 1 ] ||
        [ -z "${runtime_local_identity}" ] ||
        [ ! -f "${runtime_local_holder}" ] ||
        [ -L "${runtime_local_holder}" ]; then
        return 1
    fi

    if [ -z "${runtime_local_device}" ] ||
        [ -z "${runtime_local_inode}" ] ||
        ! [[ "${runtime_local_device}" =~ ^[0-9]+$ ]] ||
        ! [[ "${runtime_local_inode}" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    python3 "${runtime_local_holder}" terminate-group \
        "${runtime_local_pgid}" \
        "${runtime_local_identity}" \
        "${runtime_local_device}" \
        "${runtime_local_inode}" >/dev/null 2>&1
}

function runtime_verify_lock_group_empty {
    local runtime_local_holder="${SCRIPT_PATH}/common/lock-holder.py"
    local runtime_local_pgid="${RUNTIME_LOCK_PGID:-}"

    if ! [[ "${runtime_local_pgid}" =~ ^[0-9]+$ ]] ||
        [ "${runtime_local_pgid}" -le 1 ] ||
        [ ! -f "${runtime_local_holder}" ] ||
        [ -L "${runtime_local_holder}" ]; then
        return 1
    fi
    python3 "${runtime_local_holder}" verify-group-empty \
        "${runtime_local_pgid}" >/dev/null 2>&1
}

function runtime_force_release_install_lock {
    local runtime_local_status=0
    local runtime_local_wait_status=0

    # Give stopped helpers a chance to observe installer termination, then
    # enforce the release invariant. SIGKILL is required because SIGCONT can
    # fail or race with another SIGSTOP.
    runtime_resume_lock_helpers

    # A failed group termination is not final by itself: the identity-bound
    # helper terminations and the mandatory empty-group verification below can
    # still establish that no descriptor owner remains.
    runtime_terminate_lock_group || true

    # These terminations are unconditional. The group operation may already
    # have removed a helper, in which case the Python helper confirms that
    # the recorded identity is gone rather than signaling a reused PID.
    runtime_terminate_lock_helper \
        "${RUNTIME_LOCK_WORKER_PID:-}" "${RUNTIME_LOCK_WORKER_IDENTITY:-}" ||
        runtime_local_status=1
    runtime_terminate_lock_helper \
        "${RUNTIME_LOCK_WATCHDOG_PID:-}" "${RUNTIME_LOCK_WATCHDOG_IDENTITY:-}" ||
        runtime_local_status=1
    runtime_terminate_lock_helper \
        "${RUNTIME_LOCK_HOLDER_PID:-}" "${RUNTIME_LOCK_HOLDER_IDENTITY:-}" ||
        runtime_local_status=1

    if [ -n "${RUNTIME_LOCK_PID:-}" ]; then
        if runtime_background_job_is_known "${RUNTIME_LOCK_PID}"; then
            if ! runtime_signal_background_job \
                "${RUNTIME_LOCK_PID}" KILL "${RUNTIME_LOCK_GUARDIAN_IDENTITY:-}"; then
                if ! runtime_background_job_finished \
                    "${RUNTIME_LOCK_PID}" "${RUNTIME_LOCK_GUARDIAN_IDENTITY:-}"; then
                    runtime_local_status=1
                fi
            fi
            runtime_local_wait_status=0
            runtime_wait_for_background_job \
                "${RUNTIME_LOCK_PID}" "${RUNTIME_LOCK_GUARDIAN_IDENTITY:-}" 5 ||
                runtime_local_wait_status="${?}"
            if [ "${runtime_local_wait_status}" -eq 124 ]; then
                runtime_local_status=1
            fi
        elif ! runtime_background_job_finished \
            "${RUNTIME_LOCK_PID}" "${RUNTIME_LOCK_GUARDIAN_IDENTITY:-}"; then
            runtime_local_status=1
        fi
    fi

    # Never claim release from the helper terminations alone. An empty group is
    # required to rule out an unknown or reparented descriptor owner.
    if ! runtime_verify_lock_group_empty; then
        runtime_local_status=1
    fi

    return "${runtime_local_status}"
}

function runtime_validate_lock_retirement_marker {
    local runtime_local_marker_file="${1:-}"
    local runtime_local_holder="${SCRIPT_PATH}/common/lock-holder.py"

    if [ -z "${runtime_local_marker_file}" ] ||
        [ ! -s "${runtime_local_marker_file}" ] ||
        [ -z "${RUNTIME_RUN_ID:-}" ] ||
        [ -z "${RUNTIME_LOCK_OWNER_PID:-}" ] ||
        [ -z "${RUNTIME_LOCK_OWNER_IDENTITY:-}" ] ||
        [ -z "${RUNTIME_LOCK_SENTINEL_PID:-}" ] ||
        [ -z "${RUNTIME_LOCK_SENTINEL_IDENTITY:-}" ] ||
        [ -z "${RUNTIME_LOCK_INSTALLER_PID:-}" ] ||
        [ -z "${RUNTIME_LOCK_INSTALLER_IDENTITY:-}" ] ||
        [ ! -f "${runtime_local_holder}" ] ||
        [ -L "${runtime_local_holder}" ]; then
        return 1
    fi

    python3 "${runtime_local_holder}" \
        validate-owner-retirement-marker \
        "${runtime_local_marker_file}" \
        "${RUNTIME_RUN_ID}" \
        "${RUNTIME_LOCK_OWNER_PID}" \
        "${RUNTIME_LOCK_OWNER_IDENTITY}" \
        "${RUNTIME_LOCK_SENTINEL_PID}" \
        "${RUNTIME_LOCK_SENTINEL_IDENTITY}" \
        "${RUNTIME_LOCK_INSTALLER_PID}" \
        "${RUNTIME_LOCK_INSTALLER_IDENTITY}" >/dev/null 2>&1
}

function runtime_validate_lock_retirement_ack {
    local runtime_local_ack_file="${1:-}"
    local runtime_local_marker_file="${2:-}"
    local runtime_local_holder="${SCRIPT_PATH}/common/lock-holder.py"

    if [ -z "${runtime_local_ack_file}" ] ||
        [ ! -s "${runtime_local_ack_file}" ] ||
        [ -z "${runtime_local_marker_file}" ] ||
        [ ! -s "${runtime_local_marker_file}" ] ||
        [ -z "${RUNTIME_RUN_ID:-}" ] ||
        [ -z "${RUNTIME_LOCK_OWNER_PID:-}" ] ||
        [ -z "${RUNTIME_LOCK_OWNER_IDENTITY:-}" ] ||
        [ -z "${RUNTIME_LOCK_SENTINEL_PID:-}" ] ||
        [ -z "${RUNTIME_LOCK_SENTINEL_IDENTITY:-}" ] ||
        [ -z "${RUNTIME_LOCK_INSTALLER_PID:-}" ] ||
        [ -z "${RUNTIME_LOCK_INSTALLER_IDENTITY:-}" ] ||
        [ ! -f "${runtime_local_holder}" ] ||
        [ -L "${runtime_local_holder}" ]; then
        return 1
    fi

    python3 "${runtime_local_holder}" \
        validate-owner-retirement \
        "${runtime_local_ack_file}" \
        "${runtime_local_marker_file}" \
        "${RUNTIME_RUN_ID}" \
        "${RUNTIME_LOCK_OWNER_PID}" \
        "${RUNTIME_LOCK_OWNER_IDENTITY}" \
        "${RUNTIME_LOCK_SENTINEL_PID}" \
        "${RUNTIME_LOCK_SENTINEL_IDENTITY}" \
        "${RUNTIME_LOCK_INSTALLER_PID}" \
        "${RUNTIME_LOCK_INSTALLER_IDENTITY}" >/dev/null 2>&1
}

function runtime_retire_lock_owner_directly {
    local runtime_local_status

    if [ -z "${RUNTIME_LOCK_OWNER_PID:-}" ]; then
        return 0
    fi

    runtime_terminate_lock_helper \
        "${RUNTIME_LOCK_OWNER_PID}" \
        "${RUNTIME_LOCK_OWNER_IDENTITY:-}" \
        required
    runtime_local_status="${?}"
    if [ "${runtime_local_status}" -eq 0 ]; then
        wait "${RUNTIME_LOCK_OWNER_PID}" 2>/dev/null || true
        return 0
    fi
    if [ "${runtime_local_status}" -eq 75 ]; then
        wait "${RUNTIME_LOCK_OWNER_PID}" 2>/dev/null || true
        if runtime_validate_lock_retirement_marker \
            "${RUNTIME_LOCK_OWNER_RETIREMENT_MARKER_FILE:-}"; then
            RUNTIME_LOCK_OWNER_RETIREMENT_ACK=1
        else
            runtime_record_lock_retirement_loss "owner-loss"
        fi
        return 0
    fi
    return 1
}

function runtime_record_lock_retirement_loss {
    local runtime_local_loss_name="${1:-support-loss}"

    # Once intentional support teardown has begun, an already-removed support
    # peer is expected. A genuine owner loss remains security-specific even
    # when it is discovered after the sentinel has been intentionally removed.
    if [ "${RUNTIME_LOCK_SUPPORT_TEARDOWN_ACTIVE}" -eq 1 ] &&
        [ "${runtime_local_loss_name}" != "owner-loss" ]; then
        return 0
    fi

    RUNTIME_PENDING_LOCK_LOSS=1
    if [ "${RUNTIME_LOCK_ACQUIRED}" -ne 1 ]; then
        runtime_set_pending_signal_status 73 "lock-acquisition-failed"
    else
        runtime_set_pending_signal_status 141 "${runtime_local_loss_name}"
    fi
}

function runtime_retire_lock_owner {
    local runtime_local_attempt

    if [ "${RUNTIME_LOCK_OWNER_RETIREMENT_ACK}" -eq 1 ]; then
        return 0
    fi

    if [ "${RUNTIME_LOCK_SENTINEL_ARMED}" -ne 1 ] ||
        [ -z "${RUNTIME_LOCK_SENTINEL_PID:-}" ] ||
        [ -z "${RUNTIME_LOCK_SENTINEL_IDENTITY:-}" ]; then
        # No sentinel was armed, so the parent can safely retire the owner
        # directly without bypassing an owner-loss observer.
        runtime_retire_lock_owner_directly
        return "${?}"
    fi

    # Distinguish an already-dead support identity from a stopped one before
    # attempting a resume. A dead sentinel leaves the owner as the final
    # descriptor holder, so the verified direct-retirement fallback remains
    # safe. A dead owner leaves the sentinel as the final holder.
    if ! runtime_process_identity_matches \
        "${RUNTIME_LOCK_SENTINEL_PID}" \
        "${RUNTIME_LOCK_SENTINEL_IDENTITY}"; then
        runtime_record_lock_retirement_loss "support-loss"
        printf 'runtime: installation lock sentinel failed before owner retirement\n' >&2
        # The sentinel is already gone, so the owner is the final descriptor
        # holder. Retire it directly through its verified pidfd instead of
        # waiting for an acknowledgement that can no longer be published.
        runtime_retire_lock_owner_directly
        return "${?}"
    fi

    if ! runtime_process_identity_matches \
        "${RUNTIME_LOCK_OWNER_PID}" \
        "${RUNTIME_LOCK_OWNER_IDENTITY}"; then
        if runtime_validate_lock_retirement_marker \
            "${RUNTIME_LOCK_OWNER_RETIREMENT_MARKER_FILE:-}"; then
            RUNTIME_LOCK_OWNER_RETIREMENT_ACK=1
            wait "${RUNTIME_LOCK_OWNER_PID}" 2>/dev/null || true
            return 0
        fi
        runtime_record_lock_retirement_loss "owner-loss"
        printf 'runtime: installation lock owner failed before retirement\n' >&2
        # The sentinel is now the final descriptor holder. Cleanup can retire
        # it directly, but the unexpected owner loss remains security-specific.
        return 0
    fi

    # A stopped support process cannot handle the retirement request. Resume
    # both identities through verified pidfds and require a fresh running-state
    # observation before asking the sentinel to retire the owner. A failed
    # resume aborts the handshake instead of treating a stopped helper as
    # ready to retire its peer.
    if ! runtime_resume_lock_helper \
        "${RUNTIME_LOCK_OWNER_PID}" "${RUNTIME_LOCK_OWNER_IDENTITY}"; then
        runtime_record_lock_retirement_loss "owner-loss"
        printf 'runtime: installation lock owner failed before retirement\n' >&2
        return 1
    fi
    if ! runtime_resume_lock_helper \
        "${RUNTIME_LOCK_SENTINEL_PID}" "${RUNTIME_LOCK_SENTINEL_IDENTITY}"; then
        runtime_record_lock_retirement_loss "support-loss"
        printf 'runtime: installation lock sentinel failed before retirement\n' >&2
        return 1
    fi
    if ! runtime_signal_lock_helper \
        "${RUNTIME_LOCK_SENTINEL_PID}" \
        "${RUNTIME_LOCK_SENTINEL_IDENTITY}" \
        12; then
        runtime_record_lock_retirement_loss "support-loss"
        printf 'runtime: unable to request installation lock owner retirement\n' >&2
        return 1
    fi

    for ((runtime_local_attempt = 0; runtime_local_attempt < 300; runtime_local_attempt++)); do
        if [ -s "${RUNTIME_LOCK_SENTINEL_ACK_FILE:-}" ]; then
            if runtime_validate_lock_retirement_ack \
                "${RUNTIME_LOCK_SENTINEL_ACK_FILE}" \
                "${RUNTIME_LOCK_OWNER_RETIREMENT_MARKER_FILE:-}"; then
                if runtime_process_identity_matches \
                    "${RUNTIME_LOCK_OWNER_PID}" \
                    "${RUNTIME_LOCK_OWNER_IDENTITY}"; then
                    sleep 0.01 || true
                    continue
                fi
                RUNTIME_LOCK_OWNER_RETIREMENT_ACK=1
                wait "${RUNTIME_LOCK_OWNER_PID}" 2>/dev/null || true
                return 0
            fi
        fi
        if ! runtime_process_identity_matches \
            "${RUNTIME_LOCK_SENTINEL_PID}" \
            "${RUNTIME_LOCK_SENTINEL_IDENTITY}"; then
            runtime_record_lock_retirement_loss "support-loss"
            printf 'runtime: installation lock sentinel failed during owner retirement\n' >&2
            # The sentinel is gone, so the owner is the final descriptor
            # holder. Terminate it through its verified pidfd and retain the
            # support-loss status.
            runtime_retire_lock_owner_directly
            return "${?}"
        fi
        if ((runtime_local_attempt % 25 == 0)); then
            # The owner is expected to exit after authenticating the request,
            # so it must not be required to remain running while the sentinel
            # publishes the acknowledgement. The sentinel owns the request
            # transaction and resumes the owner before delivery; only the
            # sentinel itself must remain live throughout this wait.
            if ! runtime_resume_lock_helper \
                "${RUNTIME_LOCK_SENTINEL_PID}" "${RUNTIME_LOCK_SENTINEL_IDENTITY}"; then
                runtime_record_lock_retirement_loss "support-loss"
                printf 'runtime: installation lock sentinel failed during owner retirement\n' >&2
                return 1
            fi
        fi
        sleep 0.01 || true
    done

    # The explicit request was delivered but no acknowledgement arrived. Use
    # a fail-safe fallback that terminates the sentinel first, while the owner
    # still retains the exact descriptors, and then retires the owner. The
    # sentinel cannot report an unexpected owner death after it is gone, so
    # this fallback cannot suppress a genuine owner-loss notification.
    if ! runtime_process_identity_matches \
        "${RUNTIME_LOCK_SENTINEL_PID}" \
        "${RUNTIME_LOCK_SENTINEL_IDENTITY}"; then
        runtime_record_lock_retirement_loss "support-loss"
        printf 'runtime: installation lock sentinel failed during owner retirement\n' >&2
        runtime_retire_lock_owner_directly
        return "${?}"
    fi
    if ! runtime_process_identity_matches \
        "${RUNTIME_LOCK_OWNER_PID}" \
        "${RUNTIME_LOCK_OWNER_IDENTITY}"; then
        if runtime_validate_lock_retirement_marker \
            "${RUNTIME_LOCK_OWNER_RETIREMENT_MARKER_FILE:-}"; then
            RUNTIME_LOCK_OWNER_RETIREMENT_ACK=1
            wait "${RUNTIME_LOCK_OWNER_PID}" 2>/dev/null || true
            return 0
        fi
        runtime_record_lock_retirement_loss "owner-loss"
        printf 'runtime: installation lock owner failed before retirement\n' >&2
        return 0
    fi
    if ! runtime_resume_lock_helper \
        "${RUNTIME_LOCK_OWNER_PID}" "${RUNTIME_LOCK_OWNER_IDENTITY}"; then
        runtime_record_lock_retirement_loss "owner-loss"
        printf 'runtime: installation lock owner failed before retirement\n' >&2
        return 1
    fi
    if ! runtime_resume_lock_helper \
        "${RUNTIME_LOCK_SENTINEL_PID}" "${RUNTIME_LOCK_SENTINEL_IDENTITY}"; then
        runtime_record_lock_retirement_loss "support-loss"
        printf 'runtime: installation lock sentinel failed before retirement\n' >&2
        return 1
    fi

    # From this point the sentinel is intentionally being removed before the
    # owner. The owner will observe that support loss and report it to the
    # installer; mark the teardown before the signal so the notification is
    # classified as expected cleanup rather than a new terminal loss.
    RUNTIME_LOCK_SUPPORT_TEARDOWN_ACTIVE=1
    if ! runtime_terminate_lock_helper \
        "${RUNTIME_LOCK_SENTINEL_PID}" \
        "${RUNTIME_LOCK_SENTINEL_IDENTITY}"; then
        printf 'runtime: unable to terminate the installation lock sentinel after the retirement timeout\n' >&2
        return 1
    fi
    wait "${RUNTIME_LOCK_SENTINEL_PID}" 2>/dev/null || true
    RUNTIME_LOCK_SENTINEL_ARMED=0
    if ! runtime_retire_lock_owner_directly; then
        printf 'runtime: unable to retire the installation lock owner after the sentinel timeout\n' >&2
        return 1
    fi
    return 0
}

function runtime_verify_lock_sentinel {
    local runtime_local_file_identity
    local runtime_local_scope_identity

    if [ "${RUNTIME_LOCK_SENTINEL_ARMED}" -ne 1 ] ||
        [ -z "${RUNTIME_LOCK_SENTINEL_PID:-}" ] ||
        [ -z "${RUNTIME_LOCK_SENTINEL_IDENTITY:-}" ] ||
        [ -z "${RUNTIME_LOCK_OWNER_FILE_FD:-}" ] ||
        [ -z "${RUNTIME_LOCK_OWNER_SCOPE_FD:-}" ] ||
        [ -z "${RUNTIME_LOCK_FILE_IDENTITY:-}" ] ||
        [ -z "${RUNTIME_LOCK_SCOPE_IDENTITY:-}" ]; then
        return 1
    fi
    if ! runtime_process_identity_matches \
        "${RUNTIME_LOCK_SENTINEL_PID}" \
        "${RUNTIME_LOCK_SENTINEL_IDENTITY}"; then
        return 1
    fi

    runtime_local_file_identity=$(stat -Lc '%d:%i' \
        "/proc/${RUNTIME_LOCK_SENTINEL_PID}/fd/${RUNTIME_LOCK_OWNER_FILE_FD}" \
        2>/dev/null || true)
    runtime_local_scope_identity=$(stat -Lc '%d:%i' \
        "/proc/${RUNTIME_LOCK_SENTINEL_PID}/fd/${RUNTIME_LOCK_OWNER_SCOPE_FD}" \
        2>/dev/null || true)
    [ "${runtime_local_file_identity}" = "${RUNTIME_LOCK_FILE_IDENTITY}" ] &&
        [ "${runtime_local_scope_identity}" = "${RUNTIME_LOCK_SCOPE_IDENTITY}" ]
}

function runtime_release_install_lock {
    local runtime_local_attempt
    local runtime_local_max_attempts=3
    local runtime_local_had_helpers=0
    local runtime_local_had_descriptors=0
    local runtime_local_completed=0
    local runtime_local_teardown_failed=0
    local runtime_local_status_removal_failed=0
    local runtime_local_descriptor_close_failed=0
    local runtime_local_owner_termination_failed=0
    local runtime_local_owner_retirement_failed=0
    local runtime_local_sentinel_termination_failed=0
    local runtime_local_sentinel_was_live=0

    # Refresh the authoritative decision before teardown. If the file is
    # already absent or unreadable, the previously cached value is retained.
    runtime_update_lock_decision_state \
        "${RUNTIME_LOCK_DECISION_FILE:-}" || true

    # Keep intentional helper-loss notifications suppressed for the complete
    # teardown, including signals that were already queued when the helper
    # group disappeared. The flag remains set after cleanup because the
    # installer is about to terminate and no later helper transition is
    # meaningful.
    RUNTIME_LOCK_TEARDOWN_ACTIVE=1

    if [ -n "${RUNTIME_LOCK_PID:-}" ] ||
        [ -n "${RUNTIME_LOCK_HOLDER_PID:-}" ] ||
        [ -n "${RUNTIME_LOCK_WORKER_PID:-}" ] ||
        [ -n "${RUNTIME_LOCK_WATCHDOG_PID:-}" ] ||
        [ -n "${RUNTIME_LOCK_PGID:-}" ]; then
        runtime_local_had_helpers=1
    fi
    if [ -n "${RUNTIME_LOCK_FILE_FD:-}" ] ||
        [ -n "${RUNTIME_LOCK_SCOPE_FD:-}" ] ||
        [ -n "${RUNTIME_LOCK_OWNER_PID:-}" ] ||
        [ -n "${RUNTIME_LOCK_SENTINEL_PID:-}" ]; then
        runtime_local_had_descriptors=1
    fi

    if [ "${runtime_local_had_helpers}" -eq 0 ] &&
        [ "${runtime_local_had_descriptors}" -eq 0 ] &&
        [ -z "${RUNTIME_LOCK_STATUS_FILE:-}" ] &&
        [ -z "${RUNTIME_LOCK_OWNER_STATUS_FILE:-}" ] &&
        [ -z "${RUNTIME_LOCK_SENTINEL_STATUS_FILE:-}" ] &&
        [ -z "${RUNTIME_LOCK_SENTINEL_ACK_FILE:-}" ] &&
        [ -z "${RUNTIME_LOCK_OWNER_RETIREMENT_MARKER_FILE:-}" ]; then
        RUNTIME_LOCK_DEVICE=""
        RUNTIME_LOCK_INODE=""
        RUNTIME_LOCK_HELD=0
        RUNTIME_LOCK_TEARDOWN_ACTIVE=0
        return 0
    fi

    # Teardown and status removal are both retryable. State is cleared only
    # after the helpers are identity-confirmed gone, the group is empty, and
    # the status file has been removed successfully.
    for ((runtime_local_attempt = 1;  \
    runtime_local_attempt <= runtime_local_max_attempts;  \
    runtime_local_attempt++)); do
        if [ "${runtime_local_had_helpers}" -eq 1 ]; then
            if ! runtime_force_release_install_lock; then
                runtime_local_teardown_failed=1
                sleep 0.05 || true
                continue
            fi
        fi

        if { [ -n "${RUNTIME_LOCK_STATUS_FILE:-}" ] ||
            [ -n "${RUNTIME_LOCK_OWNER_STATUS_FILE:-}" ] ||
            [ -n "${RUNTIME_LOCK_SENTINEL_STATUS_FILE:-}" ]; } &&
            ! rm -f -- \
                "${RUNTIME_LOCK_STATUS_FILE:-}" \
                "${RUNTIME_LOCK_OWNER_STATUS_FILE:-}" \
                "${RUNTIME_LOCK_SENTINEL_STATUS_FILE:-}"; then
            runtime_local_status_removal_failed=1
            sleep 0.05 || true
            continue
        fi

        # The parent shell closes its retained descriptors only after helper
        # teardown and status removal have succeeded. Keep the scope lock
        # retained if the public lock descriptor cannot be closed, so the
        # installer domain never degrades into a partially released domain.
        runtime_local_descriptor_close_failed=0
        if [ -n "${RUNTIME_LOCK_FILE_FD:-}" ]; then
            if runtime_close_lock_descriptor "${RUNTIME_LOCK_FILE_FD}"; then
                RUNTIME_LOCK_FILE_FD=""
            else
                runtime_local_descriptor_close_failed=1
            fi
        fi
        if [ "${runtime_local_descriptor_close_failed}" -eq 0 ] &&
            [ -n "${RUNTIME_LOCK_SCOPE_FD:-}" ]; then
            if runtime_close_lock_descriptor "${RUNTIME_LOCK_SCOPE_FD}"; then
                RUNTIME_LOCK_SCOPE_FD=""
            else
                runtime_local_descriptor_close_failed=1
            fi
        fi
        if [ "${runtime_local_descriptor_close_failed}" -ne 0 ]; then
            sleep 0.05 || true
            continue
        fi

        # Retire the owner only after helper teardown and status removal have
        # succeeded. Until the sentinel acknowledges that retirement, both
        # support processes retain the exact lock descriptors.
        if ! runtime_retire_lock_owner; then
            runtime_local_owner_retirement_failed=1
            sleep 0.05 || true
            continue
        fi
        if { [ -n "${RUNTIME_LOCK_SENTINEL_ACK_FILE:-}" ] ||
            [ -n "${RUNTIME_LOCK_OWNER_RETIREMENT_MARKER_FILE:-}" ]; } &&
            ! rm -f -- \
                "${RUNTIME_LOCK_SENTINEL_ACK_FILE:-}" \
                "${RUNTIME_LOCK_OWNER_RETIREMENT_MARKER_FILE:-}"; then
            runtime_local_status_removal_failed=1
            sleep 0.05 || true
            continue
        fi

        # The sentinel is the final descriptor holder after the owner has been
        # retired. Verify its identity and exact inherited descriptors before
        # terminating it, so cleanup never claims a release based only on a
        # stale numeric PID.
        runtime_local_owner_termination_failed=0
        if [ -n "${RUNTIME_LOCK_OWNER_PID:-}" ]; then
            if ! runtime_terminate_lock_helper \
                "${RUNTIME_LOCK_OWNER_PID}" \
                "${RUNTIME_LOCK_OWNER_IDENTITY:-}"; then
                runtime_local_owner_termination_failed=1
            else
                wait "${RUNTIME_LOCK_OWNER_PID}" 2>/dev/null || true
            fi
        fi
        if [ "${runtime_local_owner_termination_failed}" -ne 0 ]; then
            sleep 0.05 || true
            continue
        fi

        runtime_local_sentinel_termination_failed=0
        runtime_local_sentinel_was_live=0
        if [ "${RUNTIME_LOCK_SENTINEL_ARMED}" -eq 1 ]; then
            if runtime_process_identity_matches \
                "${RUNTIME_LOCK_SENTINEL_PID}" \
                "${RUNTIME_LOCK_SENTINEL_IDENTITY:-}"; then
                runtime_local_sentinel_was_live=1
                if ! runtime_verify_lock_sentinel; then
                    runtime_local_sentinel_termination_failed=1
                fi
            fi
            # The owner has already been retired. Mark the final sentinel
            # teardown before terminating it so any queued support-loss
            # notification is recognized as intentional cleanup. A sentinel
            # that was already dead remains an unexpected support loss.
            if [ "${runtime_local_sentinel_was_live}" -eq 1 ]; then
                RUNTIME_LOCK_SUPPORT_TEARDOWN_ACTIVE=1
            fi
            if [ "${runtime_local_sentinel_termination_failed}" -eq 0 ] &&
                ! runtime_terminate_lock_helper \
                    "${RUNTIME_LOCK_SENTINEL_PID}" \
                    "${RUNTIME_LOCK_SENTINEL_IDENTITY:-}"; then
                runtime_local_sentinel_termination_failed=1
            elif [ "${runtime_local_sentinel_termination_failed}" -eq 0 ]; then
                wait "${RUNTIME_LOCK_SENTINEL_PID}" 2>/dev/null || true
            fi
        fi
        if [ "${runtime_local_sentinel_termination_failed}" -ne 0 ]; then
            sleep 0.05 || true
            continue
        fi

        runtime_local_completed=1
        break
    done

    if [ "${runtime_local_completed}" -ne 1 ]; then
        if [ "${runtime_local_teardown_failed}" -ne 0 ]; then
            printf 'runtime: unable to terminate the installation lock helpers\n' >&2
        fi
        if [ "${runtime_local_status_removal_failed}" -ne 0 ]; then
            printf 'runtime: unable to remove the installation lock status file\n' >&2
        fi
        if [ "${runtime_local_descriptor_close_failed}" -ne 0 ]; then
            printf 'runtime: unable to close the installation lock descriptors\n' >&2
        fi
        if [ "${runtime_local_owner_termination_failed}" -ne 0 ]; then
            printf 'runtime: unable to terminate the installation lock owner\n' >&2
        fi
        if [ "${runtime_local_owner_retirement_failed}" -ne 0 ]; then
            printf 'runtime: unable to retire the installation lock owner\n' >&2
        fi
        if [ "${runtime_local_sentinel_termination_failed}" -ne 0 ]; then
            printf 'runtime: unable to terminate the installation lock sentinel\n' >&2
        fi
        return 1
    fi

    # Helper and support notifications are no longer meaningful after the
    # confirmed empty group and final support-process termination. Disarm the
    # traps before clearing their identity state so a queued signal cannot
    # race the state reset.
    trap '' USR1
    trap '' SIGRTMIN
    trap '' SIGRTMIN+1

    # Keep the decision path and cached decision in this shell until installer
    # termination so a helper-loss signal during cleanup can still distinguish
    # cancellation from generic loss even if the decision file is unreadable.
    RUNTIME_LOCK_HOLDER_PID=""
    RUNTIME_LOCK_HOLDER_IDENTITY=""
    RUNTIME_LOCK_WORKER_PID=""
    RUNTIME_LOCK_WORKER_IDENTITY=""
    RUNTIME_LOCK_WATCHDOG_PID=""
    RUNTIME_LOCK_WATCHDOG_IDENTITY=""
    RUNTIME_LOCK_PID=""
    RUNTIME_LOCK_GUARDIAN_IDENTITY=""
    RUNTIME_LOCK_PGID=""
    RUNTIME_LOCK_STATUS_FILE=""
    RUNTIME_LOCK_FILE_FD=""
    RUNTIME_LOCK_SCOPE_FD=""
    RUNTIME_LOCK_OWNER_PID=""
    RUNTIME_LOCK_OWNER_IDENTITY=""
    RUNTIME_LOCK_OWNER_FILE_FD=""
    RUNTIME_LOCK_OWNER_SCOPE_FD=""
    RUNTIME_LOCK_OWNER_STATUS_FILE=""
    RUNTIME_LOCK_SENTINEL_PID=""
    RUNTIME_LOCK_SENTINEL_IDENTITY=""
    RUNTIME_LOCK_SENTINEL_STATUS_FILE=""
    RUNTIME_LOCK_SENTINEL_ACK_FILE=""
    RUNTIME_LOCK_OWNER_RETIREMENT_MARKER_FILE=""
    RUNTIME_LOCK_SENTINEL_ARMED=0
    RUNTIME_LOCK_SUPPORT_TEARDOWN_ACTIVE=0
    RUNTIME_LOCK_OWNER_RETIREMENT_ACK=0
    RUNTIME_LOCK_FILE_IDENTITY=""
    RUNTIME_LOCK_SCOPE_IDENTITY=""
    RUNTIME_LOCK_INSTALLER_PID=""
    RUNTIME_LOCK_INSTALLER_IDENTITY=""
    RUNTIME_LOCK_DEVICE=""
    RUNTIME_LOCK_INODE=""
    RUNTIME_LOCK_HELD=0
    RUNTIME_LOCK_TEARDOWN_ACTIVE=0
    return 0
}

function runtime_register_cleanup {
    local runtime_local_name="${1}"
    local runtime_local_callback="${2}"

    if ! [[ "${runtime_local_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        printf 'runtime: invalid cleanup name: %s\n' "${runtime_local_name}" >&2
        return 1
    fi

    if ! declare -F "${runtime_local_callback}" >/dev/null; then
        printf 'runtime: cleanup callback does not exist: %s\n' "${runtime_local_callback}" >&2
        return 1
    fi

    if [ "${runtime_local_name}" = "install-lock" ]; then
        # Cleanup callbacks run in reverse registration order. Keep the lock
        # teardown first in that order so it always runs last and the lock
        # remains held throughout every other cleanup callback.
        local runtime_local_remaining=()
        local runtime_local_existing
        for runtime_local_existing in "${RUNTIME_CLEANUP_ORDER[@]}"; do
            if [ "${runtime_local_existing}" != "${runtime_local_name}" ]; then
                runtime_local_remaining+=("${runtime_local_existing}")
            fi
        done
        RUNTIME_CLEANUP_ORDER=("${runtime_local_name}" "${runtime_local_remaining[@]}")
    elif [ -z "${RUNTIME_CLEANUP_CALLBACKS[${runtime_local_name}]:-}" ]; then
        RUNTIME_CLEANUP_ORDER+=("${runtime_local_name}")
    fi
    RUNTIME_CLEANUP_CALLBACKS["${runtime_local_name}"]="${runtime_local_callback}"
    return 0
}

function runtime_unregister_cleanup {
    local runtime_local_name="${1}"
    local runtime_local_index
    local runtime_local_existing
    local -a runtime_local_remaining=()

    if [ -z "${runtime_local_name}" ]; then
        return 1
    fi

    unset 'RUNTIME_CLEANUP_CALLBACKS[${runtime_local_name}]'
    for runtime_local_index in "${!RUNTIME_CLEANUP_ORDER[@]}"; do
        runtime_local_existing="${RUNTIME_CLEANUP_ORDER[runtime_local_index]}"
        if [ "${runtime_local_existing}" != "${runtime_local_name}" ]; then
            runtime_local_remaining+=("${runtime_local_existing}")
        fi
    done
    RUNTIME_CLEANUP_ORDER=("${runtime_local_remaining[@]}")
    return 0
}

function runtime_fatal {
    local runtime_local_message="${1:-Fatal error}"
    local runtime_local_status="${2:-1}"

    runtime_log "ERROR" "${runtime_local_message}" || true
    printf 'runtime: %s\n' "${runtime_local_message}" >&2
    exit "${runtime_local_status}"
}

function runtime_enter_critical_section {
    local runtime_local_name="${1:-operation}"

    RUNTIME_CRITICAL_DEPTH=$((RUNTIME_CRITICAL_DEPTH + 1))
    runtime_log "INFO" "Entering critical section '${runtime_local_name}'."
    return 0
}

function runtime_leave_critical_section {
    local runtime_local_name="${1:-operation}"
    local runtime_local_callback="${2:-}"
    local runtime_local_status

    if [ "${RUNTIME_CRITICAL_DEPTH}" -gt 0 ]; then
        RUNTIME_CRITICAL_DEPTH=$((RUNTIME_CRITICAL_DEPTH - 1))
    fi
    runtime_log "INFO" "Leaving critical section '${runtime_local_name}'."

    if [ "${RUNTIME_CRITICAL_DEPTH}" -eq 0 ] && [ "${RUNTIME_PENDING_SIGNAL_STATUS}" -ne 0 ]; then
        runtime_local_status="${RUNTIME_PENDING_SIGNAL_STATUS}"
        if [ -n "${runtime_local_callback}" ]; then
            if ! declare -F "${runtime_local_callback}" >/dev/null; then
                printf 'runtime: critical section callback does not exist: %s\n' \
                    "${runtime_local_callback}" >&2
            elif ! "${runtime_local_callback}"; then
                runtime_log "WARN" "Critical section callback '${runtime_local_callback}' failed."
            fi
        fi
        RUNTIME_PENDING_SIGNAL_STATUS=0
        RUNTIME_PENDING_SIGNAL_NAME=""
        runtime_log "WARN" "Resuming shutdown after critical section '${runtime_local_name}'."
        exit "${runtime_local_status}"
    fi

    return 0
}

function runtime_prefer_shutdown_status {
    local runtime_local_current="${1:-0}"
    local runtime_local_candidate="${2:-0}"

    # Security-specific acquisition and lock-loss states dominate ordinary
    # shutdown signals. Preserve an existing security-specific state because
    # acquisition failures/cancellations (73) and post-acquisition losses
    # (141) are mutually exclusive terminal classifications.
    case "${runtime_local_current}" in
    73 | 141)
        printf '%s\n' "${runtime_local_current}"
        return 0
        ;;
    esac
    case "${runtime_local_candidate}" in
    73 | 141)
        printf '%s\n' "${runtime_local_candidate}"
        return 0
        ;;
    esac

    # Ordinary shutdown signals have a deterministic precedence. TERM (143)
    # dominates INT (130), which dominates HUP (129), regardless of arrival
    # order. A generic nonzero status is retained unless one of these exact
    # terminal classifications becomes available.
    case "${runtime_local_current}" in
    143)
        printf '%s\n' "143"
        return 0
        ;;
    130)
        if [ "${runtime_local_candidate}" = "143" ]; then
            printf '%s\n' "143"
        else
            printf '%s\n' "130"
        fi
        return 0
        ;;
    129)
        case "${runtime_local_candidate}" in
        143 | 130)
            printf '%s\n' "${runtime_local_candidate}"
            ;;
        *)
            printf '%s\n' "129"
            ;;
        esac
        return 0
        ;;
    esac

    case "${runtime_local_candidate}" in
    129 | 130 | 143)
        printf '%s\n' "${runtime_local_candidate}"
        ;;
    *)
        printf '%s\n' "${runtime_local_current}"
        ;;
    esac
}

function runtime_set_pending_signal_status {
    local runtime_local_candidate="${1:-0}"
    local runtime_local_candidate_name="${2:-signal}"
    local runtime_local_current="${RUNTIME_PENDING_SIGNAL_STATUS:-0}"
    local runtime_local_preferred

    runtime_local_preferred=$(runtime_prefer_shutdown_status \
        "${runtime_local_current}" "${runtime_local_candidate}")
    if [ "${runtime_local_current}" != "${runtime_local_preferred}" ] ||
        [ "${runtime_local_current}" -eq 0 ]; then
        RUNTIME_PENDING_SIGNAL_NAME="${runtime_local_candidate_name}"
    fi
    RUNTIME_PENDING_SIGNAL_STATUS="${runtime_local_preferred}"
}

function runtime_handle_signal {
    local runtime_local_status="${1:-1}"
    local runtime_local_name="${2:-signal}"

    # Lock loss is a security-sensitive terminal status. Once it is pending,
    # an ordinary shutdown signal must not replace status 141 during cleanup.
    if [ "${RUNTIME_PENDING_LOCK_LOSS}" -eq 1 ]; then
        runtime_log "WARN" "Received ${runtime_local_name}; preserving pending lock-loss status ${RUNTIME_PENDING_SIGNAL_STATUS}." \
            "runtime.lock.lost" || true
        return 0
    fi

    if [ "${RUNTIME_LOCK_ACQUIRING}" -eq 1 ]; then
        # An operator shutdown during acquisition keeps its exact signal
        # status. Exit immediately so Bash cannot defer the trap until an
        # acquisition helper has completed. A separate helper or decision
        # failure still uses status 73 and is recorded as a lock loss.
        runtime_set_pending_signal_status \
            "${runtime_local_status}" "${runtime_local_name}"
        RUNTIME_LOCK_ACQUIRING=0
        runtime_log "WARN" "Received ${runtime_local_name}; aborting lock acquisition safely." \
            "runtime.lock.failed" || true
        exit "${RUNTIME_PENDING_SIGNAL_STATUS}"
    fi

    if [ "${RUNTIME_CRITICAL_DEPTH}" -gt 0 ] || [ "${RUNTIME_CLEANING}" -eq 1 ]; then
        runtime_set_pending_signal_status \
            "${runtime_local_status}" "${runtime_local_name}"
        runtime_log "WARN" "Received ${runtime_local_name}; deferring shutdown until the current operation completes."
        return 0
    fi

    runtime_log "WARN" "Received ${runtime_local_name}; shutting down."
    # Retain the ordinary shutdown status while cleanup runs. This lets
    # cleanup distinguish an expected helper termination notification from a
    # genuine lock-loss signal that arrived before teardown began.
    runtime_set_pending_signal_status \
        "${runtime_local_status}" "${runtime_local_name}"
    exit "${RUNTIME_PENDING_SIGNAL_STATUS}"
}

function runtime_handle_lock_loss {
    local runtime_local_status="${1:-141}"
    local runtime_local_decision_state="${RUNTIME_LOCK_DECISION_STATE:-unknown}"

    # A cancellation winner is distinct from a helper failure. The guardian
    # uses USR1 to wake an installer that may be waiting for the guardian; the
    # decision lets the installer report the intended cancellation status
    # instead of a generic lock-loss status. If the decision file has already
    # disappeared or cannot be read, the cached authoritative state remains
    # authoritative for this installer.
    case "${runtime_local_decision_state}" in
    committed | cancelled | unknown) ;;
    *) runtime_local_decision_state="unknown" ;;
    esac
    if runtime_update_lock_decision_state \
        "${RUNTIME_LOCK_DECISION_FILE:-}"; then
        runtime_local_decision_state="${RUNTIME_LOCK_DECISION_STATE}"
    fi

    # Helper teardown intentionally kills the supervisor, worker, and
    # watchdog. One of those processes can report the expected loss before it
    # exits. Do not turn that teardown notification into a new terminal
    # status: an acquisition that is already failing remains status 73, and
    # an ordinary shutdown retains its original status. A cancellation remains
    # security-specific even when it is observed during teardown. A loss
    # observed before teardown starts is still handled as status 141 below.
    if [ "${RUNTIME_LOCK_TEARDOWN_ACTIVE}" -eq 1 ] &&
        [ "${RUNTIME_PENDING_LOCK_LOSS}" -ne 1 ]; then
        case "${runtime_local_decision_state}" in
        committed)
            # A committed decision proves that the helper notification was
            # caused by the intentional teardown itself.
            return 0
            ;;
        cancelled)
            RUNTIME_PENDING_LOCK_LOSS=1
            runtime_set_pending_signal_status 73 "lock-cancelled"
            ;;
        unknown)
            # An ordinary operator signal may already have started an
            # intentional pre-commit teardown. In that case the helper
            # notification is expected and must not replace the exact
            # shutdown status. A previously observed helper loss remains
            # authoritative through RUNTIME_PENDING_LOCK_LOSS.
            if [ "${RUNTIME_PENDING_SIGNAL_STATUS}" -ne 0 ] &&
                [ "${RUNTIME_PENDING_LOCK_LOSS}" -ne 1 ]; then
                return 0
            fi
            # Otherwise an unclassifiable decision is not evidence of
            # intentional teardown. Fall through to the conservative generic
            # failure.
            ;;
        esac
    fi

    if [ "${RUNTIME_LOCK_ACQUIRING}" -eq 1 ]; then
        RUNTIME_PENDING_LOCK_LOSS=1
        runtime_set_pending_signal_status 73 "lock-acquisition-failed"
        if [ "${runtime_local_decision_state}" = "cancelled" ]; then
            RUNTIME_PENDING_SIGNAL_NAME="lock-cancelled"
        else
            RUNTIME_PENDING_SIGNAL_NAME="lock-acquisition-failed"
        fi
        runtime_log "ERROR" "The installation lock acquisition was interrupted; aborting the acquisition safely." \
            "runtime.lock.failed" || true
        return 0
    fi

    if [ "${runtime_local_decision_state}" = "cancelled" ]; then
        RUNTIME_PENDING_LOCK_LOSS=1
        runtime_set_pending_signal_status 73 "lock-cancelled"
        if [ "${RUNTIME_CRITICAL_DEPTH}" -gt 0 ] || [ "${RUNTIME_CLEANING}" -eq 1 ]; then
            runtime_log "ERROR" "The installation lock acquisition was cancelled; aborting after the current operation completes." \
                "runtime.lock.cancelled" || true
            printf 'runtime: installation lock acquisition was cancelled; aborting after cleanup\n' >&2
            return 0
        fi
        runtime_log "ERROR" "The installation lock acquisition was cancelled; aborting immediately." \
            "runtime.lock.cancelled" || true
        printf 'runtime: installation lock acquisition was cancelled; aborting immediately\n' >&2
        exit "${RUNTIME_PENDING_SIGNAL_STATUS}"
    fi

    # A helper failure before acquisition has completed is an acquisition
    # failure, not a loss of an already-held installation lock. In
    # particular, do not turn it into a wait for the guardian: the guardian
    # may be waiting for this installer to exit. RUNTIME_LOCK_ACQUIRED remains
    # set after cleanup starts, so a later helper failure is still classified
    # as generic loss rather than acquisition failure.
    if [ "${RUNTIME_LOCK_ACQUIRED}" -ne 1 ]; then
        RUNTIME_PENDING_LOCK_LOSS=1
        runtime_set_pending_signal_status 73 "lock-acquisition-failed"
        if [ "${RUNTIME_CRITICAL_DEPTH}" -gt 0 ] || [ "${RUNTIME_CLEANING}" -eq 1 ]; then
            runtime_log "ERROR" "The installation lock acquisition failed; aborting after the current operation completes." \
                "runtime.lock.failed" || true
            printf 'runtime: installation lock acquisition failed; aborting after cleanup\n' >&2
            return 0
        fi
        runtime_log "ERROR" "The installation lock acquisition failed; aborting immediately." \
            "runtime.lock.failed" || true
        printf 'runtime: installation lock acquisition failed; installation lock was lost; aborting immediately\n' >&2
        exit "${RUNTIME_PENDING_SIGNAL_STATUS}"
    fi

    # Lock loss always takes precedence over a previously pending ordinary
    # signal, and remains pending until the installer exits.
    RUNTIME_PENDING_LOCK_LOSS=1
    runtime_set_pending_signal_status \
        "${runtime_local_status}" "lock-loss"

    if [ "${RUNTIME_CRITICAL_DEPTH}" -gt 0 ] || [ "${RUNTIME_CLEANING}" -eq 1 ]; then
        runtime_log "ERROR" "The installation lock helpers failed; aborting after the current operation completes." \
            "runtime.lock.lost" || true
        printf 'runtime: installation lock helpers failed; aborting after cleanup\n' >&2
        return 0
    fi

    runtime_log "ERROR" "The installation lock helpers failed; aborting immediately." \
        "runtime.lock.lost" || true
    printf 'runtime: installation lock was lost; aborting immediately\n' >&2
    exit "${RUNTIME_PENDING_SIGNAL_STATUS}"
}

function runtime_handle_owner_loss {
    if [ "${RUNTIME_LOCK_ACQUIRING}" -eq 1 ] ||
        [ "${RUNTIME_LOCK_ACQUIRED}" -ne 1 ]; then
        RUNTIME_PENDING_LOCK_LOSS=1
        runtime_set_pending_signal_status 73 "lock-acquisition-failed"
        RUNTIME_LOCK_ACQUIRING=0
        runtime_log "ERROR" "The installation lock owner failed during acquisition; aborting safely." \
            "runtime.lock.failed" || true
        printf 'runtime: installation lock owner failed during acquisition; aborting safely\n' >&2
        exit "${RUNTIME_PENDING_SIGNAL_STATUS}"
    fi

    RUNTIME_PENDING_LOCK_LOSS=1
    runtime_set_pending_signal_status 141 "owner-loss"
    if [ "${RUNTIME_CRITICAL_DEPTH}" -gt 0 ] || [ "${RUNTIME_CLEANING}" -eq 1 ]; then
        runtime_log "ERROR" "The installation lock owner failed; aborting after the current operation completes." \
            "runtime.lock.lost" || true
        printf 'runtime: installation lock owner failed; aborting after cleanup\n' >&2
        return 0
    fi

    runtime_log "ERROR" "The installation lock owner failed; aborting immediately." \
        "runtime.lock.lost" || true
    printf 'runtime: installation lock owner failed; aborting immediately\n' >&2
    exit "${RUNTIME_PENDING_SIGNAL_STATUS}"
}

function runtime_handle_support_loss {
    if [ "${RUNTIME_LOCK_SUPPORT_TEARDOWN_ACTIVE}" -eq 1 ]; then
        # The installer intentionally removed the sentinel before the owner
        # during the final support teardown. The owner correctly reports that
        # support loss, but it is an expected consequence of cleanup and must
        # not replace an exact operator shutdown status.
        runtime_log "WARN" "Received support-loss notification during intentional support teardown; preserving the current status." \
            "runtime.lock.lost" || true
        return 0
    fi

    if [ "${RUNTIME_LOCK_ACQUIRING}" -eq 1 ] ||
        [ "${RUNTIME_LOCK_ACQUIRED}" -ne 1 ]; then
        RUNTIME_PENDING_LOCK_LOSS=1
        runtime_set_pending_signal_status 73 "lock-acquisition-failed"
        RUNTIME_LOCK_ACQUIRING=0
        runtime_log "ERROR" "The installation lock support failed during acquisition; aborting safely." \
            "runtime.lock.failed" || true
        printf 'runtime: installation lock support failed during acquisition; aborting safely\n' >&2
        exit "${RUNTIME_PENDING_SIGNAL_STATUS}"
    fi

    RUNTIME_PENDING_LOCK_LOSS=1
    runtime_set_pending_signal_status 141 "support-loss"
    if [ "${RUNTIME_CRITICAL_DEPTH}" -gt 0 ] || [ "${RUNTIME_CLEANING}" -eq 1 ]; then
        runtime_log "ERROR" "The installation lock support failed; aborting after the current operation completes." \
            "runtime.lock.lost" || true
        printf 'runtime: installation lock support failed; aborting after cleanup\n' >&2
        return 0
    fi

    runtime_log "ERROR" "The installation lock support failed; aborting immediately." \
        "runtime.lock.lost" || true
    printf 'runtime: installation lock support failed; aborting immediately\n' >&2
    exit "${RUNTIME_PENDING_SIGNAL_STATUS}"
}

function runtime_cleanup {
    local runtime_local_status="${?}"
    local runtime_local_original_status="${runtime_local_status}"
    local runtime_local_final_status
    local runtime_local_index
    local runtime_local_name
    local runtime_local_callback
    local runtime_local_callback_status=0
    local runtime_local_cleanup_status=0
    local runtime_local_failure_count=0
    local runtime_local_summary_status=0
    local runtime_local_summary_operation=""
    local runtime_local_summary_total=0
    local runtime_local_summary_completed=0
    local runtime_local_summary_skipped=0
    local runtime_local_summary_failed=0
    local runtime_local_summary_required=0
    local runtime_local_summary_canceled=0
    local runtime_local_operation_failure=0

    # Cleanup callbacks are commands, not command-line argument carriers.
    # Clear the function's inherited positional parameters so every callback
    # receives an explicit empty argument list.
    set --

    # USR2 is an acquisition-only cancellation request. Once teardown has
    # started it must not interrupt the parent-shell lock cleanup.
    trap '' USR2

    if [ "${RUNTIME_CLEANING}" -eq 1 ] || [ "${RUNTIME_CLEANED}" -eq 1 ]; then
        return "${runtime_local_status}"
    fi
    RUNTIME_CLEANING=1

    # Modules are sourced into the installer shell. An explicit `exit` inside
    # a module therefore bypasses runtime_run_module and reaches this trap
    # directly. Treat that termination as a module failure instead of
    # allowing an incomplete installation to report success.
    if [ "${RUNTIME_MODULE_ACTIVE_DEPTH}" -gt 0 ] &&
        [ "${RUNTIME_MODULE_FAILURE_STATUS}" -eq 0 ] &&
        [ "${#RUNTIME_MODULE_STACK[@]}" -gt 0 ]; then
        runtime_local_index=$((${#RUNTIME_MODULE_STACK[@]} - 1))
        if [ "${runtime_local_status}" -eq 0 ]; then
            runtime_local_status=1
        fi
        runtime_record_module_failure "${runtime_local_status}" \
            "${RUNTIME_MODULE_STACK[runtime_local_index]}"
        RUNTIME_MODULE_FIRST_ERROR_STATUS="${runtime_local_status}"
        RUNTIME_MODULE_FIRST_ERROR_COMMAND="module termination"
        runtime_log "ERROR" "Module '${RUNTIME_MODULE_STACK[runtime_local_index]}' terminated unexpectedly with status ${runtime_local_status}." \
            "runtime.module.failed" || true
    fi

    if [ "${RUNTIME_MODULE_FIRST_ERROR_STATUS}" -ne 0 ] &&
        [ "${#RUNTIME_MODULE_STACK[@]}" -gt 0 ]; then
        for ((runtime_local_index = ${#RUNTIME_MODULE_STACK[@]} - 1; runtime_local_index >= 0; runtime_local_index--)); do
            runtime_log "ERROR" "Module '${RUNTIME_MODULE_STACK[runtime_local_index]}' failed with status ${RUNTIME_MODULE_FIRST_ERROR_STATUS}."
        done
    fi

    for ((runtime_local_index = ${#RUNTIME_CLEANUP_ORDER[@]} - 1; runtime_local_index >= 0; runtime_local_index--)); do
        runtime_local_name="${RUNTIME_CLEANUP_ORDER[runtime_local_index]}"
        runtime_local_callback="${RUNTIME_CLEANUP_CALLBACKS[${runtime_local_name}]:-}"
        if [ -n "${runtime_local_callback}" ] && declare -F "${runtime_local_callback}" >/dev/null; then
            runtime_local_callback_status=0
            if [ "${runtime_local_name}" = "install-lock" ]; then
                # The lock cleanup owns descriptors in the installer parent
                # shell, so it must run in this shell rather than a child.
                if "${runtime_local_callback}"; then
                    runtime_local_callback_status=0
                else
                    runtime_local_callback_status="${?}"
                fi
            else
                # Isolate ordinary callbacks so an explicit exit cannot skip
                # the remaining callbacks or terminate the EXIT-trap shell.
                if (
                    trap - EXIT
                    trap - ERR
                    trap '' HUP TERM INT USR1 USR2
                    "${runtime_local_callback}"
                ); then
                    runtime_local_callback_status=0
                else
                    runtime_local_callback_status="${?}"
                fi
            fi
            if [ "${runtime_local_callback_status}" -ne 0 ]; then
                if [ "${runtime_local_cleanup_status}" -eq 0 ]; then
                    runtime_local_cleanup_status="${runtime_local_callback_status}"
                fi
                runtime_log "WARN" "Cleanup callback '${runtime_local_name}' failed with status ${runtime_local_callback_status}."
            fi
        fi
    done

    RUNTIME_CLEANUP_FAILURE_STATUS="${runtime_local_cleanup_status}"

    # Mark cleanup complete before selecting the terminal status. Once
    # RUNTIME_CLEANING is cleared, a shutdown signal that arrives at the
    # status-selection boundary is handled immediately with its own status
    # instead of being deferred after the final status has been chosen.
    RUNTIME_CLEANING=0
    RUNTIME_CLEANED=1

    runtime_local_final_status="${runtime_local_status}"
    if [ "${RUNTIME_PENDING_LOCK_LOSS}" -eq 1 ] &&
        [ "${RUNTIME_PENDING_SIGNAL_STATUS}" -ne 0 ]; then
        # Lock loss and cancellation are more security-specific than a
        # cleanup failure and retain their established 73/141 statuses.
        runtime_local_final_status="${RUNTIME_PENDING_SIGNAL_STATUS}"
    elif [ "${RUNTIME_PENDING_SIGNAL_STATUS}" -ne 0 ]; then
        # A pending operator signal keeps its exact required status. Cleanup
        # remains visible through its warning log, but a generic cleanup
        # failure must not replace 143, 130, or 129.
        runtime_local_final_status="${RUNTIME_PENDING_SIGNAL_STATUS}"
    elif [ "${runtime_local_cleanup_status}" -ne 0 ] &&
        [ "${runtime_local_status}" -eq 0 ]; then
        # A cleanup failure is the terminal status only when the operation
        # itself succeeded. A module's exact failure status remains primary;
        # the cleanup failure is still visible in the structured warning log.
        runtime_local_final_status="${runtime_local_cleanup_status}"
    fi

    if [ "${RUNTIME_SUMMARY_PENDING}" -eq 1 ] &&
        [ "${RUNTIME_PENDING_SIGNAL_STATUS}" -eq 0 ]; then
        case "${RUNTIME_SUMMARY_OPERATION}" in
        *canceled* | *cancelled*) runtime_local_summary_canceled=1 ;;
        esac
    fi

    runtime_local_operation_failure=0
    if [ "${RUNTIME_SUMMARY_PENDING}" -eq 1 ] &&
        [ "${runtime_local_summary_canceled}" -eq 1 ]; then
        # An intentional cancellation is not an additional failed unit.
        runtime_local_operation_failure=0
    elif [ "${runtime_local_final_status}" -ne 0 ]; then
        # Any terminal failure without a failed module is operation-level,
        # including a failure after every counted module has completed.
        runtime_local_operation_failure=1
    fi

    if [ "${runtime_local_cleanup_status}" -ne 0 ]; then
        # Cleanup is part of the operation. Its failure remains operation-level
        # even when every module completed successfully.
        RUNTIME_OPERATION_FAILED=1
    elif [ "${runtime_local_final_status}" -ne 0 ] &&
        [ "${RUNTIME_MODULE_FAILED}" -eq 0 ] &&
        [ "${RUNTIME_OPERATION_FAILED}" -eq 0 ] &&
        [ "${runtime_local_operation_failure}" -eq 1 ]; then
        # A failure before all counted units completed is an operation-level
        # failure rather than a module failure. Keep the two categories
        # distinct while still reporting one failed unit in the summary.
        RUNTIME_OPERATION_FAILED=1
    fi

    if [ "${RUNTIME_SUMMARY_PENDING}" -eq 1 ]; then
        runtime_local_summary_required=1
        runtime_local_summary_operation="${RUNTIME_SUMMARY_OPERATION}"
        runtime_local_summary_total="${RUNTIME_SUMMARY_TOTAL}"
        runtime_local_summary_completed="${RUNTIME_SUMMARY_COMPLETED}"
        runtime_local_summary_skipped="${RUNTIME_SUMMARY_SKIPPED}"
        runtime_local_summary_failed="${RUNTIME_SUMMARY_FAILED}"

        if [ "${runtime_local_cleanup_status}" -ne 0 ] ||
            { [ "${runtime_local_final_status}" -ne 0 ] &&
                [ "${runtime_local_summary_canceled}" -ne 1 ]; }; then
            case "${RUNTIME_SUMMARY_OPERATION}" in
            *" complete")
                runtime_local_summary_operation="${RUNTIME_SUMMARY_OPERATION% complete} failed"
                ;;
            *)
                runtime_local_summary_operation="${RUNTIME_OPERATION_LABEL} failed"
                ;;
            esac
            runtime_local_summary_total="${RUNTIME_MODULE_TOTAL}"
            runtime_local_summary_completed="${RUNTIME_MODULE_COMPLETED}"
            runtime_local_summary_skipped="${RUNTIME_MODULE_SKIPPED}"
            runtime_local_failure_count=$((RUNTIME_MODULE_FAILED + RUNTIME_OPERATION_FAILED))
            runtime_local_summary_failed="${runtime_local_failure_count}"
        fi
    elif [ "${runtime_local_final_status}" -ne 0 ]; then
        runtime_local_summary_required=1
        runtime_local_summary_operation="${RUNTIME_OPERATION_LABEL} failed"
        runtime_local_summary_total="${RUNTIME_MODULE_TOTAL}"
        runtime_local_summary_completed="${RUNTIME_MODULE_COMPLETED}"
        runtime_local_summary_skipped="${RUNTIME_MODULE_SKIPPED}"
        runtime_local_failure_count=$((RUNTIME_MODULE_FAILED + RUNTIME_OPERATION_FAILED))
        runtime_local_summary_failed="${runtime_local_failure_count}"
    fi

    if [ "${runtime_local_summary_required}" -eq 1 ] &&
        [ "${RUNTIME_SUMMARY_RENDERED}" -ne 1 ]; then
        if runtime_emit_result_summary \
            "${runtime_local_summary_operation}" \
            "${runtime_local_summary_total}" \
            "${runtime_local_summary_completed}" \
            "${runtime_local_summary_skipped}" \
            "${runtime_local_summary_failed}"; then
            runtime_local_summary_status=0
        else
            runtime_local_summary_status="${?}"
        fi
        RUNTIME_SUMMARY_PENDING=0
        if [ "${runtime_local_summary_status}" -ne 0 ] &&
            [ "${runtime_local_final_status}" -eq 0 ]; then
            # Preserve the historical behavior where a failed summary renderer
            # makes an otherwise successful operation fail.
            runtime_local_final_status="${runtime_local_summary_status}"
            RUNTIME_OPERATION_FAILED=1
        fi
    fi
    if [ "${runtime_local_final_status}" -ne "${runtime_local_original_status}" ]; then
        exit "${runtime_local_final_status}"
    fi
    return "${runtime_local_final_status}"
}

function runtime_append_file {
    local runtime_local_path="${1}"
    local runtime_local_content="${2}"
    local runtime_local_helper="${SCRIPT_PATH}/common/runtime-file.py"

    if [ ! -f "${runtime_local_helper}" ] || [ -L "${runtime_local_helper}" ]; then
        printf 'runtime: secure file helper is unavailable\n' >&2
        return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        printf 'runtime: python3 is unavailable\n' >&2
        return 1
    fi

    printf '%s' "${runtime_local_content}" |
        python3 "${runtime_local_helper}" append "${runtime_local_path}"
}

function runtime_read_file {
    local runtime_local_path="${1}"
    local runtime_local_helper="${SCRIPT_PATH}/common/runtime-file.py"

    if [ ! -f "${runtime_local_helper}" ] || [ -L "${runtime_local_helper}" ]; then
        printf 'runtime: secure file helper is unavailable\n' >&2
        return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        printf 'runtime: python3 is unavailable\n' >&2
        return 1
    fi

    python3 "${runtime_local_helper}" read "${runtime_local_path}"
}

function runtime_capture_output {
    local runtime_local_name="${1}"
    local runtime_local_output
    local runtime_local_status

    shift
    if [ "$#" -eq 0 ]; then
        printf 'runtime: no command was provided for output capture\n' >&2
        return 1
    fi
    if ! [[ "${runtime_local_name}" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
        printf 'runtime: invalid output variable name: %s\n' "${runtime_local_name}" >&2
        return 1
    fi

    # The conditional context prevents the ERR trap from treating a failed
    # command substitution as an unrecoverable module error. The caller decides
    # whether the captured status is fatal or retryable.
    if runtime_local_output=$("$@"); then
        runtime_local_status=0
    else
        runtime_local_status="${?}"
    fi
    if [ "${runtime_local_status}" -ne 0 ]; then
        return "${runtime_local_status}"
    fi

    printf -v "${runtime_local_name}" '%s' "${runtime_local_output}"
    return 0
}

function runtime_log_level_value {
    case "${1^^}" in
    DEBUG) printf '%s\n' "0" ;;
    INFO) printf '%s\n' "1" ;;
    WARN) printf '%s\n' "2" ;;
    ERROR) printf '%s\n' "3" ;;
    *) printf '%s\n' "1" ;;
    esac
}

function runtime_log_should_emit {
    local runtime_local_level="${1:-INFO}"
    local runtime_local_threshold="${POSTINSTALL_LOG_LEVEL:-info}"
    local runtime_local_level_value
    local runtime_local_threshold_value

    case "${runtime_local_level^^}" in
    DEBUG) runtime_local_level_value=0 ;;
    INFO) runtime_local_level_value=1 ;;
    WARN) runtime_local_level_value=2 ;;
    ERROR) runtime_local_level_value=3 ;;
    *) runtime_local_level_value=1 ;;
    esac
    case "${runtime_local_threshold^^}" in
    DEBUG) runtime_local_threshold_value=0 ;;
    INFO) runtime_local_threshold_value=1 ;;
    WARN) runtime_local_threshold_value=2 ;;
    ERROR) runtime_local_threshold_value=3 ;;
    *) runtime_local_threshold_value=1 ;;
    esac
    [ "${runtime_local_level_value}" -ge "${runtime_local_threshold_value}" ]
}

function runtime_json_escape {
    local runtime_local_value="${1:-}"

    runtime_local_value="${runtime_local_value//\\/\\\\}"
    runtime_local_value="${runtime_local_value//\"/\\\"}"
    runtime_local_value="${runtime_local_value//$'\n'/\\n}"
    runtime_local_value="${runtime_local_value//$'\r'/\\r}"
    runtime_local_value="${runtime_local_value//$'\t'/\\t}"
    runtime_local_value="${runtime_local_value//$'\b'/\\b}"
    runtime_local_value="${runtime_local_value//$'\f'/\\f}"
    runtime_local_value=$(printf '%s' "${runtime_local_value}" |
        LC_ALL=C tr -d '\000-\010\013\014\016-\037')
    printf '%s' "${runtime_local_value}"
}

function runtime_log {
    local runtime_local_level="${1:-INFO}"
    local runtime_local_message="${2:-}"
    local runtime_local_event="${3:-runtime.event}"
    local runtime_local_module="${4:-}"
    local runtime_local_timestamp
    local runtime_local_entry
    local runtime_local_json_message
    local runtime_local_json_event
    local runtime_local_json_module
    local runtime_local_json_run_id
    local runtime_local_json_namespace
    local runtime_local_json_command
    local runtime_local_json_flavor
    local runtime_local_json_profile
    local runtime_local_json_architecture

    runtime_log_should_emit "${runtime_local_level}" || return 0
    runtime_local_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ") || runtime_local_timestamp="unknown"
    if [ -z "${runtime_local_module}" ] && [ "${#RUNTIME_MODULE_STACK[@]}" -gt 0 ]; then
        runtime_local_module="${RUNTIME_MODULE_STACK[${#RUNTIME_MODULE_STACK[@]} - 1]}"
    fi

    if [ "${POSTINSTALL_LOG_FORMAT:-plain}" = "json" ]; then
        runtime_local_json_message=$(runtime_json_escape "${runtime_local_message}")
        runtime_local_json_event=$(runtime_json_escape "${runtime_local_event}")
        runtime_local_json_module=$(runtime_json_escape "${runtime_local_module}")
        runtime_local_json_run_id=$(runtime_json_escape "${RUNTIME_RUN_ID}")
        runtime_local_json_namespace=$(runtime_json_escape "${POSTINSTALL_STATE_NAMESPACE:-}")
        runtime_local_json_command=$(runtime_json_escape "${POSTINSTALL_COMMAND:-}")
        runtime_local_json_flavor=$(runtime_json_escape "${POSTINSTALL_FLAVOR:-}")
        runtime_local_json_profile=$(runtime_json_escape "${POSTINSTALL_PROFILE:-}")
        runtime_local_json_architecture=$(runtime_json_escape "${POSTINSTALL_ARCHITECTURE:-}")
        printf -v runtime_local_entry \
            '{"schema_version":1,"timestamp":"%s","level":"%s","event":"%s","message":"%s","run_id":"%s","namespace":"%s","module":"%s","context":{"command":"%s","flavor":"%s","profile":"%s","architecture":"%s"}}\n' \
            "${runtime_local_timestamp}" "${runtime_local_level^^}" \
            "${runtime_local_json_event}" "${runtime_local_json_message}" \
            "${runtime_local_json_run_id}" "${runtime_local_json_namespace}" \
            "${runtime_local_json_module}" "${runtime_local_json_command}" \
            "${runtime_local_json_flavor}" "${runtime_local_json_profile}" \
            "${runtime_local_json_architecture}"
    else
        runtime_local_message="${runtime_local_message//$'\n'/\\n}"
        runtime_local_message="${runtime_local_message//$'\r'/\\r}"
        printf -v runtime_local_entry '[%s] %-5s %s\n' \
            "${runtime_local_timestamp}" "${runtime_local_level}" "${runtime_local_message}"
    fi

    if [ -n "${POSTINSTALL_LOG_FILE:-}" ]; then
        if ! runtime_append_file "${POSTINSTALL_LOG_FILE}" "${runtime_local_entry}"; then
            printf 'runtime: unable to write log file: %s\n' "${POSTINSTALL_LOG_FILE}" >&2
        fi
    fi

    if runtime_is_true "${POSTINSTALL_LOG_STDOUT:-0}"; then
        if [ "${POSTINSTALL_LOG_FORMAT:-plain}" = "json" ] ||
            runtime_is_true "${POSTINSTALL_JSON:-0}"; then
            printf '%s' "${runtime_local_entry}" >&2
        else
            printf '%s' "${runtime_local_entry}"
        fi
    fi

    return 0
}

function runtime_format_command {
    local runtime_local_argument

    for runtime_local_argument in "$@"; do
        printf '%q ' "${runtime_local_argument}"
    done
    printf '\n'
}

function runtime_select_github_asset_by_suffix {
    local runtime_local_json="${1:-}"
    local runtime_local_suffix="${2:-}"
    local runtime_local_url
    local -a runtime_local_urls=()

    if [ -z "${runtime_local_json}" ] || [ -z "${runtime_local_suffix}" ]; then
        printf 'runtime: release asset selector requires a JSON file and suffix\n' >&2
        return 1
    fi
    mapfile -t runtime_local_urls < <(
        jq -r --arg suffix "${runtime_local_suffix}" \
            '.assets[] | select(.name | endswith($suffix)) | .browser_download_url // empty' \
            "${runtime_local_json}" 2>/dev/null
    )
    if [ "${#runtime_local_urls[@]}" -ne 1 ]; then
        printf 'runtime: expected exactly one release asset ending in %s; found %s\n' \
            "${runtime_local_suffix}" "${#runtime_local_urls[@]}" >&2
        return 1
    fi
    runtime_local_url="${runtime_local_urls[0]}"
    if [[ "${runtime_local_url}" != https://* ]]; then
        printf 'runtime: release asset URL is not HTTPS: %s\n' "${runtime_local_url}" >&2
        return 1
    fi
    printf '%s\n' "${runtime_local_url}"
    return 0
}

function runtime_select_latest_go_release {
    local runtime_local_architecture="${1:-}"
    local runtime_local_release
    local -a runtime_local_releases=()

    case "${runtime_local_architecture}" in
    linux-amd64 | linux-arm64) ;;
    *)
        printf 'runtime: unsupported Go release architecture: %s\n' \
            "${runtime_local_architecture}" >&2
        return 1
        ;;
    esac

    mapfile -t runtime_local_releases < <(
        grep -oP "go[0-9]+(?:\.[0-9]+){1,2}\.${runtime_local_architecture}\.tar\.gz" |
            LC_ALL=C sort -Vu
    )
    if [ "${#runtime_local_releases[@]}" -eq 0 ]; then
        printf 'runtime: unable to find a Go release for %s\n' \
            "${runtime_local_architecture}" >&2
        return 1
    fi

    runtime_local_release="${runtime_local_releases[${#runtime_local_releases[@]} - 1]}"
    printf 'dl/%s\n' "${runtime_local_release}"
    return 0
}

function runtime_run {
    if [ "$#" -eq 0 ]; then
        printf 'runtime: no command was provided\n' >&2
        return 1
    fi

    if runtime_is_dry_run; then
        runtime_log "INFO" "Dry run: $(runtime_format_command "$@")"
        return 0
    fi

    runtime_log "INFO" "Running: $(runtime_format_command "$@")"
    "$@"
    local runtime_local_status="${?}"
    runtime_log "INFO" "Command exited with status ${runtime_local_status}: $(runtime_format_command "$@")"
    return "${runtime_local_status}"
}

function runtime_run_in_directory {
    local runtime_local_directory="${1}"
    local runtime_local_status

    shift
    if [ "$#" -eq 0 ]; then
        printf 'runtime: no command was provided\n' >&2
        return 1
    fi

    if runtime_is_dry_run; then
        runtime_log "INFO" "Dry run in ${runtime_local_directory}: $(runtime_format_command "$@")"
        return 0
    fi

    runtime_log "INFO" "Running in ${runtime_local_directory}: $(runtime_format_command "$@")"
    (
        cd -- "${runtime_local_directory}" || exit 1
        "$@"
    )
    runtime_local_status="${?}"
    runtime_log "INFO" "Command exited with status ${runtime_local_status}: $(runtime_format_command "$@")"
    return "${runtime_local_status}"
}

function runtime_resolve_module {
    local runtime_local_module="${1}"
    local runtime_local_candidate
    local runtime_local_canonical

    if [ -z "${runtime_local_module}" ] ||
        [[ "${runtime_local_module}" == /* ]] ||
        [[ "${runtime_local_module}" == *\\* ]] ||
        [[ "${runtime_local_module}" =~ [[:cntrl:]] ]]; then
        printf 'runtime: invalid module path: %s\n' "${runtime_local_module}" >&2
        return 1
    fi

    case "/${runtime_local_module}/" in
    */../*)
        printf 'runtime: invalid module path: %s\n' "${runtime_local_module}" >&2
        return 1
        ;;
    esac

    runtime_local_candidate="${SCRIPT_PATH}/${runtime_local_module}"
    if [ ! -f "${runtime_local_candidate}" ] || [ -L "${runtime_local_candidate}" ]; then
        printf 'runtime: module is not a regular file: %s\n' "${runtime_local_module}" >&2
        return 1
    fi

    runtime_local_canonical=$(realpath -e -- "${runtime_local_candidate}") || return 1
    if [[ "${runtime_local_canonical}" != "${SCRIPT_PATH}/"* ]]; then
        printf 'runtime: module resolves outside the repository: %s\n' "${runtime_local_module}" >&2
        return 1
    fi

    printf '%s\n' "${runtime_local_canonical}"
    return 0
}

function runtime_module_checksum {
    local runtime_local_module="${1}"
    local runtime_local_path="${2}"
    local runtime_local_dependency
    local runtime_local_dependency_relative
    local runtime_local_dependency_module
    local runtime_local_dependency_modules=""
    local runtime_local_checksum
    local runtime_local_profile_digest=""
    local -a runtime_local_dependencies=()
    local -a runtime_local_dependency_modules_list=()

    case "${runtime_local_module}" in
    common/distrobox-installation.sh | common/direnv-installation.sh | common/starship-installation.sh)
        runtime_local_dependencies+=("${SCRIPT_PATH}/common/rolling-install.sh")
        ;;
    workstation/home-configuration.sh | silverblue/home-configuration.sh)
        # Both home-configuration modules consume the shared helper generator
        # and validation functions, so changes to either must invalidate their
        # saved resume fingerprints.
        runtime_local_dependencies+=(
            "${SCRIPT_PATH}/common/home-helpers.sh"
            "${SCRIPT_PATH}/common/validation.sh"
        )
        ;;
    extras/additional-tools.sh)
        runtime_local_dependencies=(
            "${SCRIPT_PATH}/extras/tools-list.sh"
            "${SCRIPT_PATH}/extras/tools-download.sh"
            "${SCRIPT_PATH}/extras/tools-unpacking.sh"
            "${SCRIPT_PATH}/extras/tools-deployment.sh"
            "${SCRIPT_PATH}/extras/archive-extract.py"
            "${SCRIPT_PATH}/extras/manifest_url.py"
            "${SCRIPT_PATH}/extras/tar_guard.py"
            "${SCRIPT_PATH}/extras/tools-manifest.json"
        )
        for runtime_local_dependency in "${SCRIPT_PATH}/extras/"*-download.sh; do
            if [ -f "${runtime_local_dependency}" ] && [ ! -L "${runtime_local_dependency}" ]; then
                runtime_local_dependencies+=("${runtime_local_dependency}")
            fi
        done
        ;;
    esac

    if declare -F runtime_module_dependency_closure >/dev/null 2>&1; then
        runtime_local_dependency_modules=$(runtime_module_dependency_closure \
            "${POSTINSTALL_FLAVOR}" "${runtime_local_module}") || return 1
        if [ -n "${runtime_local_dependency_modules}" ]; then
            mapfile -t runtime_local_dependency_modules_list \
                <<<"${runtime_local_dependency_modules}"
            for runtime_local_dependency_module in \
                "${runtime_local_dependency_modules_list[@]}"; do
                runtime_local_dependencies+=("${SCRIPT_PATH}/${runtime_local_dependency_module}")
            done
        fi
    fi

    for runtime_local_dependency in "${runtime_local_dependencies[@]}"; do
        if [ ! -f "${runtime_local_dependency}" ] || [ -L "${runtime_local_dependency}" ]; then
            printf 'runtime: module dependency is not a regular file: %s\n' \
                "${runtime_local_dependency}" >&2
            return 1
        fi
    done

    if [ -n "${POSTINSTALL_PROFILE_FILE:-}" ] &&
        [ -f "${POSTINSTALL_PROFILE_FILE}" ] &&
        [ ! -L "${POSTINSTALL_PROFILE_FILE}" ]; then
        runtime_local_profile_digest=$(sha256sum -- "${POSTINSTALL_PROFILE_FILE}" | cut -d' ' -f1) || return 1
    fi

    runtime_local_checksum=$(
        {
            printf 'state-schema\t%s\n' "${RUNTIME_STATE_SCHEMA_VERSION}"
            printf 'module\t%s\n' "${runtime_local_module}"
            printf 'flavor\t%s\n' "${POSTINSTALL_FLAVOR:-}"
            printf 'architecture\t%s\n' "${POSTINSTALL_ARCHITECTURE:-}"
            printf 'profile\t%s\n' "${runtime_local_profile_digest}"
            printf 'file\t%s\n' "${runtime_local_module}"
            sha256sum -- "${runtime_local_path}" | cut -d' ' -f1
            if [ "${runtime_local_module}" = "extras/additional-tools.sh" ]; then
                printf 'tool-selection\t%s\n' "${POSTINSTALL_SELECTED_TOOLS:-}"
                printf 'tool-mode\t%s\n' "${POSTINSTALL_TOOL_SELECTION_MODE:-}"
                if [ "${POSTINSTALL_TOOL_SELECTION_MODE:-interactive}" = "interactive" ]; then
                    printf 'interactive-selection\t%s\n' "${CLI_TOOLS_SELECTION:-}"
                fi
            fi
            for runtime_local_dependency in "${runtime_local_dependencies[@]}"; do
                runtime_local_dependency_relative="${runtime_local_dependency#${SCRIPT_PATH}/}"
                printf 'dependency\t%s\n' "${runtime_local_dependency_relative}"
                sha256sum -- "${runtime_local_dependency}" | cut -d' ' -f1
            done
        } | sha256sum
    ) || return 1
    printf '%s\n' "${runtime_local_checksum%% *}"
}

function runtime_state_key {
    local runtime_local_namespace="${POSTINSTALL_STATE_NAMESPACE:-default}"
    local runtime_local_module="${1}"

    printf '%s:%s\n' "${runtime_local_namespace}" "${runtime_local_module}"
}

function runtime_state_value_key {
    local runtime_local_namespace="${POSTINSTALL_STATE_NAMESPACE:-default}"
    local runtime_local_module="${1}"
    local runtime_local_name="${2}"

    printf '%s:%s:%s\n' \
        "${runtime_local_namespace}" "${runtime_local_module}" "${runtime_local_name}"
}

function runtime_state_append_record {
    local runtime_local_type="${1}"
    local runtime_local_key="${2}"
    local runtime_local_value="${3}"
    local runtime_local_timestamp
    local runtime_local_entry

    case "${runtime_local_type}" in
    module | value) ;;
    *)
        printf 'runtime: invalid state record type: %s\n' "${runtime_local_type}" >&2
        return 1
        ;;
    esac

    if [ -z "${runtime_local_key}" ] || [ -z "${runtime_local_value}" ]; then
        printf 'runtime: state records require a key and value\n' >&2
        return 1
    fi

    if [[ "${runtime_local_key}" == *$'\t'* ]] ||
        [[ "${runtime_local_value}" == *$'\t'* ]] ||
        [[ "${runtime_local_value}" == *$'\n'* ]] ||
        [[ "${runtime_local_value}" == *$'\r'* ]]; then
        printf 'runtime: state records cannot contain tabs or newlines\n' >&2
        return 1
    fi

    if [ -L "${POSTINSTALL_STATE_FILE}" ]; then
        printf 'runtime: state file must not be a symbolic link: %s\n' "${POSTINSTALL_STATE_FILE}" >&2
        return 1
    fi
    if [ -e "${POSTINSTALL_STATE_FILE}" ] && [ ! -f "${POSTINSTALL_STATE_FILE}" ]; then
        printf 'runtime: state file is not a regular file: %s\n' "${POSTINSTALL_STATE_FILE}" >&2
        return 1
    fi

    runtime_local_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ") || runtime_local_timestamp="unknown"
    printf -v runtime_local_entry '%s\t%s\t%s\t%s\n' \
        "${runtime_local_type}" "${runtime_local_key}" "${runtime_local_value}" \
        "${runtime_local_timestamp}"
    if ! runtime_append_file "${POSTINSTALL_STATE_FILE}" "${runtime_local_entry}"; then
        printf 'runtime: unable to update state file: %s\n' "${POSTINSTALL_STATE_FILE}" >&2
        return 1
    fi
    return 0
}

function runtime_state_record_is_valid {
    local runtime_local_line="${1:-}"
    local runtime_local_type
    local runtime_local_key
    local runtime_local_value
    local runtime_local_timestamp
    local -a runtime_local_fields=()

    IFS=$'\t' read -r -a runtime_local_fields <<<"${runtime_local_line}"
    [ "${#runtime_local_fields[@]}" -eq 4 ] || return 1

    runtime_local_type="${runtime_local_fields[0]}"
    runtime_local_key="${runtime_local_fields[1]}"
    runtime_local_value="${runtime_local_fields[2]}"
    runtime_local_timestamp="${runtime_local_fields[3]}"

    [ -n "${runtime_local_type}" ] &&
        [ -n "${runtime_local_key}" ] &&
        [ -n "${runtime_local_value}" ] &&
        [ -n "${runtime_local_timestamp}" ] || return 1

    case "${runtime_local_type}" in
    module | value) ;;
    *) return 1 ;;
    esac

    [[ "${runtime_local_timestamp}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

function runtime_state_is_complete {
    local runtime_local_module="${1}"
    local runtime_local_checksum="${2}"
    local runtime_local_key
    local runtime_local_line
    local runtime_local_state_type
    local runtime_local_state_key
    local runtime_local_state_value
    local runtime_local_state_timestamp
    local runtime_local_latest_checksum=""
    local runtime_local_content

    if [ -z "${POSTINSTALL_STATE_FILE:-}" ]; then
        return 1
    fi
    if [ ! -e "${POSTINSTALL_STATE_FILE}" ] && [ ! -L "${POSTINSTALL_STATE_FILE}" ]; then
        return 1
    fi

    if ! runtime_local_content=$(runtime_read_file "${POSTINSTALL_STATE_FILE}"); then
        printf 'runtime: state file is unsafe: %s\n' "${POSTINSTALL_STATE_FILE}" >&2
        return 2
    fi

    runtime_local_key=$(runtime_state_key "${runtime_local_module}")
    while IFS= read -r runtime_local_line || [ -n "${runtime_local_line}" ]; do
        if ! runtime_state_record_is_valid "${runtime_local_line}"; then
            printf 'runtime: state file contains a malformed record\n' >&2
            return 2
        fi
        IFS=$'\t' read -r runtime_local_state_type runtime_local_state_key \
            runtime_local_state_value runtime_local_state_timestamp \
            <<<"${runtime_local_line}"
        if [ "${runtime_local_state_type}" = "module" ] &&
            [ "${runtime_local_state_key}" = "${runtime_local_key}" ]; then
            runtime_local_latest_checksum="${runtime_local_state_value}"
        fi
    done <<<"${runtime_local_content}"

    if [ -n "${runtime_local_latest_checksum}" ] &&
        [ "${runtime_local_latest_checksum}" = "${runtime_local_checksum}" ]; then
        return 0
    fi

    return 1
}

function runtime_invalidate_module {
    local runtime_local_module="${1}"
    local runtime_local_key

    if [ -z "${POSTINSTALL_STATE_FILE:-}" ]; then
        return 0
    fi

    runtime_local_key=$(runtime_state_key "${runtime_local_module}")
    runtime_state_append_record "module" "${runtime_local_key}" "-"
}

function runtime_restore_module_state {
    local runtime_local_module="${1}"
    local runtime_local_name
    local runtime_local_key
    local runtime_local_line
    local runtime_local_state_type
    local runtime_local_state_key
    local runtime_local_state_value
    local runtime_local_state_timestamp
    local runtime_local_latest_value
    local runtime_local_found
    local runtime_local_content

    shift
    if [ "$#" -eq 0 ]; then
        return 0
    fi

    if [ -z "${POSTINSTALL_STATE_FILE:-}" ]; then
        return 1
    fi
    if [ ! -e "${POSTINSTALL_STATE_FILE}" ] && [ ! -L "${POSTINSTALL_STATE_FILE}" ]; then
        return 1
    fi
    if ! runtime_local_content=$(runtime_read_file "${POSTINSTALL_STATE_FILE}"); then
        printf 'runtime: state file is unsafe: %s\n' "${POSTINSTALL_STATE_FILE}" >&2
        return 1
    fi

    for runtime_local_name in "$@"; do
        if ! [[ "${runtime_local_name}" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
            printf 'runtime: invalid state variable name: %s\n' "${runtime_local_name}" >&2
            return 1
        fi

        runtime_local_key=$(runtime_state_value_key \
            "${runtime_local_module}" "${runtime_local_name}")
        runtime_local_latest_value=""
        runtime_local_found=0
        while IFS= read -r runtime_local_line || [ -n "${runtime_local_line}" ]; do
            if ! runtime_state_record_is_valid "${runtime_local_line}"; then
                printf 'runtime: state file contains a malformed record\n' >&2
                return 2
            fi
            IFS=$'\t' read -r runtime_local_state_type runtime_local_state_key \
                runtime_local_state_value runtime_local_state_timestamp \
                <<<"${runtime_local_line}"
            if [ "${runtime_local_state_type}" = "value" ] &&
                [ "${runtime_local_state_key}" = "${runtime_local_key}" ]; then
                runtime_local_latest_value="${runtime_local_state_value}"
                runtime_local_found=1
            fi
        done <<<"${runtime_local_content}"

        if [ "${runtime_local_found}" -ne 1 ]; then
            printf 'runtime: saved state for %s is missing\n' "${runtime_local_name}" >&2
            return 1
        fi
        declare -g "${runtime_local_name}=${runtime_local_latest_value}"
    done

    return 0
}

function runtime_capture_module_state {
    local runtime_local_module="${1}"
    local runtime_local_name
    local runtime_local_key
    local runtime_local_value

    shift
    if [ "$#" -eq 0 ] || [ -z "${POSTINSTALL_STATE_FILE:-}" ]; then
        return 0
    fi

    for runtime_local_name in "$@"; do
        if ! [[ "${runtime_local_name}" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
            printf 'runtime: invalid state variable name: %s\n' "${runtime_local_name}" >&2
            return 1
        fi
        if ! declare -p "${runtime_local_name}" >/dev/null 2>&1; then
            printf 'runtime: state variable %s was not initialized\n' "${runtime_local_name}" >&2
            return 1
        fi

        runtime_local_key=$(runtime_state_value_key \
            "${runtime_local_module}" "${runtime_local_name}")
        runtime_local_value="${!runtime_local_name}"
        if ! runtime_state_append_record "value" "${runtime_local_key}" "${runtime_local_value}"; then
            return 1
        fi
    done

    return 0
}

function runtime_mark_module_complete {
    local runtime_local_module="${1}"
    local runtime_local_checksum="${2}"
    local runtime_local_key

    shift 2
    if [ -z "${POSTINSTALL_STATE_FILE:-}" ]; then
        return 0
    fi

    if ! runtime_capture_module_state "${runtime_local_module}" "$@"; then
        return 1
    fi

    runtime_local_key=$(runtime_state_key "${runtime_local_module}")
    runtime_state_append_record "module" "${runtime_local_key}" "${runtime_local_checksum}"
}

function runtime_elapsed_seconds {
    local runtime_local_now=0

    if [ "${RUNTIME_START_EPOCH}" -le 0 ]; then
        printf '%s\n' "0"
        return 0
    fi
    runtime_local_now=$(date +%s) || runtime_local_now="${RUNTIME_START_EPOCH}"
    if [ "${runtime_local_now}" -lt "${RUNTIME_START_EPOCH}" ]; then
        runtime_local_now="${RUNTIME_START_EPOCH}"
    fi
    printf '%s\n' "$((runtime_local_now - RUNTIME_START_EPOCH))"
}

function runtime_format_duration {
    local runtime_local_seconds="${1:-0}"
    local runtime_local_hours
    local runtime_local_minutes
    local runtime_local_remainder

    if ! [[ "${runtime_local_seconds}" =~ ^[0-9]+$ ]]; then
        runtime_local_seconds=0
    fi
    runtime_local_hours=$((runtime_local_seconds / 3600))
    runtime_local_minutes=$(((runtime_local_seconds % 3600) / 60))
    runtime_local_remainder=$((runtime_local_seconds % 60))
    if [ "${runtime_local_hours}" -gt 0 ]; then
        printf '%dh %dm %ds\n' \
            "${runtime_local_hours}" "${runtime_local_minutes}" \
            "${runtime_local_remainder}"
        return 0
    fi
    if [ "${runtime_local_minutes}" -gt 0 ]; then
        printf '%dm %ds\n' "${runtime_local_minutes}" "${runtime_local_remainder}"
        return 0
    fi
    printf '%ds\n' "${runtime_local_remainder}"
}

function runtime_emit_result_summary {
    local runtime_local_operation="${1:-Operation}"
    local runtime_local_total="${2:-0}"
    local runtime_local_completed="${3:-0}"
    local runtime_local_skipped="${4:-0}"
    local runtime_local_failed="${5:-0}"
    local runtime_local_duration
    local runtime_local_message
    local runtime_local_status=0

    if [ "${RUNTIME_SUMMARY_RENDERED}" -eq 1 ]; then
        return 0
    fi
    runtime_local_duration=$(runtime_format_duration "$(runtime_elapsed_seconds)") ||
        return 1
    runtime_local_message="${runtime_local_operation}: ${runtime_local_completed} completed, ${runtime_local_skipped} skipped, ${runtime_local_failed} failed in ${runtime_local_duration}."
    if declare -F ui_summary >/dev/null; then
        if ui_summary "${runtime_local_message}"; then
            runtime_local_status=0
        else
            runtime_local_status="${?}"
        fi
    else
        if printf '%s\n' "${runtime_local_message}"; then
            runtime_local_status=0
        else
            runtime_local_status="${?}"
        fi
    fi
    if [ "${runtime_local_status}" -ne 0 ]; then
        return "${runtime_local_status}"
    fi
    RUNTIME_SUMMARY_RENDERED=1
    return 0
}

function runtime_render_result_summary {
    local runtime_local_operation="${1:-Operation}"
    local runtime_local_total="${2:-0}"
    local runtime_local_completed="${3:-0}"
    local runtime_local_skipped="${4:-0}"
    local runtime_local_failed="${5:-0}"

    if [ "${RUNTIME_SUMMARY_RENDERED}" -eq 1 ]; then
        return 0
    fi

    # The root flow requests its final summary immediately before the EXIT
    # trap. Keep that request pending so cleanup callbacks can determine the
    # terminal outcome before a success summary is rendered.
    if [ "${RUNTIME_INITIALIZED}" -eq 1 ] && [ "${RUNTIME_CLEANED}" -ne 1 ]; then
        RUNTIME_SUMMARY_PENDING=1
        RUNTIME_SUMMARY_OPERATION="${runtime_local_operation}"
        RUNTIME_SUMMARY_TOTAL="${runtime_local_total}"
        RUNTIME_SUMMARY_COMPLETED="${runtime_local_completed}"
        RUNTIME_SUMMARY_SKIPPED="${runtime_local_skipped}"
        RUNTIME_SUMMARY_FAILED="${runtime_local_failed}"
        return 0
    fi

    if [ "${RUNTIME_CLEANED}" -eq 1 ] &&
        [ "${RUNTIME_OPERATION_FAILED}" -eq 1 ]; then
        runtime_local_operation="${RUNTIME_OPERATION_LABEL} failed"
        runtime_local_total="${RUNTIME_MODULE_TOTAL}"
        runtime_local_completed="${RUNTIME_MODULE_COMPLETED}"
        runtime_local_skipped="${RUNTIME_MODULE_SKIPPED}"
        runtime_local_failed=$((RUNTIME_MODULE_FAILED + RUNTIME_OPERATION_FAILED))
    fi

    runtime_emit_result_summary \
        "${runtime_local_operation}" \
        "${runtime_local_total}" \
        "${runtime_local_completed}" \
        "${runtime_local_skipped}" \
        "${runtime_local_failed}"
}

function runtime_render_module_progress {
    local runtime_local_module="${1:-unknown}"
    local runtime_local_state="${2:-}"
    local runtime_local_position
    local runtime_local_message

    if [ "${RUNTIME_MODULE_TOTAL}" -gt 0 ]; then
        runtime_local_position=$((RUNTIME_MODULE_COMPLETED + \
            RUNTIME_MODULE_SKIPPED + RUNTIME_MODULE_FAILED + 1))
        runtime_local_message="Module ${runtime_local_position}/${RUNTIME_MODULE_TOTAL}: ${runtime_local_module}"
    else
        runtime_local_position=$((RUNTIME_MODULE_COMPLETED + \
            RUNTIME_MODULE_SKIPPED + RUNTIME_MODULE_FAILED + 1))
        runtime_local_message="Module ${runtime_local_position}: ${runtime_local_module}"
    fi
    if [ -n "${runtime_local_state}" ]; then
        runtime_local_message+=" (${runtime_local_state})"
    fi
    if declare -F ui_step >/dev/null; then
        ui_step "${runtime_local_message}" || return $?
    else
        printf 'info: %s\n' "${runtime_local_message}" || return $?
    fi
    RUNTIME_MODULE_CURRENT="${runtime_local_position}"
    return 0
}

function runtime_record_module_failure {
    local runtime_local_status="${1:-1}"
    local runtime_local_module="${2:-unknown}"

    if [ "${RUNTIME_MODULE_FAILED}" -eq 0 ] ||
        [ "${RUNTIME_MODULE_FAILED_NAME}" != "${runtime_local_module}" ]; then
        RUNTIME_MODULE_FAILED=$((RUNTIME_MODULE_FAILED + 1))
        RUNTIME_MODULE_FAILED_NAME="${runtime_local_module}"
    fi
    RUNTIME_MODULE_FAILURE_STATUS="${runtime_local_status}"
    RUNTIME_MODULE_FAILURE_MODULE="${runtime_local_module}"
    return 0
}

function runtime_module_fail {
    local runtime_local_status="${1:-1}"
    local runtime_local_module="${2:-unknown}"

    runtime_record_module_failure "${runtime_local_status}" "${runtime_local_module}"
    if [ "${RUNTIME_MODULE_FIRST_ERROR_STATUS}" -eq 0 ]; then
        RUNTIME_MODULE_FIRST_ERROR_STATUS="${runtime_local_status}"
        RUNTIME_MODULE_FIRST_ERROR_COMMAND="runtime_module_fail ${runtime_local_module}"
    fi
    runtime_log "ERROR" "Module '${runtime_local_module}' failed with status ${runtime_local_status}." || true

    # Module failures are fatal to the installer. Exiting here also prevents
    # a parent module from ignoring a failed child and then reporting success.
    exit "${runtime_local_status}"
}

function runtime_run_module {
    local runtime_local_module="${1}"
    local runtime_local_effect="${2:-mutating}"
    local runtime_local_path
    local runtime_local_checksum
    local runtime_local_status
    local runtime_local_error_status
    local runtime_local_state_status
    local runtime_local_restore_status
    local runtime_local_dry_run=0
    local -a runtime_local_state_names=()

    if [ "$#" -ge 2 ]; then
        shift 2
    else
        shift
    fi
    runtime_local_state_names=("$@")

    if [ "${RUNTIME_MODULE_FAILURE_STATUS}" -ne 0 ]; then
        return "${RUNTIME_MODULE_FAILURE_STATUS}"
    fi

    case "${runtime_local_effect}" in
    mutating | read-only | orchestrator) ;;
    *)
        printf 'runtime: invalid module effect: %s\n' "${runtime_local_effect}" >&2
        runtime_module_fail 1 "${runtime_local_module}" || return $?
        ;;
    esac

    if [ "${runtime_local_effect}" != "orchestrator" ] &&
        ! runtime_profile_allows_module "${runtime_local_module}"; then
        runtime_render_module_progress "${runtime_local_module}" "skipped" ||
            runtime_module_fail 1 "${runtime_local_module}" || return $?
        RUNTIME_MODULE_SKIPPED=$((RUNTIME_MODULE_SKIPPED + 1))
        runtime_log "INFO" "Skipping module '${runtime_local_module}' because it is not selected by the active profile." \
            "module.skip" "${runtime_local_module}"
        return 0
    fi

    if ! runtime_local_path=$(runtime_resolve_module "${runtime_local_module}"); then
        runtime_log "ERROR" "Unable to resolve module '${runtime_local_module}'."
        runtime_module_fail 1 "${runtime_local_module}" || return $?
    fi

    if ! runtime_local_checksum=$(runtime_module_checksum \
        "${runtime_local_module}" "${runtime_local_path}"); then
        runtime_log "ERROR" "Unable to checksum module '${runtime_local_module}'."
        runtime_module_fail 1 "${runtime_local_module}" || return $?
    fi

    if runtime_is_resume &&
        [ "${runtime_local_module}" = "extras/additional-tools.sh" ] &&
        [ "${POSTINSTALL_TOOL_SELECTION_MODE:-interactive}" = "interactive" ]; then
        runtime_local_restore_status=0
        if runtime_restore_module_state "${runtime_local_module}" CLI_TOOLS_SELECTION; then
            runtime_local_checksum=$(runtime_module_checksum \
                "${runtime_local_module}" "${runtime_local_path}") ||
                runtime_module_fail 1 "${runtime_local_module}" || return $?
        else
            runtime_local_restore_status="${?}"
            if [ "${runtime_local_restore_status}" -eq 2 ]; then
                runtime_log "ERROR" "The saved state for module '${runtime_local_module}' is invalid or unsafe."
                runtime_module_fail 1 "${runtime_local_module}" || return $?
            fi
        fi
    fi

    if runtime_is_dry_run; then
        runtime_local_dry_run=1
        if [ "${runtime_local_effect}" = "mutating" ]; then
            runtime_render_module_progress "${runtime_local_module}" "dry run" ||
                runtime_module_fail 1 "${runtime_local_module}" || return $?
            runtime_log "INFO" "Dry run: would run module '${runtime_local_module}'." ||
                runtime_module_fail 1 "${runtime_local_module}" || return $?
            RUNTIME_MODULE_SKIPPED=$((RUNTIME_MODULE_SKIPPED + 1))
            return 0
        fi
    fi

    if [ "${runtime_local_effect}" = "mutating" ] && runtime_is_resume; then
        runtime_local_state_status=0
        runtime_state_is_complete "${runtime_local_module}" "${runtime_local_checksum}" ||
            runtime_local_state_status="${?}"
        if [ "${runtime_local_state_status}" -eq 2 ]; then
            runtime_log "ERROR" "The saved state for module '${runtime_local_module}' is invalid or unsafe."
            runtime_module_fail 1 "${runtime_local_module}" || return $?
        fi
        if [ "${runtime_local_state_status}" -eq 0 ]; then
            runtime_local_restore_status=0
            if runtime_restore_module_state "${runtime_local_module}" \
                "${runtime_local_state_names[@]}"; then
                runtime_render_module_progress "${runtime_local_module}" \
                    "already completed" ||
                    runtime_module_fail 1 "${runtime_local_module}" || return $?
                RUNTIME_MODULE_SKIPPED=$((RUNTIME_MODULE_SKIPPED + 1))
                runtime_log "INFO" "Resume: skipping completed module '${runtime_local_module}'." ||
                    runtime_module_fail 1 "${runtime_local_module}" || return $?
                return 0
            else
                runtime_local_restore_status="${?}"
            fi
            if [ "${runtime_local_restore_status}" -eq 2 ]; then
                runtime_log "ERROR" "The saved state for module '${runtime_local_module}' is invalid or unsafe."
                runtime_module_fail 1 "${runtime_local_module}" || return $?
            fi
            runtime_log "WARN" "Resume: saved state for '${runtime_local_module}' is incomplete; the module will run again."
        fi
    fi

    if [ "${runtime_local_effect}" = "mutating" ]; then
        if ! runtime_invalidate_module "${runtime_local_module}"; then
            runtime_log "ERROR" "Unable to invalidate the saved state for '${runtime_local_module}'."
            runtime_module_fail 1 "${runtime_local_module}" || return $?
        fi
    fi

    if [ "${runtime_local_effect}" != "orchestrator" ]; then
        runtime_render_module_progress "${runtime_local_module}" ||
            runtime_module_fail 1 "${runtime_local_module}" || return $?
    fi
    runtime_log "INFO" "Starting module '${runtime_local_module}'." \
        "runtime.module.started" "${runtime_local_module}" ||
        runtime_module_fail 1 "${runtime_local_module}" || return $?
    runtime_module_error_begin "${runtime_local_module}"
    source "${runtime_local_path}"
    runtime_local_status="${?}"
    runtime_local_error_status=0
    runtime_module_error_end || runtime_local_error_status="${?}"
    if [ "${runtime_local_error_status}" -ne 0 ]; then
        runtime_local_status="${runtime_local_error_status}"
    fi

    if [ "${runtime_local_status}" -ne 0 ]; then
        runtime_module_fail "${runtime_local_status}" "${runtime_local_module}" || return $?
    fi

    if [ "${runtime_local_effect}" = "orchestrator" ]; then
        runtime_log "INFO" "Completed orchestrator '${runtime_local_module}'." \
            "runtime.module.completed" "${runtime_local_module}"
        return 0
    fi

    if [ "${runtime_local_effect}" = "read-only" ]; then
        if [ "${runtime_local_dry_run}" -eq 1 ]; then
            runtime_log "INFO" "Dry run: completed read-only module '${runtime_local_module}'." \
                "runtime.module.completed" "${runtime_local_module}" ||
                runtime_module_fail 1 "${runtime_local_module}" || return $?
        else
            runtime_log "INFO" "Completed read-only module '${runtime_local_module}'." \
                "runtime.module.completed" "${runtime_local_module}"
        fi
        RUNTIME_MODULE_COMPLETED=$((RUNTIME_MODULE_COMPLETED + 1))
        return 0
    fi

    if [ "${runtime_local_module}" = "extras/additional-tools.sh" ] &&
        [ "${POSTINSTALL_TOOL_SELECTION_MODE:-interactive}" = "interactive" ]; then
        runtime_local_checksum=$(runtime_module_checksum \
            "${runtime_local_module}" "${runtime_local_path}") ||
            runtime_module_fail 1 "${runtime_local_module}" || return $?
    fi

    if ! runtime_mark_module_complete \
        "${runtime_local_module}" "${runtime_local_checksum}" "${runtime_local_state_names[@]}"; then
        runtime_log "ERROR" "Module '${runtime_local_module}' completed but its state could not be recorded."
        runtime_module_fail 1 "${runtime_local_module}" || return $?
    fi

    runtime_log "INFO" "Completed module '${runtime_local_module}'." \
        "runtime.module.completed" "${runtime_local_module}"
    RUNTIME_MODULE_COMPLETED=$((RUNTIME_MODULE_COMPLETED + 1))
    return 0
}
