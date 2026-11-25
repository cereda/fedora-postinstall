#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

declare -g PLAN_FLAVOR=""
declare -g PLAN_ARCHITECTURE=""
declare -g PLAN_COMMAND="plan"
declare -g PLAN_CACHE_DIR=""
declare -g PLAN_LOCK_FILE=""
declare -ga PLAN_WARNINGS=()
declare -ga PLAN_TOOL_DETAILS=()

function plan_report_error {
    local plan_local_message="${1:-}"
    local plan_local_plain_message="${2:-${plan_local_message}}"

    if declare -F ui_error >/dev/null; then
        ui_error "${plan_local_message}"
        return $?
    fi
    printf 'plan: %s\n' "${plan_local_plain_message}" >&2
}

function plan_tool_is_registered {
    local plan_local_tool="${1:-}"
    local plan_local_registered

    for plan_local_registered in "${CLI_TOOLS_LIST[@]}"; do
        if [ "${plan_local_tool}" = "${plan_local_registered}" ]; then
            return 0
        fi
    done
    return 1
}

function plan_manifest_entry {
    local plan_local_tool="${1:-}"
    local plan_local_architecture="${2:-}"

    case "${plan_local_architecture}" in
    x86_64 | aarch64) ;;
    *)
        printf 'plan: unsupported canonical architecture key: %s\n' \
            "${plan_local_architecture}" >&2
        return 1
        ;;
    esac

    jq -ce --arg tool "${plan_local_tool}" --arg architecture "${plan_local_architecture}" \
        '.tools[$tool].assets[$architecture] // .tools[$tool].assets.any // empty' \
        "${SCRIPT_PATH}/extras/tools-manifest.json"
}

function plan_resolve_tools {
    local plan_local_architecture="${1:-}"
    local plan_local_tool
    local plan_local_registered
    local plan_local_entry
    local plan_local_status=0
    local -a plan_local_ordered=()

    source "${SCRIPT_PATH}/extras/tools-list.sh"
    source "${SCRIPT_PATH}/extras/tools-download.sh"
    source "${SCRIPT_PATH}/extras/tools-unpacking.sh"
    EXTRAS_MANIFEST_FILE="${SCRIPT_PATH}/extras/tools-manifest.json"
    EXTRAS_ARCHITECTURE="${plan_local_architecture}"
    PLAN_TOOL_DETAILS=()

    if ! extras_validate_manifest_file; then
        return 69
    fi

    case "${CLI_TOOL_SELECTION_MODE}" in
    interactive | none)
        CLI_SELECTED_TOOLS=()
        return 0
        ;;
    all)
        CLI_SELECTED_TOOLS=()
        for plan_local_registered in "${CLI_TOOLS_LIST[@]}"; do
            if plan_local_entry=$(plan_manifest_entry \
                "${plan_local_registered}" "${plan_local_architecture}"); then
                if ! extras_validate_manifest_entry \
                    "${plan_local_registered}" "${plan_local_architecture}"; then
                    return 69
                fi
                CLI_SELECTED_TOOLS+=("${plan_local_registered}")
            fi
        done
        ;;
    explicit)
        for plan_local_tool in "${CLI_SELECTED_TOOLS[@]}"; do
            if ! plan_tool_is_registered "${plan_local_tool}"; then
                plan_report_error \
                    "Unknown command-line tool identifier: ${plan_local_tool}." \
                    "unknown tool identifier: ${plan_local_tool}"
                return 69
            fi
            if ! plan_local_entry=$(plan_manifest_entry \
                "${plan_local_tool}" "${plan_local_architecture}"); then
                plan_report_error \
                    "Command-line tool ${plan_local_tool} is not available for architecture ${plan_local_architecture}." \
                    "tool \"${plan_local_tool}\" is not available for architecture ${plan_local_architecture}"
                return 69
            fi
            if ! extras_validate_manifest_entry \
                "${plan_local_tool}" "${plan_local_architecture}"; then
                return 69
            fi
        done
        ;;
    *)
        plan_report_error \
            "Invalid command-line tool selection mode: ${CLI_TOOL_SELECTION_MODE}." \
            "invalid tool selection mode: ${CLI_TOOL_SELECTION_MODE}"
        return 69
        ;;
    esac

    for plan_local_registered in "${CLI_TOOLS_LIST[@]}"; do
        for plan_local_tool in "${CLI_SELECTED_TOOLS[@]}"; do
            if [ "${plan_local_registered}" = "${plan_local_tool}" ]; then
                plan_local_ordered+=("${plan_local_tool}")
                break
            fi
        done
    done
    CLI_SELECTED_TOOLS=("${plan_local_ordered[@]}")

    extras_validate_selected_tools "${CLI_SELECTED_TOOLS[@]}" || {
        plan_local_status="${?}"
        return "${plan_local_status}"
    }

    for plan_local_tool in "${CLI_SELECTED_TOOLS[@]}"; do
        plan_local_entry=$(plan_manifest_entry \
            "${plan_local_tool}" "${plan_local_architecture}") || return 69
        PLAN_TOOL_DETAILS+=("${plan_local_entry}")
    done
    return 0
}

