#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

declare -g DETECTION_OS_ID=""
declare -g DETECTION_OS_NAME=""
declare -g DETECTION_OS_VERSION=""
declare -g DETECTION_OS_ID_LIKE=""
declare -g DETECTION_OS_VARIANT_ID=""
declare -g DETECTION_OS_IS_FEDORA=0
declare -g DETECTION_FLAVOR=""
declare -g DETECTION_FLAVOR_SOURCE=""
declare -g DETECTION_FLAVOR_CONFIDENCE="unknown"
declare -g DETECTION_FLAVOR_CONFLICT=0
declare -g DETECTION_ARCHITECTURE=""
declare -g DETECTION_ARCHITECTURE_SOURCE=""
declare -ga DETECTION_WARNINGS=()

function detection_reset {
    DETECTION_OS_ID=""
    DETECTION_OS_NAME=""
    DETECTION_OS_VERSION=""
    DETECTION_OS_ID_LIKE=""
    DETECTION_OS_VARIANT_ID=""
    DETECTION_OS_IS_FEDORA=0
    DETECTION_FLAVOR=""
    DETECTION_FLAVOR_SOURCE=""
    DETECTION_FLAVOR_CONFIDENCE="unknown"
    DETECTION_FLAVOR_CONFLICT=0
    DETECTION_ARCHITECTURE=""
    DETECTION_ARCHITECTURE_SOURCE=""
    DETECTION_WARNINGS=()
}

function detection_read_os_release {
    local detection_local_path="${1:-${POSTINSTALL_OS_RELEASE_FILE:-/etc/os-release}}"
    local detection_local_line
    local detection_local_key
    local detection_local_value

    DETECTION_OS_ID=""
    DETECTION_OS_NAME=""
    DETECTION_OS_VERSION=""
    DETECTION_OS_ID_LIKE=""
    DETECTION_OS_VARIANT_ID=""

    if [ ! -f "${detection_local_path}" ] || [ ! -r "${detection_local_path}" ]; then
        return 1
    fi

    while IFS= read -r detection_local_line || [ -n "${detection_local_line}" ]; do
        detection_local_line="${detection_local_line%$'\r'}"
        if [[ "${detection_local_line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            detection_local_key="${BASH_REMATCH[1]}"
            detection_local_value="${BASH_REMATCH[2]}"
            detection_local_value="${detection_local_value#"${detection_local_value%%[![:space:]]*}"}"
            detection_local_value="${detection_local_value%"${detection_local_value##*[![:space:]]}"}"
            if [ "${#detection_local_value}" -ge 2 ]; then
                if [[ "${detection_local_value}" == \"*\" ]] ||
                    [[ "${detection_local_value}" == \'*\' ]]; then
                    detection_local_value="${detection_local_value:1:${#detection_local_value}-2}"
                fi
            fi
            case "${detection_local_key}" in
            ID) DETECTION_OS_ID="${detection_local_value}" ;;
            NAME) DETECTION_OS_NAME="${detection_local_value}" ;;
            VERSION_ID) DETECTION_OS_VERSION="${detection_local_value}" ;;
            ID_LIKE) DETECTION_OS_ID_LIKE="${detection_local_value}" ;;
            VARIANT_ID) DETECTION_OS_VARIANT_ID="${detection_local_value}" ;;
            esac
        fi
    done <"${detection_local_path}"

    case " ${DETECTION_OS_ID,,} ${DETECTION_OS_ID_LIKE,,} " in
    *" fedora "*) DETECTION_OS_IS_FEDORA=1 ;;
    esac
    [ -n "${DETECTION_OS_ID}" ]
}

function detection_os_release_flavors {
    local detection_local_value
    local -A detection_local_seen=()

    for detection_local_value in "${DETECTION_OS_NAME}" "${DETECTION_OS_VARIANT_ID}"; do
        case "${detection_local_value,,}" in
        *silverblue*)
            if [ -z "${detection_local_seen[silverblue]:-}" ]; then
                detection_local_seen[silverblue]=1
                printf '%s\n' "silverblue"
            fi
            ;;
        *workstation*)
            if [ -z "${detection_local_seen[workstation]:-}" ]; then
                detection_local_seen[workstation]=1
                printf '%s\n' "workstation"
            fi
            ;;
        esac
    done
    return 0
}

function detection_rpm_has_package {
    local detection_local_package="${1}"
    local detection_local_output

    if ! command -v rpm >/dev/null 2>&1; then
        return 1
    fi
    detection_local_output=$(rpm -q "${detection_local_package}" 2>/dev/null) || return 1
    case "${detection_local_output}" in
    "${detection_local_package}"*) return 0 ;;
    *) return 1 ;;
    esac
}

