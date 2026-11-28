#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

# Shared helpers for the intentionally rolling Distrobox, direnv, and
# Starship installers. These tools are managed independently of Fedora
# packages, so their installers are not version-pinned here.

declare -g ROLLING_INSTALLER_TEMPORARY_PATH=""
declare -g ROLLING_INSTALLER_CLEANUP_REGISTERED=0
declare -g ROLLING_INSTALLER_LOCK_FD=""
declare -g ROLLING_INSTALLER_CHILD_PID=""
declare -g ROLLING_INSTALLER_RECEIVED_SIGNAL_STATUS=0
declare -g ROLLING_INSTALLER_RECEIVED_SIGNAL_NAME=""

function rolling_installer_cleanup_temporary {
    if [ -z "${ROLLING_INSTALLER_TEMPORARY_PATH}" ]; then
        return 0
    fi
    if [ -e "${ROLLING_INSTALLER_TEMPORARY_PATH}" ] ||
        [ -L "${ROLLING_INSTALLER_TEMPORARY_PATH}" ]; then
        rm -f -- "${ROLLING_INSTALLER_TEMPORARY_PATH}" || return $?
    fi
    return 0
}

function rolling_installer_remove_temporary {
    local rolling_installer_local_cleanup_status=0

    rolling_installer_cleanup_temporary ||
        rolling_installer_local_cleanup_status="${?}"
    if [ "${rolling_installer_local_cleanup_status}" -eq 0 ]; then
        ROLLING_INSTALLER_TEMPORARY_PATH=""
        if [ "${ROLLING_INSTALLER_CLEANUP_REGISTERED}" -eq 1 ] &&
            declare -F runtime_unregister_cleanup >/dev/null; then
            if runtime_unregister_cleanup "rolling-installer-temporary"; then
                ROLLING_INSTALLER_CLEANUP_REGISTERED=0
            fi
        fi
    fi
    return "${rolling_installer_local_cleanup_status}"
}

function rolling_installer_report_error {
    local rolling_installer_local_message="${1:-}"

    if declare -F ui_error >/dev/null; then
        ui_error "${rolling_installer_local_message}"
        return $?
    fi
    printf 'installer: %s\n' "${rolling_installer_local_message}" >&2
}

function rolling_installer_tool_from_url {
    local rolling_installer_local_url="${1:-}"
    local rolling_installer_local_hash
    local rolling_installer_local_tool

    case "${rolling_installer_local_url}" in
    https://starship.rs/*)
        rolling_installer_local_tool="starship"
        ;;
    https://direnv.net/*)
        rolling_installer_local_tool="direnv"
        ;;
    https://raw.githubusercontent.com/*/distrobox/*)
        rolling_installer_local_tool="distrobox"
        ;;
    *)
        rolling_installer_local_hash=$(
            printf '%s' "${rolling_installer_local_url}" | sha256sum
        ) || return 1
        rolling_installer_local_hash="${rolling_installer_local_hash%% *}"
        rolling_installer_local_tool="url-${rolling_installer_local_hash:0:16}"
        ;;
    esac
    printf '%s\n' "${rolling_installer_local_tool}"
}

function rolling_installer_lock_path {
    local rolling_installer_local_url="${1:-}"
    local rolling_installer_local_base=""
    local rolling_installer_local_tool
    local rolling_installer_local_uid

    rolling_installer_local_tool=$(rolling_installer_tool_from_url \
        "${rolling_installer_local_url}") || return 1
    if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
        rolling_installer_local_base="${XDG_RUNTIME_DIR}"
        if [ ! -d "${rolling_installer_local_base}" ] ||
            [ -L "${rolling_installer_local_base}" ] ||
            [ ! -O "${rolling_installer_local_base}" ]; then
            return 1
        fi
    else
        rolling_installer_local_uid=$(id -u) || return 1
        rolling_installer_local_base="/tmp/fedora-postinstall-${rolling_installer_local_uid}"
        if [ -L "${rolling_installer_local_base}" ]; then
            return 1
        fi
        if [ -e "${rolling_installer_local_base}" ] &&
            [ ! -d "${rolling_installer_local_base}" ]; then
            return 1
        fi
        mkdir -p -m 0700 -- "${rolling_installer_local_base}" || return 1
        chmod 0700 -- "${rolling_installer_local_base}" || return 1
        if [ -L "${rolling_installer_local_base}" ] ||
            [ ! -d "${rolling_installer_local_base}" ] ||
            [ ! -O "${rolling_installer_local_base}" ]; then
            return 1
        fi
    fi
    printf '%s/rolling-install-%s.lock\n' \
        "${rolling_installer_local_base}" "${rolling_installer_local_tool}"
}

