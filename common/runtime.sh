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
declare -ga RUNTIME_MODULE_ERROR_STACK=()
declare -ga RUNTIME_MODULE_STACK=()
declare -ga RUNTIME_PROFILE_MODULES=()
declare -g RUNTIME_PROFILE_ENABLED=0
declare -g RUNTIME_PROFILE_FILE=""
declare -g RUNTIME_RUN_ID=""
declare -g RUNTIME_LOCK_ACQUIRED=0
declare -g RUNTIME_LOCK_HELD=0
declare -g RUNTIME_LOCK_DECISION_FILE=""
declare -g RUNTIME_LOCK_HOLDER_PID=""
declare -g RUNTIME_LOCK_WORKER_PID=""
declare -g RUNTIME_LOCK_WATCHDOG_PID=""
declare -g RUNTIME_LOCK_PID=""
declare -g RUNTIME_LOCK_STATUS_FILE=""
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
    x86_64 | amd64 | x64)
        printf '%s\n' "x86_64"
        ;;
    aarch64 | arm64)
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
    plain | text)
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
    debug | info | warn | warning | error) ;;
    *)
        printf 'runtime: invalid log level: %s\n' \
            "${POSTINSTALL_LOG_LEVEL}" >&2
        return 1
        ;;
    esac

    if [ -z "${RUNTIME_RUN_ID}" ]; then
        RUNTIME_RUN_ID="$(date -u +'%Y%m%dT%H%M%SZ')-$$-${RANDOM}"
    fi
    RUNTIME_INITIALIZED=1
    set -E
    set -o pipefail
    trap 'runtime_module_error_handler' ERR
    trap 'runtime_cleanup' EXIT
    trap 'runtime_handle_signal 130 INT' INT
    trap 'runtime_handle_signal 143 TERM' TERM
    trap 'runtime_handle_signal 129 HUP' HUP
    trap 'runtime_handle_lock_loss 141 lock-loss' USR1
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

function runtime_signal_background_job {
    local runtime_job_pid="${1:-}"
    local runtime_job_signal="${2:-}"
    local runtime_job_spec

    if ! runtime_job_spec=$(runtime_background_job_spec "${runtime_job_pid}"); then
        return 1
    fi
    kill "-${runtime_job_signal}" "%${runtime_job_spec}" 2>/dev/null
}

function runtime_wait_for_background_job {
    local runtime_job_pid="${1:-}"
    local runtime_job_status=0

    while :; do
        wait "${runtime_job_pid}"
        runtime_job_status="${?}"
        if [ "${runtime_job_status}" -gt 128 ]; then
            if runtime_background_job_is_running "${runtime_job_pid}"; then
                # A trapped signal interrupted wait while the child is still
                # the job owned by this shell. The wait status distinguishes an
                # interrupted wait from a completed child, and the job table
                # prevents a reused numeric PID from being mistaken for the
                # original child. Resume waiting for its real status.
                continue
            fi
            # The child may have exited while the signal handler was running.
            # Collect the completed job's real status before classifying the
            # result, so contention status 75 is not replaced by 128+signal.
            wait "${runtime_job_pid}" 2>/dev/null
            runtime_job_status="${?}"
        fi
        if runtime_background_job_is_running "${runtime_job_pid}"; then
            # Be conservative if Bash reports a running job after an unusual
            # wait status. The job table remains the authoritative binding.
            continue
        fi
        if runtime_background_job_is_known "${runtime_job_pid}"; then
            # The job is stopped rather than running. It cannot make progress,
            # so terminate the bound job before collecting its status.
            runtime_signal_background_job "${runtime_job_pid}" KILL || true
            wait "${runtime_job_pid}" 2>/dev/null
            runtime_job_status="${?}"
        fi
        return "${runtime_job_status}"
    done
}

