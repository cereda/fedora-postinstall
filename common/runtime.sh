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
declare -g RUNTIME_EXPECTED_FAILURE=0
declare -g RUNTIME_MODULE_FAILURE_STATUS=0
declare -g RUNTIME_MODULE_FAILURE_MODULE=""
declare -ga RUNTIME_MODULE_ERROR_STACK=()
declare -ga RUNTIME_MODULE_STACK=()

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

function runtime_module_debug_handler {
    if [ "${RUNTIME_MODULE_ACTIVE_DEPTH}" -gt 0 ] &&
        [ "${RUNTIME_EXPECTED_FAILURE}" -eq 1 ] &&
        [ "${BASH_COMMAND}" != "return 1" ]; then
        RUNTIME_EXPECTED_FAILURE=0
    fi
    return 0
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

    # A declined interactive question returns status 1 by design. The question
    # helper marks that specific return so it is not treated as a module error.
    if [ "${RUNTIME_EXPECTED_FAILURE}" -eq 1 ] &&
        [ "${runtime_local_command}" = "return 1" ]; then
        RUNTIME_EXPECTED_FAILURE=0
        return 0
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
    runtime_log "ERROR" "Command '${runtime_local_command}' failed with status ${runtime_local_status}."

    # Stop at the first unhandled failure. Continuing would allow later
    # commands to run against a partially completed system state.
    exit "${runtime_local_status}"
}

