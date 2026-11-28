#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

# Read-only host diagnostics. This file deliberately has no dependency on
# Gum, the installer UI, or the mutation runtime.

declare -ga DOCTOR_CHECK_IDS=()
declare -ga DOCTOR_CHECK_NAMES=()
declare -ga DOCTOR_CHECK_STATUSES=()
declare -ga DOCTOR_CHECK_MESSAGES=()
declare -ga DOCTOR_CHECK_DETAILS=()
declare -g DOCTOR_RECOVERY_JSON='{"status":"unknown","transactions":[]}'

function doctor_snapshot_helper_path {
    local doctor_local_directory=""

    doctor_local_directory=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" &&
        pwd -P) || return 1
    printf '%s\n' "${doctor_local_directory}/snapshot.py"
}

function doctor_snapshot_recovery_json {
    local doctor_local_helper=""
    local doctor_local_python=""

    doctor_local_helper=$(doctor_snapshot_helper_path) || return 1
    doctor_local_python=$(command -v python3 2>/dev/null) || return 1
    "${doctor_local_python}" "${doctor_local_helper}" recovery-status
}

function doctor_reset {
    DOCTOR_CHECK_IDS=()
    DOCTOR_CHECK_NAMES=()
    DOCTOR_CHECK_STATUSES=()
    DOCTOR_CHECK_MESSAGES=()
    DOCTOR_CHECK_DETAILS=()
    DOCTOR_RECOVERY_JSON='{"status":"unknown","transactions":[]}'
}

function doctor_add_check {
    local doctor_local_id="${1:-}"
    local doctor_local_name="${2:-}"
    local doctor_local_status="${3:-}"
    local doctor_local_message="${4:-}"
    local doctor_local_details="${5:-}"

    case "${doctor_local_status}" in
    ok | warning | error | skipped) ;;
    *)
        printf 'doctor: invalid check status: %s\n' "${doctor_local_status}" >&2
        return 1
        ;;
    esac

    DOCTOR_CHECK_IDS+=("${doctor_local_id}")
    DOCTOR_CHECK_NAMES+=("${doctor_local_name}")
    DOCTOR_CHECK_STATUSES+=("${doctor_local_status}")
    DOCTOR_CHECK_MESSAGES+=("${doctor_local_message}")
    DOCTOR_CHECK_DETAILS+=("${doctor_local_details}")
}

function doctor_os_release_file {
    printf '%s\n' "${POSTINSTALL_OS_RELEASE_FILE:-/etc/os-release}"
}

function doctor_os_release_value {
    local doctor_local_key="${1:-}"
    local doctor_local_file
    local doctor_local_line
    local doctor_local_value=""

    doctor_local_file=$(doctor_os_release_file) || return 1
    [ -r "${doctor_local_file}" ] || return 1
    while IFS= read -r doctor_local_line; do
        case "${doctor_local_line}" in
        "${doctor_local_key}"=*)
            doctor_local_value="${doctor_local_line#*=}"
            doctor_local_value="${doctor_local_value%\"}"
            doctor_local_value="${doctor_local_value#\"}"
            printf '%s\n' "${doctor_local_value}"
            return 0
            ;;
        esac
    done <"${doctor_local_file}"
    return 1
}

function doctor_rpm_has_package {
    local doctor_local_package="${1:-}"
    local doctor_local_output=""

    if [ -z "${doctor_local_package}" ] ||
        ! command -v rpm >/dev/null 2>&1; then
        return 1
    fi
    doctor_local_output=$(rpm -q "${doctor_local_package}" 2>/dev/null) ||
        return 1
    case "${doctor_local_output}" in
    "${doctor_local_package}"*) return 0 ;;
    *) return 1 ;;
    esac
}