function detection_rpm_flavors {
    local -A detection_local_seen=()

    if detection_rpm_has_package "fedora-release-identity-silverblue" ||
        detection_rpm_has_package "fedora-release-silverblue"; then
        detection_local_seen[silverblue]=1
        printf '%s\n' "silverblue"
    fi
    if detection_rpm_has_package "fedora-release-identity-workstation" ||
        detection_rpm_has_package "fedora-release-workstation"; then
        detection_local_seen[workstation]=1
        printf '%s\n' "workstation"
    fi
    return 0
}

function detection_detect_flavor {
    local detection_local_os_flavors=""
    local detection_local_rpm_flavors=""
    local detection_local_all_flavors=""
    local detection_local_flavor_count=0

    detection_reset
    if detection_read_os_release; then
        detection_local_os_flavors=$(detection_os_release_flavors)
    fi
    detection_local_rpm_flavors=$(detection_rpm_flavors)

    detection_local_all_flavors=$(
        printf '%s\n%s\n' \
            "${detection_local_os_flavors}" "${detection_local_rpm_flavors}" |
            sed '/^$/d' | sort -u
    )
    detection_local_flavor_count=$(
        printf '%s\n' "${detection_local_all_flavors}" |
            sed '/^$/d' | wc -l
    )

    if [ "${detection_local_flavor_count}" -gt 1 ]; then
        DETECTION_FLAVOR_CONFLICT=1
        DETECTION_FLAVOR_CONFIDENCE="ambiguous"
        DETECTION_WARNINGS+=(
            "Operating-system and RPM metadata report conflicting Fedora flavors; use --flavor to resolve the conflict."
        )
        return 1
    fi

    if [ "${detection_local_flavor_count}" -eq 1 ]; then
        DETECTION_FLAVOR="${detection_local_all_flavors}"
        if printf '%s\n' "${detection_local_os_flavors}" |
            grep -Fxq "${DETECTION_FLAVOR}"; then
            DETECTION_FLAVOR_SOURCE="os-release"
        else
            DETECTION_FLAVOR_SOURCE="rpm"
        fi
        DETECTION_FLAVOR_CONFIDENCE="high"
        return 0
    fi

    DETECTION_FLAVOR_CONFIDENCE="unknown"
    return 1
}

function detection_detect_architecture {
    local detection_local_machine

    detection_local_machine=$(uname -m) || return 1
    if ! DETECTION_ARCHITECTURE=$(runtime_normalize_architecture "${detection_local_machine}"); then
        DETECTION_ARCHITECTURE=""
        return 1
    fi
    DETECTION_ARCHITECTURE_SOURCE="uname"
    return 0
}

function detection_resolve_architecture {
    local detection_local_selected

    if [ -n "${CLI_ARCHITECTURE}" ]; then
        printf '%s\n' "${CLI_ARCHITECTURE}"
        return 0
    fi
    if ! detection_local_selected=$(runtime_detect_architecture); then
        printf 'cli: unable to detect a supported architecture\n' >&2
        return 69
    fi
    CLI_ARCHITECTURE="${detection_local_selected}"
    printf '%s\n' "${CLI_ARCHITECTURE}"
}

function detection_resolve_flavor {
    local detection_local_selected

    if [ -n "${CLI_FLAVOR}" ]; then
        printf '%s\n' "${CLI_FLAVOR}"
        return 0
    fi

    if ! detection_detect_flavor; then
        if [ "${DETECTION_FLAVOR_CONFLICT}" -eq 1 ]; then
            printf 'cli: Fedora flavor detection is ambiguous; use --flavor to select workstation or silverblue\n' >&2
            return 69
        fi
        printf 'cli: unable to detect Fedora flavor; use --flavor to select workstation or silverblue\n' >&2
        return 69
    fi

    detection_local_selected="${DETECTION_FLAVOR}"
    CLI_FLAVOR="${detection_local_selected}"
    printf '%s\n' "${CLI_FLAVOR}"
}