function plan_prepare {
    local plan_local_command="${1:-plan}"
    local plan_local_flavor=""
    local plan_local_architecture=""

    PLAN_COMMAND="${plan_local_command}"
    PLAN_CACHE_DIR="${CLI_CACHE_DIR}"
    PLAN_LOCK_FILE="${CLI_LOCK_FILE}"
    PLAN_WARNINGS=()
    PLAN_TOOL_DETAILS=()
    PROFILE_EFFECTIVE_MODULES=()
    PROFILE_EXTRAS_SELECTED=0

    if [ "${plan_local_command}" = "extras" ]; then
        plan_local_architecture=$(detection_resolve_architecture) || return $?
        PLAN_ARCHITECTURE="${plan_local_architecture}"
        PROFILE_EXTRAS_SELECTED=1
        PROFILE_EFFECTIVE_MODULES=("extras/additional-tools.sh")
        plan_resolve_tools "${PLAN_ARCHITECTURE}" || return $?
        return 0
    fi

    plan_local_flavor=$(detection_resolve_flavor) || return $?
    plan_local_architecture=$(detection_resolve_architecture) || return $?
    PLAN_FLAVOR="${plan_local_flavor}"
    PLAN_ARCHITECTURE="${plan_local_architecture}"

    profile_load || return $?
    profile_apply_flavor "${PLAN_FLAVOR}" || return $?
    plan_resolve_tools "${PLAN_ARCHITECTURE}" || return $?

    detection_detect_flavor || true
    if [ "${CLI_FLAVOR_EXPLICIT}" -eq 1 ] &&
        [ -n "${DETECTION_FLAVOR}" ] &&
        [ "${CLI_FLAVOR}" != "${DETECTION_FLAVOR}" ]; then
        PLAN_WARNINGS+=(
            "The selected flavor differs from the automatically detected flavor."
        )
    fi

    detection_detect_architecture || true
    if [ "${CLI_ARCHITECTURE_EXPLICIT}" -eq 1 ] &&
        [ -n "${DETECTION_ARCHITECTURE}" ] &&
        [ "${CLI_ARCHITECTURE}" != "${DETECTION_ARCHITECTURE}" ]; then
        PLAN_WARNINGS+=(
            "The selected architecture differs from the detected host architecture."
        )
    fi
    return 0
}

function plan_module_is_selected {
    local plan_local_module="${1:-}"
    local plan_local_selected

    for plan_local_selected in "${PROFILE_EFFECTIVE_MODULES[@]}"; do
        if [ "${plan_local_selected}" = "${plan_local_module}" ]; then
            return 0
        fi
    done
    return 1
}