function rolling_installer_lock_acquire {
    local rolling_installer_local_url="${1:-}"
    local rolling_installer_local_path
    local rolling_installer_local_status=0
    local rolling_installer_local_timeout="${ROLLING_INSTALLER_LOCK_TIMEOUT_SECONDS:-300}"

    if ! [[ "${rolling_installer_local_timeout}" =~ ^[0-9]+$ ]] ||
        [ "${rolling_installer_local_timeout}" -lt 1 ] ||
        [ "${rolling_installer_local_timeout}" -gt 3600 ]; then
        return 64
    fi
    command -v flock >/dev/null 2>&1 || return 127
    rolling_installer_local_path=$(rolling_installer_lock_path \
        "${rolling_installer_local_url}") || return 1
    if [ -L "${rolling_installer_local_path}" ]; then
        return 1
    fi
    if [ -e "${rolling_installer_local_path}" ] &&
        [ ! -f "${rolling_installer_local_path}" ]; then
        return 1
    fi
    (
        umask 077
        : >>"${rolling_installer_local_path}"
    ) || return 1
    if [ -L "${rolling_installer_local_path}" ] ||
        [ ! -f "${rolling_installer_local_path}" ] ||
        [ ! -O "${rolling_installer_local_path}" ]; then
        return 1
    fi

    exec {ROLLING_INSTALLER_LOCK_FD}<>"${rolling_installer_local_path}" ||
        return 1
    flock -w "${rolling_installer_local_timeout}" -x \
        "${ROLLING_INSTALLER_LOCK_FD}" ||
        rolling_installer_local_status="${?}"
    if [ "${rolling_installer_local_status}" -ne 0 ]; then
        exec {ROLLING_INSTALLER_LOCK_FD}>&- || true
        ROLLING_INSTALLER_LOCK_FD=""
        return "${rolling_installer_local_status}"
    fi
    return 0
}

function rolling_installer_lock_release {
    local rolling_installer_local_status=0

    if [ -z "${ROLLING_INSTALLER_LOCK_FD}" ]; then
        return 0
    fi
    flock -u "${ROLLING_INSTALLER_LOCK_FD}" ||
        rolling_installer_local_status="${?}"
    exec {ROLLING_INSTALLER_LOCK_FD}>&- ||
        rolling_installer_local_status="${?}"
    ROLLING_INSTALLER_LOCK_FD=""
    return "${rolling_installer_local_status}"
}

function rolling_installer_process_group_id {
    local rolling_installer_local_pid="${1:-}"
    local rolling_installer_local_stat=""
    local rolling_installer_local_fields_text=""
    local rolling_installer_local_group_id=""
    local -a rolling_installer_local_fields=()

    if ! [[ "${rolling_installer_local_pid}" =~ ^[0-9]+$ ]] ||
        [ "${rolling_installer_local_pid}" -le 1 ] ||
        [ ! -r "/proc/${rolling_installer_local_pid}/stat" ]; then
        return 1
    fi
    rolling_installer_local_stat=$(
        cat "/proc/${rolling_installer_local_pid}/stat" 2>/dev/null
    ) || return 1
    rolling_installer_local_fields_text="${rolling_installer_local_stat##*) }"
    read -r -a rolling_installer_local_fields <<<"${rolling_installer_local_fields_text}"
    if [ "${#rolling_installer_local_fields[@]}" -le 2 ]; then
        return 1
    fi
    rolling_installer_local_group_id="${rolling_installer_local_fields[2]}"
    if ! [[ "${rolling_installer_local_group_id}" =~ ^[0-9]+$ ]] ||
        [ "${rolling_installer_local_group_id}" -le 1 ]; then
        return 1
    fi
    printf '%s\n' "${rolling_installer_local_group_id}"
}

