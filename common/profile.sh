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

declare -ga PROFILE_INCLUDE=()
declare -ga PROFILE_EXCLUDE=()
declare -ga PROFILE_FLAVORS=()
declare -ga PROFILE_TOOLS=()
declare -ga PROFILE_EFFECTIVE_MODULES=()
declare -g PROFILE_EXTRAS_SELECTED=1
declare -g PROFILE_APPLIED=0

function profile_reset {
    PROFILE_INCLUDE=()
    PROFILE_EXCLUDE=()
    PROFILE_FLAVORS=()
    PROFILE_TOOLS=()
    PROFILE_EFFECTIVE_MODULES=()
    PROFILE_EXTRAS_SELECTED=1
    PROFILE_APPLIED=0
}

function profile_path_is_safe {
    local profile_local_path="${1:-}"

    [ -n "${profile_local_path}" ] &&
        [ -f "${profile_local_path}" ] &&
        [ ! -L "${profile_local_path}" ]
}

function profile_resolve_path {
    local profile_local_request="${CLI_PROFILE_REQUEST:-default}"
    local profile_local_path
    local profile_local_user_path

    if [ -n "${CLI_PROFILE_FILE}" ]; then
        profile_local_path="${CLI_PROFILE_FILE}"
    elif [[ "${profile_local_request}" == */* ]] ||
        [[ "${profile_local_request}" == *.json ]]; then
        profile_local_path="${profile_local_request}"
    else
        if ! [[ "${profile_local_request}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
            printf 'profile: invalid profile name: %s\n' "${profile_local_request}" >&2
            return 65
        fi
        profile_local_user_path="${XDG_CONFIG_HOME:-${HOME}/.config}/fedora-postinstall/profiles/${profile_local_request}.json"
        if [ -e "${profile_local_user_path}" ] || [ -L "${profile_local_user_path}" ]; then
            profile_local_path="${profile_local_user_path}"
        else
            profile_local_path="${SCRIPT_PATH}/profiles/${profile_local_request}.json"
        fi
    fi

    if [ -L "${profile_local_path}" ]; then
        printf 'profile: profile must not be a symbolic link: %s\n' \
            "${profile_local_path}" >&2
        return 65
    fi
    if ! profile_path_is_safe "${profile_local_path}"; then
        printf 'profile: profile is not a regular file: %s\n' "${profile_local_path}" >&2
        return 65
    fi
    profile_local_path=$(realpath -e -- "${profile_local_path}") || return 65
    printf '%s\n' "${profile_local_path}"
}

function profile_tool_is_registered {
    local profile_local_tool="${1:-}"
    local profile_local_registered

    for profile_local_registered in "${CLI_TOOLS_LIST[@]}"; do
        if [ "${profile_local_tool}" = "${profile_local_registered}" ]; then
            return 0
        fi
    done
    return 1
}

function profile_validate_tools {
    local profile_local_tool
    local profile_local_manifest="${SCRIPT_PATH}/extras/tools-manifest.json"

    if [ ! -f "${profile_local_manifest}" ] || [ -L "${profile_local_manifest}" ]; then
        printf 'profile: unable to load the authoritative tool manifest\n' >&2
        return 65
    fi
    for profile_local_tool in "${PROFILE_TOOLS[@]}"; do
        if ! profile_tool_is_registered "${profile_local_tool}"; then
            printf 'profile: unknown tool identifier: %s\n' "${profile_local_tool}" >&2
            return 65
        fi
        if ! jq -e --arg tool "${profile_local_tool}" \
            '.tools[$tool] | type == "object"' \
            "${profile_local_manifest}" >/dev/null; then
            printf 'profile: tool is missing from the authoritative manifest: %s\n' \
                "${profile_local_tool}" >&2
            return 65
        fi
    done
    return 0
}

function profile_load {
    local profile_local_path
    local profile_local_json
    local profile_local_tool
    local -a profile_local_items=()

    profile_reset
    profile_local_path=$(profile_resolve_path) || return $?
    if ! profile_local_json=$(python3 "${SCRIPT_PATH}/common/profile.py" \
        "${profile_local_path}"); then
        return 65
    fi

    CLI_PROFILE_FILE="${profile_local_path}"
    CLI_PROFILE_NAME=$(jq -r '.name' <<<"${profile_local_json}") || return 65
    CLI_PROFILE_DESCRIPTION=$(jq -r '.description' <<<"${profile_local_json}") || return 65
    CLI_PROFILE_DIGEST=$(sha256sum -- "${profile_local_path}") || return 65
    CLI_PROFILE_DIGEST="${CLI_PROFILE_DIGEST%% *}"
    export POSTINSTALL_PROFILE_FILE="${profile_local_path}"
    export POSTINSTALL_PROFILE="${CLI_PROFILE_NAME}"

    PROFILE_FLAVORS=()
    while IFS= read -r profile_local_item; do
        [ -n "${profile_local_item}" ] && PROFILE_FLAVORS+=("${profile_local_item}")
    done < <(jq -r '.flavors[]?' <<<"${profile_local_json}")

    PROFILE_INCLUDE=()
    while IFS= read -r profile_local_item; do
        [ -n "${profile_local_item}" ] && PROFILE_INCLUDE+=("${profile_local_item}")
    done < <(jq -r '.modules.include[]?' <<<"${profile_local_json}")

    PROFILE_EXCLUDE=()
    while IFS= read -r profile_local_item; do
        [ -n "${profile_local_item}" ] && PROFILE_EXCLUDE+=("${profile_local_item}")
    done < <(jq -r '.modules.exclude[]?' <<<"${profile_local_json}")

    PROFILE_TOOLS=()
    while IFS= read -r profile_local_tool; do
        [ -n "${profile_local_tool}" ] && PROFILE_TOOLS+=("${profile_local_tool}")
    done < <(jq -r '.extras.tools[]?' <<<"${profile_local_json}")

    source "${SCRIPT_PATH}/extras/tools-list.sh"
    profile_validate_tools || return 65

    if [ "${CLI_TOOL_SELECTION_SOURCE}" = "default" ]; then
        if jq -e 'has("extras") and (.extras | has("tools"))' \
            <<<"${profile_local_json}" >/dev/null; then
            if [ "${#PROFILE_TOOLS[@]}" -eq 0 ]; then
                CLI_TOOL_SELECTION_MODE="none"
            else
                CLI_TOOL_SELECTION_MODE="explicit"
                CLI_SELECTED_TOOLS=("${PROFILE_TOOLS[@]}")
            fi
            CLI_TOOL_SELECTION_SOURCE="profile"
        fi
    fi

    return 0
}

function profile_pattern_matches_any {
    local profile_local_module="${1:-}"
    local profile_local_pattern
    local -a profile_local_patterns=("${@:2}")

    for profile_local_pattern in "${profile_local_patterns[@]}"; do
        if runtime_module_pattern_matches "${profile_local_module}" "${profile_local_pattern}"; then
            return 0
        fi
    done
    return 1
}

function profile_validate_patterns {
    local profile_local_flavor="${1:-}"
    local profile_local_pattern
    local profile_local_match=0
    local profile_local_validation_flavor
    local profile_local_module
    local -a profile_local_modules=()
    local -a profile_local_patterns=()
    local -a profile_local_validation_flavors=()

    if [ "${#PROFILE_FLAVORS[@]}" -gt 0 ]; then
        profile_local_validation_flavors=("${PROFILE_FLAVORS[@]}")
    else
        profile_local_validation_flavors=("${profile_local_flavor}")
    fi
    profile_local_patterns=("${PROFILE_INCLUDE[@]}" "${PROFILE_EXCLUDE[@]}")

    for profile_local_pattern in "${profile_local_patterns[@]}"; do
        profile_local_match=0
        for profile_local_validation_flavor in "${profile_local_validation_flavors[@]}"; do
            mapfile -t profile_local_modules < <(
                runtime_module_inventory_modules "${profile_local_validation_flavor}"
            )
            for profile_local_module in "${profile_local_modules[@]}"; do
                if runtime_module_pattern_matches "${profile_local_module}" "${profile_local_pattern}"; then
                    profile_local_match=1
                    break
                fi
            done
            if [ "${profile_local_match}" -eq 1 ]; then
                break
            fi
        done
        if [ "${profile_local_match}" -eq 0 ] &&
            runtime_module_pattern_matches \
                "extras/additional-tools.sh" "${profile_local_pattern}"; then
            profile_local_match=1
        fi
        if [ "${profile_local_match}" -eq 0 ]; then
            printf 'profile: module pattern does not match any supported inventory: %s\n' \
                "${profile_local_pattern}" >&2
            return 65
        fi
    done
    return 0
}

function profile_module_is_excluded {
    local profile_local_module="${1:-}"

    profile_pattern_matches_any "${profile_local_module}" "${PROFILE_EXCLUDE[@]}"
}

function profile_include_selects_module {
    local profile_local_module="${1:-}"
    local profile_local_pattern
    local profile_local_include_all=0

    if [ "${#PROFILE_INCLUDE[@]}" -eq 0 ]; then
        return 0
    fi
    for profile_local_pattern in "${PROFILE_INCLUDE[@]}"; do
        if [ "${profile_local_pattern}" = "*" ]; then
            profile_local_include_all=1
            break
        fi
    done
    if [ "${profile_local_include_all}" -eq 1 ]; then
        return 0
    fi
    profile_pattern_matches_any "${profile_local_module}" "${PROFILE_INCLUDE[@]}"
}

function profile_apply_flavor {
    local profile_local_flavor="${1:-}"
    local profile_local_module
    local profile_local_dependency
    local profile_local_provider
    local profile_local_selected=0
    local profile_local_dependency_selected=0
    local -a profile_local_modules=()
    local -a profile_local_selected_modules=()
    local -a profile_local_dependencies=()
    local -a profile_local_worklist=()

    if [ -z "${profile_local_flavor}" ]; then
        printf 'profile: a Fedora flavor is required to apply a profile\n' >&2
        return 65
    fi
    if [ "${#PROFILE_FLAVORS[@]}" -gt 0 ]; then
        profile_local_selected=0
        for profile_local_provider in "${PROFILE_FLAVORS[@]}"; do
            if [ "${profile_local_provider}" = "${profile_local_flavor}" ]; then
                profile_local_selected=1
                break
            fi
        done
        if [ "${profile_local_selected}" -eq 0 ]; then
            printf 'profile: profile "%s" does not support Fedora %s\n' \
                "${CLI_PROFILE_NAME}" "${profile_local_flavor}" >&2
            return 65
        fi
    fi

    profile_validate_patterns "${profile_local_flavor}" || return 65
    mapfile -t profile_local_modules < <(runtime_module_inventory_modules "${profile_local_flavor}")

    for profile_local_module in "${profile_local_modules[@]}"; do
        if profile_include_selects_module "${profile_local_module}" &&
            ! profile_module_is_excluded "${profile_local_module}"; then
            profile_local_selected_modules+=("${profile_local_module}")
            profile_local_worklist+=("${profile_local_module}")
        fi
    done

    PROFILE_EXTRAS_SELECTED=0
    if profile_include_selects_module "extras/additional-tools.sh" &&
        ! profile_module_is_excluded "extras/additional-tools.sh"; then
        PROFILE_EXTRAS_SELECTED=1
    fi

    while [ "${#profile_local_worklist[@]}" -gt 0 ]; do
        profile_local_module="${profile_local_worklist[0]}"
        profile_local_worklist=("${profile_local_worklist[@]:1}")
        mapfile -t profile_local_dependencies < <(
            runtime_module_dependencies "${profile_local_flavor}" "${profile_local_module}"
        )
        for profile_local_dependency in "${profile_local_dependencies[@]}"; do
            if profile_module_is_excluded "${profile_local_dependency}"; then
                printf 'profile: module "%s" requires excluded module "%s"\n' \
                    "${profile_local_module}" "${profile_local_dependency}" >&2
                return 65
            fi
            profile_local_dependency_selected=0
            for profile_local_provider in "${profile_local_modules[@]}"; do
                if [ "${profile_local_provider}" = "${profile_local_dependency}" ]; then
                    profile_local_dependency_selected=1
                    break
                fi
            done
            if [ "${profile_local_dependency_selected}" -eq 0 ]; then
                printf 'profile: module "%s" requires unavailable module "%s"\n' \
                    "${profile_local_module}" "${profile_local_dependency}" >&2
                return 65
            fi
            profile_local_dependency_selected=0
            for profile_local_provider in "${profile_local_selected_modules[@]}"; do
                if [ "${profile_local_provider}" = "${profile_local_dependency}" ]; then
                    profile_local_dependency_selected=1
                    break
                fi
            done
            if [ "${profile_local_dependency_selected}" -eq 0 ]; then
                profile_local_selected_modules+=("${profile_local_dependency}")
                profile_local_worklist+=("${profile_local_dependency}")
            fi
        done
    done

    PROFILE_EFFECTIVE_MODULES=()
    for profile_local_module in "${profile_local_modules[@]}"; do
        profile_local_selected=0
        for profile_local_provider in "${profile_local_selected_modules[@]}"; do
            if [ "${profile_local_provider}" = "${profile_local_module}" ]; then
                profile_local_selected=1
                break
            fi
        done
        if [ "${profile_local_selected}" -eq 1 ]; then
            PROFILE_EFFECTIVE_MODULES+=("${profile_local_module}")
        fi
    done
    if [ "${PROFILE_EXTRAS_SELECTED}" -eq 1 ]; then
        PROFILE_EFFECTIVE_MODULES+=("extras/additional-tools.sh")
    fi

    RUNTIME_PROFILE_ENABLED=1
    RUNTIME_PROFILE_MODULES=("${PROFILE_EFFECTIVE_MODULES[@]}")
    PROFILE_APPLIED=1
    return 0
}