function plan_build_module_json {
    local plan_local_flavor="${1:-}"
    local plan_local_module
    local plan_local_effect
    local plan_local_states
    local plan_local_selected
    local plan_local_action
    local plan_local_json='[]'

    if [ "${PLAN_COMMAND}" != "extras" ]; then
        while IFS='|' read -r plan_local_module plan_local_effect plan_local_states; do
            [ -n "${plan_local_module}" ] || continue
            if plan_module_is_selected "${plan_local_module}"; then
                plan_local_selected=true
                case "${plan_local_effect}" in
                read-only) plan_local_action="load" ;;
                orchestrator) plan_local_action="run" ;;
                *) plan_local_action="run" ;;
                esac
            else
                plan_local_selected=false
                plan_local_action="skip-profile"
            fi
            plan_local_json=$(jq -c \
                --arg path "${plan_local_module}" \
                --arg effect "${plan_local_effect}" \
                --arg action "${plan_local_action}" \
                --argjson selected "${plan_local_selected}" \
                '. + [{path: $path, effect: $effect, selected: $selected, action: $action}]' \
                <<<"${plan_local_json}") || return 1
        done < <(runtime_module_inventory_rows "${plan_local_flavor}")
    fi

    if plan_module_is_selected "extras/additional-tools.sh"; then
        case "${CLI_TOOL_SELECTION_MODE}" in
        none) plan_local_action="skip-none" ;;
        interactive) plan_local_action="choose" ;;
        all | explicit) plan_local_action="run" ;;
        *) plan_local_action="run" ;;
        esac
        plan_local_selected=true
    else
        plan_local_selected=false
        plan_local_action="skip-profile"
    fi
    plan_local_json=$(jq -c \
        --arg path "extras/additional-tools.sh" \
        --arg effect "mutating" \
        --arg action "${plan_local_action}" \
        --argjson selected "${plan_local_selected}" \
        '. + [{path: $path, effect: $effect, selected: $selected, action: $action}]' \
        <<<"${plan_local_json}") || return 1

    printf '%s\n' "${plan_local_json}"
}

function plan_build_tool_json {
    local plan_local_tool
    local plan_local_entry
    local plan_local_json='[]'

    for plan_local_tool in "${CLI_SELECTED_TOOLS[@]}"; do
        plan_local_entry=$(plan_manifest_entry "${plan_local_tool}" "${PLAN_ARCHITECTURE}") || return 1
        plan_local_json=$(jq -c \
            --arg id "${plan_local_tool}" \
            --arg version "$(jq -r --arg tool "${plan_local_tool}" '.tools[$tool].version' \
                "${SCRIPT_PATH}/extras/tools-manifest.json")" \
            --argjson entry "${plan_local_entry}" \
            '. + [{
                id: $id,
                version: $version,
                url: $entry.url,
                sha256: $entry.sha256,
                type: $entry.type,
                files: ($entry.files | to_entries | map({source: .key, target: .value}))
            }]' <<<"${plan_local_json}") || return 1
    done
    printf '%s\n' "${plan_local_json}"
}

