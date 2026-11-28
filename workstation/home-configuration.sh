#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Fedora Workstation home configuration"

ui_description "Set up the managed home-directory structure and Bash configuration for Fedora Workstation."

HOME_CONFIGURATION_FLATPAKS_RETENTION_AVAILABLE=1
FLATPAKS_KEEP_CACHE_IDS=()
if [ "${FLATPAKS_KEEP_CACHE_IDS_JSON+x}" != "x" ]; then
    HOME_CONFIGURATION_FLATPAKS_RETENTION_AVAILABLE=0
    FLATPAKS_KEEP_CACHE_LIST=""
    ui_warning "Flatpak cache-retention state is unavailable; generated cleanup will not remove Flatpak application data."
elif [ -z "${FLATPAKS_KEEP_CACHE_IDS_JSON}" ]; then
    ui_error "The Flatpak cache-retention state is missing."
    return 1
else
    flatpaks_keep_cache_filter_from_state "${FLATPAKS_KEEP_CACHE_IDS_JSON}" || return $?
fi

# Use a shell-safe command name independent from the host name.
COMMAND_NAME="host_${MACHINE_NAME//[^A-Za-z0-9_]/_}"

HOME_CONFIGURATION_CANONICAL_HOME=$(realpath -e -- "${HOME}") || {
    ui_error "Unable to resolve the home directory."
    return 1
}

HIDDEN_DIRECTORY_PROMPT_STATUS=0
ui_confirm \
    "Use the recommended hidden directory (~/.${MACHINE_NAME}) or choose a custom location?" \
    "Use hidden directory" "Choose location" ||
    HIDDEN_DIRECTORY_PROMPT_STATUS="${?}"

case "${HIDDEN_DIRECTORY_PROMPT_STATUS}" in
0)
    ROOT_DIRECTORY_STRUCTURE="${HOME_CONFIGURATION_CANONICAL_HOME}/.${MACHINE_NAME}"
    ;;
1)
    ui_step "Selecting a custom configuration directory."

    HOME_CONFIGURATION_DIRECTORY_MAX_ATTEMPTS=3
    HOME_CONFIGURATION_DIRECTORY_ATTEMPT=0
    HOME_CONFIGURATION_DIRECTORY_SELECTED=0
    ROOT_DIRECTORY_STRUCTURE=""

    while [ "${HOME_CONFIGURATION_DIRECTORY_ATTEMPT}" -lt \
        "${HOME_CONFIGURATION_DIRECTORY_MAX_ATTEMPTS}" ]; do
        HOME_CONFIGURATION_DIRECTORY_ATTEMPT=$((HOME_CONFIGURATION_DIRECTORY_ATTEMPT + 1))
        SELECT_DIRECTORY=""
        HOME_CONFIGURATION_DIRECTORY_STATUS=0

        if SELECT_DIRECTORY=$(ui_select_directory "${HOME}"); then
            HOME_CONFIGURATION_DIRECTORY_STATUS=0
        else
            HOME_CONFIGURATION_DIRECTORY_STATUS="${?}"
        fi

        case "${HOME_CONFIGURATION_DIRECTORY_STATUS}" in
        0)
            if [ -z "${SELECT_DIRECTORY}" ]; then
                ui_error "No directory was selected."
                return 1
            fi
            # Validate the selected path before resolving it. Resolving a
            # final symbolic link first would erase evidence that the chosen
            # managed root is a link and allow writes through it.
            ROOT_DIRECTORY_STRUCTURE="${SELECT_DIRECTORY}"
            if validate_root_directory "${ROOT_DIRECTORY_STRUCTURE}" &&
                ROOT_DIRECTORY_STRUCTURE=$(realpath -e -- "${SELECT_DIRECTORY}") &&
                validate_root_directory_children "${ROOT_DIRECTORY_STRUCTURE}"; then
                HOME_CONFIGURATION_DIRECTORY_SELECTED=1
                break
            fi
            ;;
        1)
            ui_error "Directory selection was cancelled."
            return 1
            ;;
        *)
            ui_error "Unable to select a directory (status ${HOME_CONFIGURATION_DIRECTORY_STATUS})."
            return "${HOME_CONFIGURATION_DIRECTORY_STATUS}"
            ;;
        esac
    done

    if [ "${HOME_CONFIGURATION_DIRECTORY_SELECTED}" -ne 1 ]; then
        ui_error "Unable to select a safe configuration directory after ${HOME_CONFIGURATION_DIRECTORY_MAX_ATTEMPTS} attempts."
        return 1
    fi
    ;;
*)
    ui_error "Unable to read the directory-structure preference."
    return "${HIDDEN_DIRECTORY_PROMPT_STATUS}"
    ;;
esac

if ! validate_root_directory "${ROOT_DIRECTORY_STRUCTURE}"; then
    ui_error "The selected configuration directory is not safe to use."
    return 1
fi
if ! validate_root_directory_children "${ROOT_DIRECTORY_STRUCTURE}"; then
    ui_error "The selected configuration directory contains an unsafe managed path."
    return 1
fi

ui_text "The managed home directory will be located at ${ROOT_DIRECTORY_STRUCTURE}."

ui_step "Creating the managed directory structure."
HOME_CONFIGURATION_CREATE_STATUS=0
mkdir -p "${ROOT_DIRECTORY_STRUCTURE}" || HOME_CONFIGURATION_CREATE_STATUS="${?}"
mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/applications" || HOME_CONFIGURATION_CREATE_STATUS="${?}"
mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/config" || HOME_CONFIGURATION_CREATE_STATUS="${?}"
mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/data" || HOME_CONFIGURATION_CREATE_STATUS="${?}"
mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/profile" || HOME_CONFIGURATION_CREATE_STATUS="${?}"
mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/scripts" || HOME_CONFIGURATION_CREATE_STATUS="${?}"
mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/stuff" || HOME_CONFIGURATION_CREATE_STATUS="${?}"
mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/environments" || HOME_CONFIGURATION_CREATE_STATUS="${?}"
if [ "${HOME_CONFIGURATION_CREATE_STATUS}" -ne 0 ]; then
    ui_error "Unable to create the managed directory structure."
    return "${HOME_CONFIGURATION_CREATE_STATUS}"
fi
if ! validate_root_directory "${ROOT_DIRECTORY_STRUCTURE}" ||
    ! validate_root_directory_children "${ROOT_DIRECTORY_STRUCTURE}"; then
    ui_error "The managed directory structure became unsafe while it was created."
    return 1
fi
ui_success "Managed directory structure created."

HOME_CONFIGURATION_REPOSITORY_ROOT="${SCRIPT_PATH:-$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${HOME_CONFIGURATION_REPOSITORY_ROOT}/common/home-helpers.sh" || return 1

ui_step "Generating the managed helper scripts."
HOME_CONFIGURATION_KEEP_IDS=$(printf '%s\n' "${FLATPAKS_KEEP_CACHE_IDS[@]}")
home_helpers_render_all \
    "${ROOT_DIRECTORY_STRUCTURE}" \
    "workstation" \
    "${COMMAND_NAME}" \
    "${HOME_CONFIGURATION_FLATPAKS_RETENTION_AVAILABLE}" \
    "${HOME_CONFIGURATION_KEEP_IDS}" || return $?
ui_success "Managed helper scripts generated."

ui_step "Updating the Bash entry point."
home_helpers_update_bashrc \
    "${HOME_CONFIGURATION_CANONICAL_HOME}/.bashrc" \
    "${ROOT_DIRECTORY_STRUCTURE}" || return $?
ui_success "Bash entry point updated."

return 0