function rolling_installer_signal_process_tree {
    local rolling_installer_local_signal="${1:-TERM}"
    local rolling_installer_local_pid="${2:-}"
    local rolling_installer_local_children=""
    local rolling_installer_local_child
    local rolling_installer_local_group_id=""

    if ! [[ "${rolling_installer_local_pid}" =~ ^[0-9]+$ ]] ||
        [ "${rolling_installer_local_pid}" -le 1 ]; then
        return 1
    fi
    if ! kill -0 "${rolling_installer_local_pid}" 2>/dev/null; then
        return 1
    fi

    # Only signal a process group after verifying that the installer is its
    # leader. Otherwise the numeric group could belong to an unrelated
    # process. The installer is launched in its own group so this reaches
    # every helper it starts, even when a descendant changes its disposition.
    rolling_installer_local_group_id=$(rolling_installer_process_group_id \
        "${rolling_installer_local_pid}") ||
        rolling_installer_local_group_id=""
    if [ "${rolling_installer_local_group_id}" = "${rolling_installer_local_pid}" ]; then
        kill -s "${rolling_installer_local_signal}" -- \
            "-${rolling_installer_local_pid}" 2>/dev/null ||
            kill -s "${rolling_installer_local_signal}" \
                "${rolling_installer_local_pid}" 2>/dev/null ||
            return 1
        return 0
    fi

    # Fall back to walking descendants if process-group metadata is not
    # available. This path is slower and racy, but remains bounded and never
    # signals an unverified process group.
    if command -v pgrep >/dev/null 2>&1; then
        rolling_installer_local_children=$(
            pgrep -P "${rolling_installer_local_pid}" 2>/dev/null
        ) || rolling_installer_local_children=""
        for rolling_installer_local_child in ${rolling_installer_local_children}; do
            rolling_installer_signal_process_tree \
                "${rolling_installer_local_signal}" \
                "${rolling_installer_local_child}" || true
        done
        sleep 0.1 || true
        kill -s "${rolling_installer_local_signal}" \
            "${rolling_installer_local_pid}" 2>/dev/null || true
        return 0
    fi
    kill -s "${rolling_installer_local_signal}" \
        "${rolling_installer_local_pid}" 2>/dev/null || return 1
    return 0
}

function rolling_installer_handle_signal {
    local rolling_installer_local_signal="${1:-TERM}"
    local rolling_installer_local_status="${2:-143}"

    if [ "${ROLLING_INSTALLER_RECEIVED_SIGNAL_STATUS}" -eq 0 ]; then
        ROLLING_INSTALLER_RECEIVED_SIGNAL_STATUS="${rolling_installer_local_status}"
        ROLLING_INSTALLER_RECEIVED_SIGNAL_NAME="${rolling_installer_local_signal}"
    fi
    if [ -n "${ROLLING_INSTALLER_CHILD_PID}" ]; then
        rolling_installer_signal_process_tree \
            "${rolling_installer_local_signal}" \
            "${ROLLING_INSTALLER_CHILD_PID}" || true
    fi
    return 0
}