function doctor_detect_flavor {
    local doctor_local_name=""
    local doctor_local_variant=""
    local doctor_local_id=""
    local doctor_local_workstation=0
    local doctor_local_silverblue=0
    local doctor_local_flavor_count=0

    doctor_local_name=$(doctor_os_release_value "NAME") || doctor_local_name=""
    doctor_local_variant=$(doctor_os_release_value "VARIANT_ID") || doctor_local_variant=""
    doctor_local_id=$(doctor_os_release_value "ID") || doctor_local_id=""
    case "${doctor_local_name,,} ${doctor_local_variant,,}" in
    *workstation*) doctor_local_workstation=1 ;;
    esac
    case "${doctor_local_name,,} ${doctor_local_variant,,}" in
    *silverblue*) doctor_local_silverblue=1 ;;
    esac
    case "${doctor_local_id,,}" in
    silverblue) doctor_local_silverblue=1 ;;
    esac

    if doctor_rpm_has_package "fedora-release-identity-workstation" ||
        doctor_rpm_has_package "fedora-release-workstation"; then
        doctor_local_workstation=1
    fi
    if doctor_rpm_has_package "fedora-release-identity-silverblue" ||
        doctor_rpm_has_package "fedora-release-silverblue"; then
        doctor_local_silverblue=1
    fi

    doctor_local_flavor_count=$((doctor_local_workstation + doctor_local_silverblue))
    if [ "${doctor_local_flavor_count}" -eq 1 ]; then
        if [ "${doctor_local_workstation}" -eq 1 ]; then
            printf '%s\n' "workstation"
        else
            printf '%s\n' "silverblue"
        fi
        return 0
    fi
    return 1
}

function doctor_selected_flavor {
    local doctor_local_selected=""
    local doctor_local_detected=""

    case "${POSTINSTALL_FLAVOR:-}" in
    workstation | silverblue)
        doctor_local_selected="${POSTINSTALL_FLAVOR,,}"
        ;;
    esac
    doctor_local_detected=$(doctor_detect_flavor) || doctor_local_detected=""
    if [ -n "${doctor_local_selected}" ]; then
        printf '%s\n' "${doctor_local_selected}"
    else
        printf '%s\n' "${doctor_local_detected:-unknown}"
    fi
}

function doctor_check_fedora {
    local doctor_local_id=""
    local doctor_local_version=""

    doctor_local_id=$(doctor_os_release_value "ID") || doctor_local_id=""
    if [ "${doctor_local_id,,}" != "fedora" ]; then
        doctor_add_check \
            "fedora-system" "Fedora system" "error" \
            "This host is not a supported Fedora system." \
            "Detected ID: ${doctor_local_id:-unknown}"
        return 0
    fi

    doctor_local_version=$(doctor_os_release_value "VERSION_ID") ||
        doctor_local_version=""
    doctor_add_check \
        "fedora-system" "Fedora system" "ok" \
        "The host is running Fedora ${doctor_local_version:-unknown}." \
        ""
}

function doctor_check_firmware_updates {
    local doctor_local_output=""
    local doctor_local_status=0

    if ! command -v fwupdmgr >/dev/null 2>&1; then
        doctor_add_check \
            "firmware-updates" "Firmware updates" "warning" \
            "fwupdmgr is unavailable; firmware updates were not checked." \
            ""
        return 0
    fi

    doctor_local_output=$(fwupdmgr get-updates 2>&1) ||
        doctor_local_status="${?}"
    case "${doctor_local_status}" in
    0 | 2)
        ;;
    *)
        doctor_add_check \
            "firmware-updates" "Firmware updates" "error" \
            "Unable to query firmware updates." \
            "${doctor_local_output}"
        return 0
        ;;
    esac
    if [ "${doctor_local_status}" -eq 0 ] &&
        [ -n "${doctor_local_output//[[:space:]]/}" ]; then
        doctor_add_check \
            "firmware-updates" "Firmware updates" "warning" \
            "Firmware updates are available." \
            "${doctor_local_output}"
        return 0
    fi

    doctor_add_check \
        "firmware-updates" "Firmware updates" "ok" \
        "No firmware updates are available." \
        ""
}

function doctor_check_fstrim_timer {
    local doctor_local_output=""
    local doctor_local_status=0

    if ! command -v systemctl >/dev/null 2>&1; then
        doctor_add_check \
            "fstrim-timer" "SSD trim timer" "warning" \
            "systemctl is unavailable; the fstrim.timer state was not checked." \
            ""
        return 0
    fi

    doctor_local_output=$(systemctl is-enabled fstrim.timer 2>&1) ||
        doctor_local_status="${?}"
    doctor_local_output="${doctor_local_output//$'\n'/; }"
    case "${doctor_local_output}" in
    enabled | enabled-runtime | static)
        doctor_add_check \
            "fstrim-timer" "SSD trim timer" "ok" \
            "fstrim.timer is enabled (${doctor_local_output})." \
            ""
        ;;
    disabled | disabled-runtime | masked | linked | linked-runtime)
        doctor_add_check \
            "fstrim-timer" "SSD trim timer" "warning" \
            "fstrim.timer is not enabled (${doctor_local_output})." \
            ""
        ;;
    *)
        if [ "${doctor_local_status}" -eq 0 ]; then
            doctor_add_check \
                "fstrim-timer" "SSD trim timer" "warning" \
                "The fstrim.timer state is unknown (${doctor_local_output:-no output})." \
                ""
        else
            doctor_add_check \
                "fstrim-timer" "SSD trim timer" "error" \
                "Unable to determine whether fstrim.timer is enabled." \
                "${doctor_local_output}"
        fi
        ;;
    esac
}