function plan_render {
    local plan_local_flavor="${PLAN_FLAVOR}"
    local plan_local_module
    local plan_local_effect
    local plan_local_states
    local plan_local_selected
    local plan_local_action
    local plan_local_warning
    local plan_local_modules_json
    local plan_local_tools_json
    local plan_local_warnings_json='[]'
    local plan_local_detected_flavor=""
    local plan_local_detected_architecture=""
    local plan_local_profile_name="${CLI_PROFILE_NAME:-default}"
    local plan_local_profile_path="${CLI_PROFILE_FILE:-}"
    local plan_local_profile_digest="${CLI_PROFILE_DIGEST:-}"

    detection_detect_flavor || true
    detection_detect_architecture || true
    plan_local_detected_flavor="${DETECTION_FLAVOR}"
    plan_local_detected_architecture="${DETECTION_ARCHITECTURE}"

    plan_local_modules_json=$(plan_build_module_json "${plan_local_flavor}") || return 1
    plan_local_tools_json=$(plan_build_tool_json) || return 1

    for plan_local_warning in "${PLAN_WARNINGS[@]}" "${DETECTION_WARNINGS[@]}"; do
        [ -n "${plan_local_warning}" ] || continue
        plan_local_warnings_json=$(jq -c \
            --arg warning "${plan_local_warning}" \
            '. + [$warning]' <<<"${plan_local_warnings_json}") || return 1
    done

    if [ "${CLI_JSON}" -eq 1 ]; then
        jq -n \
            --arg command "${PLAN_COMMAND}" \
            --arg os_id "${DETECTION_OS_ID}" \
            --arg os_name "${DETECTION_OS_NAME}" \
            --arg os_version "${DETECTION_OS_VERSION}" \
            --arg detected_flavor "${plan_local_detected_flavor}" \
            --arg selected_flavor "${plan_local_flavor}" \
            --arg detected_architecture "${plan_local_detected_architecture}" \
            --arg selected_architecture "${PLAN_ARCHITECTURE}" \
            --arg profile_name "${plan_local_profile_name}" \
            --arg profile_path "${plan_local_profile_path}" \
            --arg profile_digest "${plan_local_profile_digest}" \
            --arg cache_dir "${PLAN_CACHE_DIR}" \
            --arg lock_file "${PLAN_LOCK_FILE}" \
            --arg tool_mode "${CLI_TOOL_SELECTION_MODE}" \
            --argjson modules "${plan_local_modules_json}" \
            --argjson tools "${plan_local_tools_json}" \
            --argjson warnings "${plan_local_warnings_json}" \
            '{
                schema_version: 1,
                command: $command,
                dry_run: true,
                os: {id: $os_id, name: $os_name, version: $os_version},
                flavor: {detected: $detected_flavor, selected: $selected_flavor},
                architecture: {detected: $detected_architecture, selected: $selected_architecture},
                profile: {name: $profile_name, path: $profile_path, digest: $profile_digest},
                paths: {cache_dir: $cache_dir, lock_file: $lock_file},
                modules: $modules,
                extras: {mode: $tool_mode, tools: $tools},
                warnings: $warnings
            }'
        return 0
    fi

    printf 'Fedora post-installation plan\n'
    printf 'Command: %s\n' "${PLAN_COMMAND}"
    printf 'Operating system: %s\n' "${DETECTION_OS_NAME:-unknown}"
    printf 'Version: %s\n' "${DETECTION_OS_VERSION:-unknown}"
    printf 'Detected flavor: %s\n' "${plan_local_detected_flavor:-unknown}"
    printf 'Selected flavor: %s\n' "${plan_local_flavor:-not-applicable}"
    printf 'Detected architecture: %s\n' "${plan_local_detected_architecture:-unknown}"
    printf 'Selected architecture: %s\n' "${PLAN_ARCHITECTURE}"
    printf 'Profile: %s\n' "${plan_local_profile_name}"
    if [ -n "${plan_local_profile_path}" ]; then
        printf 'Profile path: %s\n' "${plan_local_profile_path}"
    fi
    printf 'Cache directory: %s\n' "${PLAN_CACHE_DIR}"
    printf 'Lock file: %s\n' "${PLAN_LOCK_FILE}"
    printf 'Modules:\n'
    if [ "${PLAN_COMMAND}" != "extras" ]; then
        while IFS='|' read -r plan_local_module plan_local_effect plan_local_states; do
            [ -n "${plan_local_module}" ] || continue
            if plan_module_is_selected "${plan_local_module}"; then
                plan_local_selected="yes"
                case "${plan_local_effect}" in
                read-only) plan_local_action="load" ;;
                *) plan_local_action="run" ;;
                esac
            else
                plan_local_selected="no"
                plan_local_action="skip-profile"
            fi
            printf '  %-6s %-11s %s\n' \
                "${plan_local_action}" "${plan_local_effect}" "${plan_local_module}"
        done < <(runtime_module_inventory_rows "${plan_local_flavor}")
    fi

    if plan_module_is_selected "extras/additional-tools.sh"; then
        case "${CLI_TOOL_SELECTION_MODE}" in
        none) plan_local_action="skip-none" ;;
        interactive) plan_local_action="choose" ;;
        all | explicit) plan_local_action="run" ;;
        *) plan_local_action="run" ;;
        esac
        printf '  %-6s %-11s %s\n' \
            "${plan_local_action}" "mutating" "extras/additional-tools.sh"
    else
        printf '  %-6s %-11s %s\n' \
            "skip-profile" "mutating" "extras/additional-tools.sh"
    fi
    printf 'Extras selection: %s\n' "${CLI_TOOL_SELECTION_MODE}"
    for plan_local_tool in "${CLI_SELECTED_TOOLS[@]}"; do
        printf '  %s\n' "${plan_local_tool}"
    done
    for plan_local_warning in "${PLAN_WARNINGS[@]}" "${DETECTION_WARNINGS[@]}"; do
        [ -n "${plan_local_warning}" ] || continue
        printf 'Warning: %s\n' "${plan_local_warning}"
    done
}