function runtime_acquire_install_lock {
    local runtime_local_flock
    local runtime_local_holder="${SCRIPT_PATH}/common/lock-holder.py"
    local runtime_local_helper="${SCRIPT_PATH}/common/runtime-file.py"
    local runtime_local_status
    local runtime_local_holder_pid
    local runtime_local_worker_pid
    local runtime_local_watchdog_pid
    local runtime_local_lock_scope
    local runtime_local_lock_fd
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

    # Install the lock-loss handler before starting the guardian. The guardian
    # can detect a helper failure before runtime_initialize installs the
    # process-wide traps.
    trap 'runtime_handle_lock_loss 141 lock-loss' USR1

    runtime_prepare_cache_directory || return $?
    runtime_prepare_lock_file || return $?

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
    runtime_local_decision_file="${RUNTIME_LOCK_DECISION_FILE}"
    if ! rm -f -- \
        "${RUNTIME_LOCK_STATUS_FILE}" \
        "${RUNTIME_LOCK_DECISION_FILE}"; then
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

    # The guardian owns the locked descriptor and starts a Python supervisor,
    # which starts a worker and watchdog. All four processes retain the
    # descriptor. The guardian ignores installer shutdown signals, detects
    # supervisor exit without consulting the status file, and retains the
    # descriptor until the installer has completed cleanup and terminated.
    (
        umask 077
        trap - EXIT
        trap - ERR
        trap '' HUP TERM INT USR1

        runtime_guardian_cancel_requested=0
        runtime_guardian_abort_requested=0
        runtime_guardian_supervisor_pid=""
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
                cancelled 2>/dev/null) || true
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
                runtime_background_job_is_running \
                    "${runtime_guardian_supervisor_pid}"; then
                runtime_signal_background_job \
                    "${runtime_guardian_supervisor_pid}" USR2 || true
            fi
        }
        trap 'runtime_guardian_cancel_acquisition' USR2

        runtime_guardian_installer_identity=$(runtime_capture_process_identity \
            "${runtime_local_installer_pid}") || exit 73
        if [ "${runtime_guardian_installer_identity}" != \
            "${runtime_local_installer_identity}" ]; then
            exit 73
        fi

        exec {runtime_local_lock_fd}<>"${POSTINSTALL_LOCK_FILE}" || exit 73
        "${runtime_local_flock}" \
            --exclusive \
            --nonblock \
            --conflict-exit-code 75 \
            "${runtime_local_lock_fd}" || exit $?

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

        if [ "${runtime_guardian_cancel_requested}" -eq 1 ] ||
            [ "${runtime_guardian_abort_requested}" -eq 1 ]; then
            runtime_signal_background_job \
                "${runtime_guardian_supervisor_pid}" USR2 || true
        fi

        runtime_wait_for_background_job "${runtime_guardian_supervisor_pid}" ||
            runtime_guardian_supervisor_status="${?}"

        # Supervisor exit is authoritative. The decision file distinguishes a
        # cancelled acquisition from a committed lock whose helpers failed.
        runtime_guardian_decision_state=$(python3 "${runtime_local_holder}" \
            read-decision "${runtime_local_decision_file}" 2>/dev/null || true)
        if [ "${runtime_guardian_decision_state}" = "cancelled" ]; then
            # The decision is already authoritative. Notify the installer so it
            # can fail acquisition with the cancellation status, then wait for
            # its termination before removing the decision. The USR1 handler
            # distinguishes this case by rereading the decision, so a
            # cancellation cannot be mistaken for a generic lock loss.
            if ! python3 "${runtime_local_holder}" \
                await-installer \
                "${runtime_guardian_installer_identity}" \
                "${runtime_local_installer_pid}"; then
                printf 'runtime: unable to monitor installer after lock cancellation\n' >&2
                if runtime_process_identity_matches \
                    "${runtime_local_installer_pid}" \
                    "${runtime_guardian_installer_identity}"; then
                    kill -USR1 "${runtime_local_installer_pid}" 2>/dev/null || true
                fi
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
            if runtime_process_identity_matches \
                "${runtime_local_installer_pid}" \
                "${runtime_local_installer_identity}"; then
                kill -USR1 "${runtime_local_installer_pid}" 2>/dev/null || true
            fi
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

    for ((runtime_local_attempt = 0; runtime_local_attempt < 100; runtime_local_attempt++)); do
        if [ -s "${RUNTIME_LOCK_STATUS_FILE}" ]; then
            if ! runtime_local_validation=$(python3 "${runtime_local_holder}" \
                validate-status \
                "${RUNTIME_LOCK_STATUS_FILE}" \
                "${RUNTIME_LOCK_PID}" \
                "${runtime_local_installer_pid}" \
                "${runtime_local_installer_identity}"); then
                break
            fi
            IFS=' ' read -r runtime_local_holder_pid runtime_local_worker_pid \
                runtime_local_watchdog_pid <<<"${runtime_local_validation}"
            if ! [[ "${runtime_local_holder_pid}" =~ ^[0-9]+$ ]] ||
                ! [[ "${runtime_local_worker_pid}" =~ ^[0-9]+$ ]] ||
                ! [[ "${runtime_local_watchdog_pid}" =~ ^[0-9]+$ ]]; then
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
            if ! python3 "${runtime_local_holder}" \
                validate-status \
                "${RUNTIME_LOCK_STATUS_FILE}" \
                "${RUNTIME_LOCK_PID}" \
                "${runtime_local_installer_pid}" \
                "${runtime_local_installer_identity}" >/dev/null; then
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
                runtime_local_committed=1
            elif [ "${runtime_local_decision_state}" = "cancelled" ]; then
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
                    runtime_local_committed=1
                    runtime_local_cancelled=0
                elif [ "${runtime_local_decision_state}" = "cancelled" ]; then
                    runtime_local_cancelled=1
                    runtime_local_committed=0
                fi
                break
            fi
            if ! python3 "${runtime_local_holder}" \
                validate-status \
                "${RUNTIME_LOCK_STATUS_FILE}" \
                "${RUNTIME_LOCK_PID}" \
                "${runtime_local_installer_pid}" \
                "${runtime_local_installer_identity}" >/dev/null; then
                break
            fi

            RUNTIME_LOCK_HOLDER_PID="${runtime_local_holder_pid}"
            RUNTIME_LOCK_WORKER_PID="${runtime_local_worker_pid}"
            RUNTIME_LOCK_WATCHDOG_PID="${runtime_local_watchdog_pid}"
            RUNTIME_LOCK_ACQUIRED=1
            RUNTIME_LOCK_HELD=1
            return 0
        fi

        if ! runtime_background_job_is_running "${RUNTIME_LOCK_PID}"; then
            # The guardian job has completed or stopped. Its shell job table,
            # rather than a reusable numeric PID, is the authoritative link.
            break
        fi
        sleep 0.05
    done

    # Re-read the decision after every failed acquisition attempt.  The
    # decision file, rather than the exit status of the publishing helper, is
    # authoritative.  This also handles a published "committed" entry whose
    # directory fsync failed after renameat2() completed.
    runtime_local_decision_state=$(python3 "${runtime_local_holder}" \
        read-decision "${RUNTIME_LOCK_DECISION_FILE}" 2>/dev/null || true)
    if [ "${runtime_local_decision_state}" = "committed" ]; then
        runtime_local_committed=1
        runtime_local_cancelled=0
    elif [ "${runtime_local_decision_state}" = "cancelled" ]; then
        runtime_local_cancelled=1
        runtime_local_committed=0
    fi

    if [ "${runtime_local_committed}" -eq 1 ]; then
        # The commit already won.  Do not send USR2 (it is explicitly an
        # acquisition-only cancellation signal) and, most importantly, do not
        # wait for the guardian: the guardian may be waiting for this
        # installer, which would deadlock the acquisition failure path.
        printf 'runtime: unable to lock file: %s (lock acquisition failed after commit)\n' \
            "${POSTINSTALL_LOCK_FILE}" >&2
        RUNTIME_LOCK_PID=""
        RUNTIME_LOCK_HOLDER_PID=""
        RUNTIME_LOCK_WORKER_PID=""
        RUNTIME_LOCK_WATCHDOG_PID=""
        return 73
    fi

    if [ "${runtime_local_cancelled}" -eq 1 ]; then
        # The guardian keeps the decision and lock until the installer
        # terminates. Do not wait for the guardian here: it waits for this
        # installer, so waiting in both directions would deadlock.
        if [ -n "${RUNTIME_LOCK_PID}" ] &&
            runtime_background_job_is_running "${RUNTIME_LOCK_PID}"; then
            runtime_signal_background_job \
                "${RUNTIME_LOCK_PID}" USR2 || true
        fi
        RUNTIME_LOCK_PID=""
        RUNTIME_LOCK_HOLDER_PID=""
        RUNTIME_LOCK_WORKER_PID=""
        RUNTIME_LOCK_WATCHDOG_PID=""
        # Keep the decision path available to the USR1 trap until this
        # installer terminates. The guardian removes the file only after it
        # observes that termination.
        printf 'runtime: installation lock acquisition was cancelled\n' >&2
        return 73
    fi

    # A failure before the commit is cancelled rather than allowed to wait
    # for the guardian.  The guardian can be waiting for the installer, and
    # waiting for it here would create the same two-way deadlock.  If the
    # guardian has already exited, collect its status so lock contention can
    # still be reported as status 75.
    if [ -n "${RUNTIME_LOCK_PID}" ] &&
        runtime_background_job_is_running "${RUNTIME_LOCK_PID}"; then
        runtime_signal_background_job \
            "${RUNTIME_LOCK_PID}" USR2 || true
    fi
    runtime_local_status=73
    if [ -n "${RUNTIME_LOCK_PID}" ] &&
        ! runtime_background_job_is_running "${RUNTIME_LOCK_PID}"; then
        runtime_wait_for_background_job "${RUNTIME_LOCK_PID}" ||
            runtime_local_status="${?}"
        if [ "${runtime_local_status}" -eq 0 ]; then
            runtime_local_status=73
        fi
    fi

    RUNTIME_LOCK_PID=""
    RUNTIME_LOCK_HOLDER_PID=""
    RUNTIME_LOCK_WORKER_PID=""
    RUNTIME_LOCK_WATCHDOG_PID=""

    if [ "${runtime_local_status}" -eq 75 ]; then
        printf 'runtime: another installer is already running (lock: %s)\n' \
            "${POSTINSTALL_LOCK_FILE}" >&2
        return 75
    fi
    printf 'runtime: unable to lock file: %s\n' \
        "${POSTINSTALL_LOCK_FILE}" >&2
    return 73
}

