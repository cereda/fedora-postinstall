#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

if ! declare -F ui_input >/dev/null; then
    VALIDATION_UI_DIRECTORY="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" &&
        pwd -P)" || return 1
    source "${VALIDATION_UI_DIRECTORY}/ui.sh" || return 1
    source "${VALIDATION_UI_DIRECTORY}/ui-prompts.sh" || return 1
fi

function is_valid_hostname {
    [[ "${1}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

function is_valid_container_name {
    [[ "${1}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$ ]]
}

function is_valid_flatpak_application_id {
    [[ "${1}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*(\.[A-Za-z0-9][A-Za-z0-9_-]*)*$ ]]
}

function flatpaks_keep_cache_state_from_ids {
    local flatpaks_local_id
    local flatpaks_local_state=""

    for flatpaks_local_id in "$@"; do
        if ! is_valid_flatpak_application_id "${flatpaks_local_id}"; then
            ui_error "Invalid Flatpak application identifier: ${flatpaks_local_id}."
            return 1
        fi
    done

    flatpaks_local_state=$(jq -nc --args '$ARGS.positional' -- "$@") || return 1
    printf '%s\n' "${flatpaks_local_state}"
}

function flatpaks_keep_cache_filter_from_state {
    local flatpaks_local_state="${1:-[]}"
    local flatpaks_local_id

    if ! jq -e '
        type == "array" and
        all(.[];
            type == "string" and
            test("^[A-Za-z0-9][A-Za-z0-9_-]*(\\.[A-Za-z0-9][A-Za-z0-9_-]*)*$")
        )
    ' >/dev/null <<<"${flatpaks_local_state}"; then
        ui_error "The saved Flatpak cache-retention state is invalid."
        return 1
    fi

    FLATPAKS_KEEP_CACHE_LIST=""
    while IFS= read -r flatpaks_local_id; do
        [ -n "${flatpaks_local_id}" ] || continue
        FLATPAKS_KEEP_CACHE_LIST+=" -not -name ${flatpaks_local_id}"
    done < <(jq -r '.[]' <<<"${flatpaks_local_state}")
}

function is_valid_git_name {
    [[ -n "${1}" && "${1}" != *$'\n'* && "${1}" != *$'\r'* ]]
}

function is_valid_git_email {
    [[ "${1}" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]]
}

function is_valid_root_directory {
    local candidate="${1}"
    local canonical_home
    local canonical_parent
    local canonical_candidate
    local candidate_parent
    local candidate_name

    canonical_home=$(realpath -e -- "${HOME}") || return 1
    candidate_parent=$(dirname -- "${candidate}")
    candidate_name=$(basename -- "${candidate}")
    [[ "${candidate_name}" != "." && "${candidate_name}" != ".." ]] || return 1
    canonical_parent=$(realpath -e -- "${candidate_parent}") || return 1
    canonical_candidate="${canonical_parent}/${candidate_name}"

    [[ "${canonical_candidate}" == "${canonical_home}" || "${canonical_candidate}" == "${canonical_home}/"* ]] || return 1
    [[ "${canonical_candidate}" =~ ^/[A-Za-z0-9_./-]+$ ]] || return 1

    if [ -d "${canonical_candidate}" ]; then
        [[ -w "${canonical_candidate}" ]] || return 1
    else
        [[ -w "${canonical_parent}" ]] || return 1
    fi
}

function validate_root_directory {
    local candidate="${1}"

    if ! is_valid_root_directory "${candidate}"; then
        ui_warning "The configuration directory must be an existing writable directory under ${HOME} and contain only letters, digits, dots, underscores, slashes, and hyphens."
        return 1
    fi
}

function prompt_valid_hostname {
    local value
    local status=0

    while true; do
        if value=$(ui_input "Your machine name: "); then
            status=0
        else
            status="${?}"
        fi
        if [ "${status}" -ne 0 ]; then
            return "${status}"
        fi
        if is_valid_hostname "${value}"; then
            printf '%s\n' "${value}"
            return 0
        fi

        ui_warning "Invalid hostname. Use 1-63 letters, digits, or hyphens; it must not start or end with a hyphen."
    done
}

function prompt_valid_container_name {
    local prompt="${1}"
    local default="${2:-}"
    local value
    local status=0

    while true; do
        if value=$(ui_input "${prompt}" "${default}"); then
            status=0
        else
            status="${?}"
        fi
        if [ "${status}" -ne 0 ]; then
            return "${status}"
        fi

        if is_valid_container_name "${value}"; then
            printf '%s\n' "${value}"
            return 0
        fi

        ui_warning "Invalid container name. Use 1-63 letters, digits, dots, underscores, or hyphens."
    done
}

function prompt_valid_git_name {
    local value
    local status=0

    while true; do
        if value=$(ui_input "Your full name: "); then
            status=0
        else
            status="${?}"
        fi
        if [ "${status}" -ne 0 ]; then
            return "${status}"
        fi
        if is_valid_git_name "${value}"; then
            printf '%s\n' "${value}"
            return 0
        fi

        ui_warning "The Git user name cannot be empty or contain line breaks."
    done
}

function prompt_valid_git_email {
    local value
    local status=0

    while true; do
        if value=$(ui_input "Your email address: "); then
            status=0
        else
            status="${?}"
        fi
        if [ "${status}" -ne 0 ]; then
            return "${status}"
        fi
        if is_valid_git_email "${value}"; then
            printf '%s\n' "${value}"
            return 0
        fi

        ui_warning "Invalid email address. Use a non-empty address in the form user@example.com."
    done
}