function doctor_check_restart_required {
    local doctor_local_flavor=""
    local doctor_local_output=""
    local doctor_local_output_lower=""
    local doctor_local_status=0

    doctor_local_flavor=$(doctor_detect_flavor) || doctor_local_flavor=""
    if [ "${doctor_local_flavor}" != "workstation" ]; then
        doctor_add_check \
            "restart-required" "Pending restart" "skipped" \
            "The pending-restart check applies to Fedora Workstation only." \
            ""
        return 0
    fi

    if ! command -v dnf >/dev/null 2>&1; then
        doctor_add_check \
            "restart-required" "Pending restart" "warning" \
            "dnf is unavailable; a pending restart was not checked." \
            ""
        return 0
    fi

    doctor_local_output=$(dnf --cacheonly needs-restarting -r 2>&1) ||
        doctor_local_status="${?}"
    case "${doctor_local_status}" in
    0)
        doctor_add_check \
            "restart-required" "Pending restart" "ok" \
            "No pending system restart was reported." \
            "${doctor_local_output}"
        ;;
    1)
        doctor_local_output_lower="${doctor_local_output,,}"
        if [[ "${doctor_local_output_lower}" == *reboot* ]] &&
            { [[ "${doctor_local_output_lower}" == *required* ]] ||
                [[ "${doctor_local_output_lower}" == *pending* ]] ||
                [[ "${doctor_local_output_lower}" == *"true"* ]]; }; then
            doctor_add_check \
                "restart-required" "Pending restart" "warning" \
                "A system restart is pending." \
                "${doctor_local_output}"
        else
            doctor_add_check \
                "restart-required" "Pending restart" "error" \
                "Unable to determine whether a system restart is pending." \
                "${doctor_local_output}"
        fi
        ;;
    *)
        doctor_add_check \
            "restart-required" "Pending restart" "error" \
            "Unable to determine whether a system restart is pending." \
            "${doctor_local_output}"
        ;;
    esac
}

function doctor_check_local_bin_path {
    local doctor_local_expected="${HOME:-}/.local/bin"
    local doctor_local_expected_real=""
    local doctor_local_entry
    local doctor_local_entry_real=""
    local -a doctor_local_entries=()

    if [ -z "${HOME:-}" ]; then
        doctor_add_check \
            "local-bin-path" "User executable path" "error" \
            "HOME is not set, so ~/.local/bin cannot be checked." \
            ""
        return 0
    fi

    doctor_local_expected_real=$(realpath -m -- \
        "${doctor_local_expected}" 2>/dev/null) ||
        doctor_local_expected_real="${doctor_local_expected}"
    IFS=':' read -r -a doctor_local_entries <<<"${PATH:-}"
    for doctor_local_entry in "${doctor_local_entries[@]}"; do
        doctor_local_entry_real=$(realpath -m -- \
            "${doctor_local_entry}" 2>/dev/null) ||
            doctor_local_entry_real="${doctor_local_entry}"
        if [ "${doctor_local_entry}" = "${doctor_local_expected}" ] ||
            [ "${doctor_local_entry_real}" = "${doctor_local_expected_real}" ]; then
            if [ -d "${doctor_local_expected}" ]; then
                doctor_add_check \
                    "local-bin-path" "User executable path" "ok" \
                    "~/.local/bin is present in PATH." \
                    ""
            else
                doctor_add_check \
                    "local-bin-path" "User executable path" "warning" \
                    "~/.local/bin is in PATH, but the directory does not exist." \
                    ""
            fi
            return 0
        fi
    done

    doctor_add_check \
        "local-bin-path" "User executable path" "warning" \
        "~/.local/bin is not present in PATH." \
        ""
}