function runtime_release_install_lock {
    if [ "${RUNTIME_LOCK_HELD}" -ne 1 ]; then
        return 0
    fi

    # The lock wrapper, supervisor, worker, and watchdog deliberately retain
    # the descriptor until they observe the installer's termination. The
    # guardian removes the status and decision files after that observation.
    # Keep the decision path in this shell until installer termination so a
    # helper-loss signal during cleanup can still distinguish cancellation
    # from generic loss.
    RUNTIME_LOCK_HOLDER_PID=""
    RUNTIME_LOCK_WORKER_PID=""
    RUNTIME_LOCK_WATCHDOG_PID=""
    RUNTIME_LOCK_PID=""
    RUNTIME_LOCK_STATUS_FILE=""
    RUNTIME_LOCK_HELD=0
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

    # Lock loss is a security-sensitive terminal status. Once it is pending,
    # an ordinary shutdown signal must not replace status 141 during cleanup.
    if [ "${RUNTIME_PENDING_LOCK_LOSS}" -eq 1 ]; then
        runtime_log "WARN" "Received ${runtime_local_name}; preserving pending lock-loss status ${RUNTIME_PENDING_SIGNAL_STATUS}." \
            "runtime.lock.lost" || true
        return 0
    fi

    if [ "${RUNTIME_CRITICAL_DEPTH}" -gt 0 ] || [ "${RUNTIME_CLEANING}" -eq 1 ]; then
        RUNTIME_PENDING_SIGNAL_STATUS="${runtime_local_status}"
        RUNTIME_PENDING_SIGNAL_NAME="${runtime_local_name}"
        runtime_log "WARN" "Received ${runtime_local_name}; deferring shutdown until the current operation completes."
        return 0
    fi

    runtime_log "WARN" "Received ${runtime_local_name}; shutting down."
    exit "${runtime_local_status}"
}