function rolling_installer_process_running {
    local rolling_installer_local_pid="${1:-}"
    local rolling_installer_local_state=""
    local rolling_installer_local_stat=""

    if ! [[ "${rolling_installer_local_pid}" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    kill -0 "${rolling_installer_local_pid}" 2>/dev/null || return 1
    if [ -r "/proc/${rolling_installer_local_pid}/stat" ]; then
        rolling_installer_local_stat=$(
            cat "/proc/${rolling_installer_local_pid}/stat" 2>/dev/null
        ) || return 1
        rolling_installer_local_state="${rolling_installer_local_stat##*) }"
        rolling_installer_local_state="${rolling_installer_local_state%% *}"
        if [ "${rolling_installer_local_state}" = "Z" ]; then
            return 1
        fi
    fi
    return 0
}

function rolling_installer_restore_trap {
    local rolling_installer_local_previous="${1:-}"
    local rolling_installer_local_signal="${2:-HUP}"

    if [ -n "${rolling_installer_local_previous}" ]; then
        eval "${rolling_installer_local_previous}"
    else
        trap - "${rolling_installer_local_signal}"
    fi
}

function rolling_installer_execute {
    local rolling_installer_local_shell="${1:-}"
    local rolling_installer_local_path="${2:-}"
    local rolling_installer_local_timeout="${ROLLING_INSTALLER_TIMEOUT_SECONDS:-600}"
    local rolling_installer_local_grace="${ROLLING_INSTALLER_KILL_GRACE_SECONDS:-5}"
    local rolling_installer_local_child_status=0
    local rolling_installer_local_marker
    local rolling_installer_local_marker_directory
    local rolling_installer_local_monitor_enabled=0
    local rolling_installer_local_watchdog_monitor_enabled=0
    local rolling_installer_local_previous_hup
    local rolling_installer_local_previous_int
    local rolling_installer_local_previous_term
    local rolling_installer_local_status=0
    local rolling_installer_local_watchdog
    local rolling_installer_local_watchdog_status=0

    shift 2 || return 1
    if [ -z "${rolling_installer_local_shell}" ] ||
        [ -z "${rolling_installer_local_path}" ]; then
        return 64
    fi
    if ! [[ "${rolling_installer_local_timeout}" =~ ^[0-9]+$ ]] ||
        [ "${rolling_installer_local_timeout}" -lt 1 ] ||
        [ "${rolling_installer_local_timeout}" -gt 86400 ]; then
        return 64
    fi
    if ! [[ "${rolling_installer_local_grace}" =~ ^[0-9]+$ ]] ||
        [ "${rolling_installer_local_grace}" -lt 1 ] ||
        [ "${rolling_installer_local_grace}" -gt 60 ]; then
        return 64
    fi

    rolling_installer_local_marker_directory=$(mktemp -d \
        "${TMPDIR:-/tmp}/fedora-postinstall-rolling-timeout.XXXXXX") || return 1
    rolling_installer_local_marker="${rolling_installer_local_marker_directory}/timeout"
    rolling_installer_local_previous_hup=$(trap -p HUP) || true
    rolling_installer_local_previous_int=$(trap -p INT) || true
    rolling_installer_local_previous_term=$(trap -p TERM) || true

    # Run the installer in its own process group. This keeps SIGINT usable in
    # the installer (Bash otherwise ignores it for asynchronous children) and
    # lets one group signal reach every helper the installer starts.
    ROLLING_INSTALLER_RECEIVED_SIGNAL_STATUS=0
    ROLLING_INSTALLER_RECEIVED_SIGNAL_NAME=""

    # Install the forwarding traps before launching the installer. Otherwise a
    # signal arriving during startup can be handled by the caller's default
    # disposition and mask the installer's eventual status.
    trap 'rolling_installer_handle_signal HUP 129' HUP
    trap 'rolling_installer_handle_signal INT 130' INT
    trap 'rolling_installer_handle_signal TERM 143' TERM

    if [[ "$-" == *m* ]]; then
        rolling_installer_local_monitor_enabled=1
    else
        set -m
    fi
    "${rolling_installer_local_shell}" "${rolling_installer_local_path}" "$@" &
    ROLLING_INSTALLER_CHILD_PID="${!}"
    if [ "${rolling_installer_local_monitor_enabled}" -eq 0 ]; then
        set +m
    fi
    if [ -n "${ROLLING_INSTALLER_RECEIVED_SIGNAL_NAME}" ]; then
        rolling_installer_handle_signal \
            "${ROLLING_INSTALLER_RECEIVED_SIGNAL_NAME}" \
            "${ROLLING_INSTALLER_RECEIVED_SIGNAL_STATUS}"
    fi

    # Give the watchdog its own process group so it can be terminated
    # together with its sleeping child without touching the installer group.
    if [[ "$-" == *m* ]]; then
        rolling_installer_local_watchdog_monitor_enabled=1
    else
        set -m
    fi
    (
        sleep "${rolling_installer_local_timeout}" || exit 0
        if rolling_installer_process_running "${ROLLING_INSTALLER_CHILD_PID}"; then
            mkdir -- "${rolling_installer_local_marker}" 2>/dev/null || true
            rolling_installer_signal_process_tree TERM \
                "${ROLLING_INSTALLER_CHILD_PID}" || true
            sleep "${rolling_installer_local_grace}" || true
            rolling_installer_signal_process_tree KILL \
                "${ROLLING_INSTALLER_CHILD_PID}" 2>/dev/null || true
        fi
    ) >/dev/null 2>&1 &
    rolling_installer_local_watchdog="${!}"
    if [ "${rolling_installer_local_watchdog_monitor_enabled}" -eq 0 ]; then
        set +m
    fi

    # Do not block in Bash's wait builtin while the installer is alive. Bash
    # defers an INT trap until an asynchronous child exits, which would
    # prevent the parent from forwarding the interruption. Short foreground
    # sleeps keep the trap responsive; the child is reaped with wait after it
    # has exited and its exact status is available.
    while rolling_installer_process_running "${ROLLING_INSTALLER_CHILD_PID}"; do
        sleep 0.1 || true
    done
    if wait "${ROLLING_INSTALLER_CHILD_PID}"; then
        rolling_installer_local_child_status=0
    else
        rolling_installer_local_child_status="${?}"
    fi

    # Terminate the watchdog's verified process group, including its sleep
    # child. The installer has a separate group and is never included.
    rolling_installer_signal_process_tree TERM \
        "${rolling_installer_local_watchdog}" || true
    if wait "${rolling_installer_local_watchdog}"; then
        rolling_installer_local_watchdog_status=0
    else
        rolling_installer_local_watchdog_status="${?}"
    fi
    rolling_installer_restore_trap "${rolling_installer_local_previous_hup}" HUP
    rolling_installer_restore_trap "${rolling_installer_local_previous_int}" INT
    rolling_installer_restore_trap "${rolling_installer_local_previous_term}" TERM

    if [ -d "${rolling_installer_local_marker}" ]; then
        rolling_installer_local_status=124
        rolling_installer_report_error \
            "The rolling installer timed out after ${rolling_installer_local_timeout} seconds." ||
            true
    elif [ "${rolling_installer_local_child_status}" -ne 0 ]; then
        rolling_installer_local_status="${rolling_installer_local_child_status}"
    elif [ "${ROLLING_INSTALLER_RECEIVED_SIGNAL_STATUS}" -ne 0 ]; then
        rolling_installer_local_status="${ROLLING_INSTALLER_RECEIVED_SIGNAL_STATUS}"
    fi
    rmdir -- "${rolling_installer_local_marker}" 2>/dev/null || true
    rmdir -- "${rolling_installer_local_marker_directory}" 2>/dev/null || true
    ROLLING_INSTALLER_CHILD_PID=""
    ROLLING_INSTALLER_RECEIVED_SIGNAL_STATUS=0
    ROLLING_INSTALLER_RECEIVED_SIGNAL_NAME=""
    return "${rolling_installer_local_status}"
}

function rolling_installer_download_raw {
    local rolling_installer_local_url="${1:-}"
    local rolling_installer_local_path="${2:-}"
    local rolling_installer_local_status=0

    ROLLING_INSTALLER_FAILURE_REASON=""
    if [ -z "${rolling_installer_local_url}" ] ||
        [ -z "${rolling_installer_local_path}" ]; then
        ROLLING_INSTALLER_FAILURE_REASON="arguments"
        return 64
    fi
    if [[ "${rolling_installer_local_url}" != https://* ]]; then
        ROLLING_INSTALLER_FAILURE_REASON="scheme"
        return 64
    fi

    # Keep the failing command in an || list. The runtime's ERR trap exits the
    # installer immediately for an unguarded failure, which would otherwise
    # bypass the temporary-file cleanup in rolling_installer_run.
    curl \
        --disable \
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
        --output "${rolling_installer_local_path}" \
        "${rolling_installer_local_url}" ||
        rolling_installer_local_status="${?}"
    if [ "${rolling_installer_local_status}" -ne 0 ]; then
        ROLLING_INSTALLER_FAILURE_REASON="download"
        return "${rolling_installer_local_status}"
    fi
    if [ ! -s "${rolling_installer_local_path}" ]; then
        ROLLING_INSTALLER_FAILURE_REASON="empty"
        return 1
    fi
    return 0
}

function rolling_installer_download {
    local rolling_installer_local_url="${1:-}"
    local rolling_installer_local_path="${2:-}"
    local rolling_installer_local_status=0

    rolling_installer_download_raw \
        "${rolling_installer_local_url}" "${rolling_installer_local_path}" ||
        rolling_installer_local_status="${?}"
    if [ "${rolling_installer_local_status}" -eq 0 ]; then
        return 0
    fi

    case "${ROLLING_INSTALLER_FAILURE_REASON}" in
    empty)
        rolling_installer_report_error \
            "The rolling installer downloaded from ${rolling_installer_local_url} was empty." || true
        ;;
    scheme)
        rolling_installer_report_error \
            "Rolling installer URLs must use HTTPS." || true
        ;;
    arguments)
        rolling_installer_report_error \
            "A rolling installer URL and destination are required." || true
        ;;
    *)
        rolling_installer_report_error \
            "Unable to download the rolling installer from ${rolling_installer_local_url}." || true
        ;;
    esac
    return "${rolling_installer_local_status}"
}