function doctor_check_snapshot_recovery {
    local doctor_local_output=""
    local doctor_local_status=0
    local doctor_local_recovery_status=""
    local doctor_local_details=""

    if ! doctor_local_output=$(doctor_snapshot_recovery_json 2>&1); then
        doctor_add_check \
            "snapshot-recovery" "Snapshot recovery" "warning" \
            "Snapshot recovery artifacts could not be inspected." \
            "${doctor_local_output}"
        return 0
    fi
    if ! doctor_local_recovery_status=$(jq -er '.status' \
        <<<"${doctor_local_output}" 2>/dev/null); then
        doctor_add_check \
            "snapshot-recovery" "Snapshot recovery" "warning" \
            "Snapshot recovery diagnostics returned invalid data." \
            "${doctor_local_output}"
        return 0
    fi

    DOCTOR_RECOVERY_JSON="${doctor_local_output}"
    doctor_local_details=$(jq -r '
        .transactions[]? |
        select(
            .status == "prepared" or
            .status == "in_progress" or
            .status == "recovery_required" or
            .status == "invalid" or
            (.kind == "selective" and .status == "committed")
        ) |
        (
            "journal=\(.journal) status=\(.status) root=\(.root // "unknown")",
            (.artifacts[]? | "artifact=\(.)")
        )
    ' <<<"${doctor_local_output}" 2>/dev/null) || doctor_local_details=""
    case "${doctor_local_recovery_status}" in
    ok)
        doctor_add_check \
            "snapshot-recovery" "Snapshot recovery" "ok" \
            "No pending snapshot recovery transactions were found." \
            "${doctor_local_details}"
        ;;
    attention)
        doctor_add_check \
            "snapshot-recovery" "Snapshot recovery" "error" \
            "Pending snapshot recovery requires attention; run 'snapshot recover'." \
            "${doctor_local_details}"
        ;;
    *)
        doctor_add_check \
            "snapshot-recovery" "Snapshot recovery" "warning" \
            "The snapshot recovery status is unknown." \
            "${doctor_local_details}"
        ;;
    esac
}