function runtime_module_error_begin {
    local runtime_local_module="${1:-unknown}"

    RUNTIME_MODULE_ERROR_STACK+=("${RUNTIME_MODULE_ERROR_COUNT}")
    RUNTIME_MODULE_STACK+=("${runtime_local_module}")
    RUNTIME_MODULE_ACTIVE_DEPTH=$((RUNTIME_MODULE_ACTIVE_DEPTH + 1))
    RUNTIME_EXPECTED_FAILURE=0
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
    RUNTIME_EXPECTED_FAILURE=0

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

    RUNTIME_INITIALIZED=1
    set -E
    set -o pipefail
    trap 'runtime_module_debug_handler' DEBUG
    trap 'runtime_module_error_handler' ERR
    trap 'runtime_cleanup' EXIT
    trap 'runtime_handle_signal 130 INT' INT
    trap 'runtime_handle_signal 143 TERM' TERM
    trap 'runtime_handle_signal 129 HUP' HUP
    runtime_log "INFO" "Runtime initialized." || return 1
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

    if [ -z "${RUNTIME_CLEANUP_CALLBACKS[${runtime_local_name}]:-}" ]; then
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

function runtime_handle_signal {
    local runtime_local_status="${1:-1}"
    local runtime_local_name="${2:-signal}"

    if [ "${RUNTIME_CRITICAL_DEPTH}" -gt 0 ]; then
        RUNTIME_PENDING_SIGNAL_STATUS="${runtime_local_status}"
        RUNTIME_PENDING_SIGNAL_NAME="${runtime_local_name}"
        runtime_log "WARN" "Received ${runtime_local_name}; deferring shutdown until the current operation completes."
        return 0
    fi

    runtime_log "WARN" "Received ${runtime_local_name}; shutting down."
    exit "${runtime_local_status}"
}

function runtime_cleanup {
    local runtime_local_status="${?}"
    local runtime_local_index
    local runtime_local_name
    local runtime_local_callback

    if [ "${RUNTIME_CLEANING}" -eq 1 ] || [ "${RUNTIME_CLEANED}" -eq 1 ]; then
        return "${runtime_local_status}"
    fi
    RUNTIME_CLEANING=1

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
            "${runtime_local_callback}" || runtime_log "WARN" "Cleanup callback '${runtime_local_name}' failed."
        fi
    done

    RUNTIME_CLEANING=0
    RUNTIME_CLEANED=1
    return "${runtime_local_status}"
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

function runtime_log {
    local runtime_local_level="${1:-INFO}"
    local runtime_local_message="${2:-}"
    local runtime_local_timestamp
    local runtime_local_entry

    runtime_local_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ") || runtime_local_timestamp="unknown"
    runtime_local_message="${runtime_local_message//$'\n'/\\n}"
    runtime_local_message="${runtime_local_message//$'\r'/\\r}"

    if [ -n "${POSTINSTALL_LOG_FILE:-}" ]; then
        printf -v runtime_local_entry '[%s] %-5s %s\n' \
            "${runtime_local_timestamp}" "${runtime_local_level}" "${runtime_local_message}"
        if ! runtime_append_file "${POSTINSTALL_LOG_FILE}" "${runtime_local_entry}"; then
            printf 'runtime: unable to write log file: %s\n' "${POSTINSTALL_LOG_FILE}" >&2
        fi
    fi

    if runtime_is_true "${POSTINSTALL_LOG_STDOUT:-0}"; then
        printf '[%s] %-5s %s\n' \
            "${runtime_local_timestamp}" "${runtime_local_level}" "${runtime_local_message}"
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
    local runtime_local_checksum
    local -a runtime_local_dependencies=()

    case "${runtime_local_module}" in
    common/flatpaks-installation.sh)
        runtime_local_dependencies=(
            "${SCRIPT_PATH}/common/flatpaks-to-install.sh"
        )
        ;;
    common/fonts-installation.sh)
        runtime_local_dependencies=(
            "${SCRIPT_PATH}/common/fonts-to-install.sh"
        )
        ;;
    common/terminal-colors.sh)
        runtime_local_dependencies=(
            "${SCRIPT_PATH}/common/color-themes.sh"
        )
        ;;
    workstation/package-cleanup.sh)
        runtime_local_dependencies=(
            "${SCRIPT_PATH}/workstation/packages-to-remove.sh"
        )
        ;;
    workstation/useful-packages.sh)
        runtime_local_dependencies=(
            "${SCRIPT_PATH}/workstation/packages-to-install.sh"
        )
        ;;
    silverblue/useful-packages.sh)
        runtime_local_dependencies=(
            "${SCRIPT_PATH}/silverblue/packages-to-install.sh"
        )
        ;;
    extras/additional-tools.sh)
        runtime_local_dependencies=(
            "${SCRIPT_PATH}/extras/tools-list.sh"
            "${SCRIPT_PATH}/extras/tools-download.sh"
            "${SCRIPT_PATH}/extras/tools-unpacking.sh"
            "${SCRIPT_PATH}/extras/tools-deployment.sh"
            "${SCRIPT_PATH}/extras/archive-extract.py"
            "${SCRIPT_PATH}/extras/tools-manifest.json"
        )
        for runtime_local_dependency in "${SCRIPT_PATH}/extras/"*-download.sh; do
            if [ -f "${runtime_local_dependency}" ] && [ ! -L "${runtime_local_dependency}" ]; then
                runtime_local_dependencies+=("${runtime_local_dependency}")
            fi
        done
        ;;
    esac

    for runtime_local_dependency in "${runtime_local_dependencies[@]}"; do
        if [ ! -f "${runtime_local_dependency}" ] || [ -L "${runtime_local_dependency}" ]; then
            printf 'runtime: module dependency is not a regular file: %s\n' \
                "${runtime_local_dependency}" >&2
            return 1
        fi
    done

    runtime_local_checksum=$(
        {
            printf 'module\t%s\n' "${runtime_local_module}"
            printf 'file\t%s\n' "${runtime_local_path}"
            sha256sum -- "${runtime_local_path}"
            for runtime_local_dependency in "${runtime_local_dependencies[@]}"; do
                printf 'dependency\t%s\n' "${runtime_local_dependency}"
                sha256sum -- "${runtime_local_dependency}"
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

function runtime_state_is_complete {
    local runtime_local_module="${1}"
    local runtime_local_checksum="${2}"
    local runtime_local_key
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
    while IFS=$'\t' read -r runtime_local_state_type runtime_local_state_key \
        runtime_local_state_value runtime_local_state_timestamp; do
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
        while IFS=$'\t' read -r runtime_local_state_type runtime_local_state_key \
            runtime_local_state_value runtime_local_state_timestamp; do
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

function runtime_module_fail {
    local runtime_local_status="${1:-1}"
    local runtime_local_module="${2:-unknown}"

    RUNTIME_MODULE_FAILURE_STATUS="${runtime_local_status}"
    RUNTIME_MODULE_FAILURE_MODULE="${runtime_local_module}"
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

    if ! runtime_local_path=$(runtime_resolve_module "${runtime_local_module}"); then
        runtime_log "ERROR" "Unable to resolve module '${runtime_local_module}'."
        runtime_module_fail 1 "${runtime_local_module}" || return $?
    fi

    if ! runtime_local_checksum=$(runtime_module_checksum \
        "${runtime_local_module}" "${runtime_local_path}"); then
        runtime_log "ERROR" "Unable to checksum module '${runtime_local_module}'."
        runtime_module_fail 1 "${runtime_local_module}" || return $?
    fi

    if runtime_is_dry_run; then
        runtime_local_dry_run=1
        if [ "${runtime_local_effect}" = "mutating" ]; then
            runtime_log "INFO" "Dry run: would run module '${runtime_local_module}'." ||
                runtime_module_fail 1 "${runtime_local_module}" || return $?
            return 0
        fi
    fi

    if [ "${runtime_local_effect}" = "mutating" ] && runtime_is_resume; then
        runtime_local_state_status=0
        runtime_state_is_complete "${runtime_local_module}" "${runtime_local_checksum}" || runtime_local_state_status="${?}"
        if [ "${runtime_local_state_status}" -eq 2 ]; then
            runtime_log "ERROR" "The saved state for module '${runtime_local_module}' is unsafe."
            runtime_module_fail 1 "${runtime_local_module}" || return $?
        fi
        if [ "${runtime_local_state_status}" -eq 0 ]; then
            if runtime_restore_module_state "${runtime_local_module}" "${runtime_local_state_names[@]}"; then
                runtime_log "INFO" "Resume: skipping completed module '${runtime_local_module}'." ||
                    runtime_module_fail 1 "${runtime_local_module}" || return $?
                return 0
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

    runtime_log "INFO" "Starting module '${runtime_local_module}'." ||
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
        runtime_log "INFO" "Completed orchestrator '${runtime_local_module}'."
        return 0
    fi

    if [ "${runtime_local_effect}" = "read-only" ]; then
        if [ "${runtime_local_dry_run}" -eq 1 ]; then
            runtime_log "INFO" "Dry run: completed read-only module '${runtime_local_module}'." ||
                runtime_module_fail 1 "${runtime_local_module}" || return $?
        else
            runtime_log "INFO" "Completed read-only module '${runtime_local_module}'."
        fi
        return 0
    fi

    if ! runtime_mark_module_complete \
        "${runtime_local_module}" "${runtime_local_checksum}" "${runtime_local_state_names[@]}"; then
        runtime_log "ERROR" "Module '${runtime_local_module}' completed but its state could not be recorded."
        runtime_module_fail 1 "${runtime_local_module}" || return $?
    fi

    runtime_log "INFO" "Completed module '${runtime_local_module}'."
    return 0
}