function runtime_handle_lock_loss {
    local runtime_local_status="${1:-141}"
    local runtime_local_decision_state=""
    local runtime_local_holder="${SCRIPT_PATH:-}/common/lock-holder.py"

    # A cancellation winner is distinct from a helper failure. The guardian
    # uses USR1 to wake an installer that may be waiting for the guardian; the
    # decision lets the installer report the intended cancellation status
    # instead of a generic lock-loss status.
    if [ -n "${RUNTIME_LOCK_DECISION_FILE:-}" ] &&
        [ -f "${runtime_local_holder}" ] &&
        [ ! -L "${runtime_local_holder}" ] &&
        command -v python3 >/dev/null 2>&1; then
        runtime_local_decision_state=$(python3 "${runtime_local_holder}" \
            read-decision "${RUNTIME_LOCK_DECISION_FILE}" 2>/dev/null || true)
    fi
    if [ "${runtime_local_decision_state}" = "cancelled" ]; then
        RUNTIME_PENDING_LOCK_LOSS=1
        RUNTIME_PENDING_SIGNAL_STATUS=73
        RUNTIME_PENDING_SIGNAL_NAME="lock-cancelled"
        if [ "${RUNTIME_CRITICAL_DEPTH}" -gt 0 ] || [ "${RUNTIME_CLEANING}" -eq 1 ]; then
            runtime_log "ERROR" "The installation lock acquisition was cancelled; aborting after the current operation completes." \
                "runtime.lock.cancelled" || true
            printf 'runtime: installation lock acquisition was cancelled; aborting after cleanup\n' >&2
            return 0
        fi
        runtime_log "ERROR" "The installation lock acquisition was cancelled; aborting immediately." \
            "runtime.lock.cancelled" || true
        printf 'runtime: installation lock acquisition was cancelled; aborting immediately\n' >&2
        exit 73
    fi

    # A helper failure before acquisition has completed is an acquisition
    # failure, not a loss of an already-held installation lock. In
    # particular, do not turn it into a wait for the guardian: the guardian
    # may be waiting for this installer to exit. RUNTIME_LOCK_ACQUIRED remains
    # set after cleanup starts, so a later helper failure is still classified
    # as generic loss rather than acquisition failure.
    if [ "${RUNTIME_LOCK_ACQUIRED}" -ne 1 ]; then
        RUNTIME_PENDING_LOCK_LOSS=1
        RUNTIME_PENDING_SIGNAL_STATUS=73
        RUNTIME_PENDING_SIGNAL_NAME="lock-acquisition-failed"
        if [ "${RUNTIME_CRITICAL_DEPTH}" -gt 0 ] || [ "${RUNTIME_CLEANING}" -eq 1 ]; then
            runtime_log "ERROR" "The installation lock acquisition failed; aborting after the current operation completes." \
                "runtime.lock.failed" || true
            printf 'runtime: installation lock acquisition failed; aborting after cleanup\n' >&2
            return 0
        fi
        runtime_log "ERROR" "The installation lock acquisition failed; aborting immediately." \
            "runtime.lock.failed" || true
        printf 'runtime: installation lock acquisition failed; installation lock was lost; aborting immediately\n' >&2
        exit 73
    fi

    # Lock loss always takes precedence over a previously pending ordinary
    # signal, and remains pending until the installer exits.
    RUNTIME_PENDING_LOCK_LOSS=1
    RUNTIME_PENDING_SIGNAL_STATUS="${runtime_local_status}"
    RUNTIME_PENDING_SIGNAL_NAME="lock-loss"

    if [ "${RUNTIME_CRITICAL_DEPTH}" -gt 0 ] || [ "${RUNTIME_CLEANING}" -eq 1 ]; then
        runtime_log "ERROR" "The installation lock helpers failed; aborting after the current operation completes." \
            "runtime.lock.lost" || true
        printf 'runtime: installation lock helpers failed; aborting after cleanup\n' >&2
        return 0
    fi

    runtime_log "ERROR" "The installation lock helpers failed; aborting immediately." \
        "runtime.lock.lost" || true
    printf 'runtime: installation lock was lost; aborting immediately\n' >&2
    exit "${runtime_local_status}"
}