function doctor_count_status {
    local doctor_local_status="${1:-}"
    local doctor_local_count=0
    local doctor_local_index

    for ((doctor_local_index = 0; doctor_local_index < ${#DOCTOR_CHECK_STATUSES[@]}; doctor_local_index++)); do
        if [ "${DOCTOR_CHECK_STATUSES[doctor_local_index]}" = "${doctor_local_status}" ]; then
            doctor_local_count=$((doctor_local_count + 1))
        fi
    done
    printf '%s\n' "${doctor_local_count}"
}

function doctor_json {
    local doctor_local_index
    local doctor_local_check
    local doctor_local_checks="[]"
    local doctor_local_ok
    local doctor_local_warning
    local doctor_local_error
    local doctor_local_skipped
    local doctor_local_status="ok"
    local doctor_local_flavor=""
    local doctor_local_selected_flavor=""
    local doctor_local_generated

    doctor_local_ok=$(doctor_count_status "ok")
    doctor_local_warning=$(doctor_count_status "warning")
    doctor_local_error=$(doctor_count_status "error")
    doctor_local_skipped=$(doctor_count_status "skipped")
    if [ "${doctor_local_error}" -gt 0 ]; then
        doctor_local_status="error"
    elif [ "${doctor_local_warning}" -gt 0 ]; then
        doctor_local_status="warning"
    fi

    for ((doctor_local_index = 0; doctor_local_index < ${#DOCTOR_CHECK_IDS[@]}; doctor_local_index++)); do
        doctor_local_check=$(jq -cn \
            --arg id "${DOCTOR_CHECK_IDS[doctor_local_index]}" \
            --arg name "${DOCTOR_CHECK_NAMES[doctor_local_index]}" \
            --arg status "${DOCTOR_CHECK_STATUSES[doctor_local_index]}" \
            --arg message "${DOCTOR_CHECK_MESSAGES[doctor_local_index]}" \
            --arg details "${DOCTOR_CHECK_DETAILS[doctor_local_index]}" \
            '{
                id: $id,
                name: $name,
                status: $status,
                message: $message,
                details: $details
            }') || return 1
        doctor_local_checks=$(jq -cn \
            --argjson checks "${doctor_local_checks}" \
            --argjson check "${doctor_local_check}" \
            '$checks + [$check]') || return 1
    done

    doctor_local_flavor=$(doctor_detect_flavor) || doctor_local_flavor="unknown"
    doctor_local_selected_flavor=$(doctor_selected_flavor) ||
        doctor_local_selected_flavor="unknown"
    doctor_local_generated=$(date -u +'%Y-%m-%dT%H:%M:%SZ') || doctor_local_generated="unknown"
    jq -n \
        --arg generated_at "${doctor_local_generated}" \
        --arg flavor "${doctor_local_flavor}" \
        --arg selected_flavor "${doctor_local_selected_flavor}" \
        --arg status "${doctor_local_status}" \
        --argjson ok "${doctor_local_ok}" \
        --argjson warning "${doctor_local_warning}" \
        --argjson error "${doctor_local_error}" \
        --argjson skipped "${doctor_local_skipped}" \
        --argjson checks "${doctor_local_checks}" \
        --argjson snapshot_recovery "${DOCTOR_RECOVERY_JSON}" \
        '{
            schema_version: 1,
            generated_at: $generated_at,
            flavor: $flavor,
            detected_flavor: $flavor,
            host_flavor: $flavor,
            selected_flavor: $selected_flavor,
            status: $status,
            summary: {
                ok: $ok,
                warning: $warning,
                error: $error,
                skipped: $skipped
            },
            snapshot_recovery: $snapshot_recovery,
            checks: $checks
        }'
}

function doctor_render_plain {
    local doctor_local_index
    local doctor_local_line
    local doctor_local_prefix
    local doctor_local_detected_flavor=""
    local doctor_local_selected_flavor=""

    doctor_local_detected_flavor=$(doctor_detect_flavor) ||
        doctor_local_detected_flavor="unknown"
    doctor_local_selected_flavor=$(doctor_selected_flavor) ||
        doctor_local_selected_flavor="unknown"
    printf '%s\n' "Fedora post-installation doctor"
    printf '%s\n' "=============================="
    printf 'Detected flavor: %s; selected flavor: %s.\n' \
        "${doctor_local_detected_flavor}" "${doctor_local_selected_flavor}"
    if [ "${doctor_local_detected_flavor}" != "unknown" ] &&
        [ "${doctor_local_selected_flavor}" != "unknown" ] &&
        [ "${doctor_local_detected_flavor}" != "${doctor_local_selected_flavor}" ]; then
        printf '[warning] The selected flavor does not match the host flavor.\n'
    fi
    for ((doctor_local_index = 0; doctor_local_index < ${#DOCTOR_CHECK_IDS[@]}; doctor_local_index++)); do
        case "${DOCTOR_CHECK_STATUSES[doctor_local_index]}" in
        ok) doctor_local_prefix="ok" ;;
        warning) doctor_local_prefix="warning" ;;
        error) doctor_local_prefix="error" ;;
        skipped) doctor_local_prefix="skipped" ;;
        *) doctor_local_prefix="unknown" ;;
        esac
        printf '[%s] %s: %s\n' \
            "${doctor_local_prefix}" \
            "${DOCTOR_CHECK_NAMES[doctor_local_index]}" \
            "${DOCTOR_CHECK_MESSAGES[doctor_local_index]}"
        if [ -n "${DOCTOR_CHECK_DETAILS[doctor_local_index]}" ]; then
            while IFS= read -r doctor_local_line; do
                printf '    %s\n' "${doctor_local_line}"
            done <<<"${DOCTOR_CHECK_DETAILS[doctor_local_index]}"
        fi
    done
    printf '%s\n' \
        "Summary: $(doctor_count_status "ok") ok, $(doctor_count_status "warning") warning, $(doctor_count_status "error") error, $(doctor_count_status "skipped") skipped."
}

function doctor_run {
    local doctor_local_json=0
    local doctor_local_error_count=0

    while [ "$#" -gt 0 ]; do
        case "${1}" in
        --json)
            doctor_local_json=1
            shift
            ;;
        *)
            printf 'doctor: unknown option: %s\n' "${1}" >&2
            return 64
            ;;
        esac
    done

    doctor_reset
    doctor_check_fedora
    doctor_check_firmware_updates
    doctor_check_fstrim_timer
    doctor_check_restart_required
    doctor_check_local_bin_path
    doctor_check_snapshot_recovery
    doctor_local_error_count=$(doctor_count_status "error")

    if [ "${doctor_local_json}" -eq 1 ]; then
        doctor_json || return 1
    else
        doctor_render_plain || return 1
    fi

    if [ "${doctor_local_error_count}" -gt 0 ]; then
        return 1
    fi
    return 0
}