function rolling_installer_run {
    local rolling_installer_local_url="${1:-}"
    local rolling_installer_local_shell="${2:-}"
    local rolling_installer_local_temporary
    local rolling_installer_local_status=0
    local rolling_installer_local_cleanup_status=0
    local rolling_installer_local_lock_status=0
    local rolling_installer_local_lock_release_status=0

    if [ -z "${rolling_installer_local_url}" ] ||
        [ -z "${rolling_installer_local_shell}" ]; then
        rolling_installer_report_error \
            "A rolling installer URL and interpreter are required." || true
        return 64
    fi
    if [[ "${rolling_installer_local_url}" != https://* ]]; then
        rolling_installer_report_error \
            "Rolling installer URLs must use HTTPS." || true
        return 64
    fi
    shift 2

    rolling_installer_lock_acquire "${rolling_installer_local_url}" ||
        rolling_installer_local_lock_status="${?}"
    if [ "${rolling_installer_local_lock_status}" -ne 0 ]; then
        rolling_installer_report_error \
            "Unable to acquire the rolling installer update lock." || true
        return "${rolling_installer_local_lock_status}"
    fi

    rolling_installer_local_temporary=$(mktemp \
        "${TMPDIR:-/tmp}/fedora-postinstall-rolling-installer.XXXXXX") || {
        rolling_installer_lock_release || true
        return 1
    }
    ROLLING_INSTALLER_TEMPORARY_PATH="${rolling_installer_local_temporary}"
    if declare -F runtime_register_cleanup >/dev/null &&
        declare -F runtime_unregister_cleanup >/dev/null; then
        if ! runtime_register_cleanup \
            "rolling-installer-temporary" rolling_installer_cleanup_temporary; then
            rolling_installer_remove_temporary || true
            rolling_installer_lock_release || true
            return 1
        fi
        ROLLING_INSTALLER_CLEANUP_REGISTERED=1
    fi
    rolling_installer_download_raw \
        "${rolling_installer_local_url}" "${rolling_installer_local_temporary}" ||
        rolling_installer_local_status="${?}"
    if [ "${rolling_installer_local_status}" -ne 0 ]; then
        rolling_installer_remove_temporary ||
            rolling_installer_local_cleanup_status="${?}"
        rolling_installer_lock_release ||
            rolling_installer_local_lock_release_status="${?}"
        case "${ROLLING_INSTALLER_FAILURE_REASON}" in
        empty)
            rolling_installer_report_error \
                "The rolling installer downloaded from ${rolling_installer_local_url} was empty." || true
            ;;
        scheme)
            rolling_installer_report_error \
                "Rolling installer URLs must use HTTPS." || true
            ;;
        *)
            rolling_installer_report_error \
                "Unable to download the rolling installer from ${rolling_installer_local_url}." || true
            ;;
        esac
        if [ "${rolling_installer_local_cleanup_status}" -ne 0 ]; then
            rolling_installer_report_error \
                "The rolling installer failed, but its temporary file could not be removed." || true
        fi
        return "${rolling_installer_local_status}"
    fi

    # Guard the downloaded script as well. A non-zero status must be collected
    # so the temporary file is removed before the runtime observes the failure.
    rolling_installer_execute \
        "${rolling_installer_local_shell}" "${rolling_installer_local_temporary}" "$@" ||
        rolling_installer_local_status="${?}"
    rolling_installer_remove_temporary ||
        rolling_installer_local_cleanup_status="${?}"
    rolling_installer_lock_release ||
        rolling_installer_local_lock_release_status="${?}"
    if [ "${rolling_installer_local_status}" -ne 0 ]; then
        rolling_installer_report_error \
            "The rolling installer from ${rolling_installer_local_url} failed with status ${rolling_installer_local_status}." || true
    fi
    if [ "${rolling_installer_local_cleanup_status}" -ne 0 ]; then
        rolling_installer_report_error \
            "The rolling installer completed, but its temporary file could not be removed." || true
    fi
    if [ "${rolling_installer_local_lock_release_status}" -ne 0 ]; then
        rolling_installer_report_error \
            "The rolling installer completed, but its update lock could not be released." || true
    fi
    if [ "${rolling_installer_local_status}" -ne 0 ]; then
        return "${rolling_installer_local_status}"
    fi
    if [ "${rolling_installer_local_cleanup_status}" -ne 0 ]; then
        return "${rolling_installer_local_cleanup_status}"
    fi
    return "${rolling_installer_local_lock_release_status}"
}