function runtime_cleanup {
    local runtime_local_status="${?}"
    local runtime_local_final_status
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

    runtime_local_final_status="${runtime_local_status}"
    if [ "${RUNTIME_PENDING_SIGNAL_STATUS}" -ne 0 ]; then
        runtime_local_final_status="${RUNTIME_PENDING_SIGNAL_STATUS}"
    fi
    RUNTIME_CLEANING=0
    RUNTIME_CLEANED=1
    if [ "${RUNTIME_PENDING_SIGNAL_STATUS}" -ne 0 ]; then
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
    WARN | WARNING) printf '%s\n' "2" ;;
    ERROR) printf '%s\n' "3" ;;
    *) printf '%s\n' "1" ;;
    esac
}

function runtime_log_should_emit {
    local runtime_local_level="${1:-INFO}"
    local runtime_local_threshold="${POSTINSTALL_LOG_LEVEL:-info}"
    local runtime_local_level_value
    local runtime_local_threshold_value

    runtime_local_level_value=$(runtime_log_level_value "${runtime_local_level}")
    runtime_local_threshold_value=$(runtime_log_level_value "${runtime_local_threshold}")
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

    if declare -F runtime_module_dependency_closure >/dev/null 2>&1 &&
        [ -n "${POSTINSTALL_FLAVOR:-}" ]; then
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
            runtime_log "INFO" "Dry run: would run module '${runtime_local_module}'." ||
                runtime_module_fail 1 "${runtime_local_module}" || return $?
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
    return 0
}