function detection_render {
    local detection_local_selected_flavor="${CLI_FLAVOR}"
    local detection_local_selected_architecture="${CLI_ARCHITECTURE}"
    local detection_local_flavor_mismatch=0
    local detection_local_architecture_mismatch=0
    local detection_local_warning
    local detection_local_json_warnings='[]'

    detection_detect_flavor || true
    detection_detect_architecture || true

    if [ -z "${detection_local_selected_flavor}" ] &&
        [ -n "${DETECTION_FLAVOR}" ]; then
        detection_local_selected_flavor="${DETECTION_FLAVOR}"
    fi
    if [ -z "${detection_local_selected_architecture}" ] &&
        [ -n "${DETECTION_ARCHITECTURE}" ]; then
        detection_local_selected_architecture="${DETECTION_ARCHITECTURE}"
    fi

    if [ -n "${CLI_FLAVOR_EXPLICIT}" ] && [ "${CLI_FLAVOR_EXPLICIT}" -eq 1 ] &&
        [ -n "${DETECTION_FLAVOR}" ] && [ "${CLI_FLAVOR}" != "${DETECTION_FLAVOR}" ]; then
        detection_local_flavor_mismatch=1
        DETECTION_WARNINGS+=(
            "The selected flavor differs from the automatically detected flavor."
        )
    fi
    if [ "${CLI_ARCHITECTURE_EXPLICIT}" -eq 1 ] &&
        [ -n "${DETECTION_ARCHITECTURE}" ] &&
        [ "${CLI_ARCHITECTURE}" != "${DETECTION_ARCHITECTURE}" ]; then
        detection_local_architecture_mismatch=1
        DETECTION_WARNINGS+=(
            "The selected architecture differs from the detected host architecture."
        )
    fi

    CLI_FLAVOR="${detection_local_selected_flavor}"
    CLI_ARCHITECTURE="${detection_local_selected_architecture}"

    if [ "${CLI_JSON}" -eq 1 ]; then
        for detection_local_warning in "${DETECTION_WARNINGS[@]}"; do
            detection_local_json_warnings=$(jq -c \
                --arg warning "${detection_local_warning}" \
                '. + [$warning]' <<<"${detection_local_json_warnings}") || return 1
        done
        jq -n \
            --arg os_id "${DETECTION_OS_ID}" \
            --arg os_name "${DETECTION_OS_NAME}" \
            --arg os_version "${DETECTION_OS_VERSION}" \
            --argjson is_fedora "${DETECTION_OS_IS_FEDORA}" \
            --arg detected_flavor "${DETECTION_FLAVOR}" \
            --arg flavor_source "${DETECTION_FLAVOR_SOURCE}" \
            --arg flavor_confidence "${DETECTION_FLAVOR_CONFIDENCE}" \
            --arg selected_flavor "${detection_local_selected_flavor}" \
            --arg detected_architecture "${DETECTION_ARCHITECTURE}" \
            --arg selected_architecture "${detection_local_selected_architecture}" \
            --argjson flavor_mismatch "${detection_local_flavor_mismatch}" \
            --argjson architecture_mismatch "${detection_local_architecture_mismatch}" \
            --argjson warnings "${detection_local_json_warnings}" \
            '{
                schema_version: 1,
                os: {
                    id: $os_id,
                    name: $os_name,
                    version: $os_version,
                    is_fedora: $is_fedora
                },
                flavor: {
                    detected: $detected_flavor,
                    selected: $selected_flavor,
                    source: $flavor_source,
                    confidence: $flavor_confidence,
                    mismatch: $flavor_mismatch
                },
                architecture: {
                    detected: $detected_architecture,
                    selected: $selected_architecture,
                    mismatch: $architecture_mismatch
                },
                warnings: $warnings
            }'
        return 0
    fi

    printf 'Operating system: %s\n' "${DETECTION_OS_NAME:-unknown}"
    printf 'Version: %s\n' "${DETECTION_OS_VERSION:-unknown}"
    printf 'Fedora: %s\n' "$([ "${DETECTION_OS_IS_FEDORA}" -eq 1 ] && printf 'yes' || printf 'no')"
    printf 'Detected flavor: %s\n' "${DETECTION_FLAVOR:-unknown}"
    printf 'Selected flavor: %s\n' "${detection_local_selected_flavor:-unknown}"
    printf 'Flavor source: %s\n' "${DETECTION_FLAVOR_SOURCE:-unknown}"
    printf 'Flavor confidence: %s\n' "${DETECTION_FLAVOR_CONFIDENCE}"
    printf 'Detected architecture: %s\n' "${DETECTION_ARCHITECTURE:-unknown}"
    printf 'Selected architecture: %s\n' "${detection_local_selected_architecture:-unknown}"
    for detection_local_warning in "${DETECTION_WARNINGS[@]}"; do
        printf 'Warning: %s\n' "${detection_local_warning}"
    done
}
