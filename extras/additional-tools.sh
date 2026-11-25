#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

if ! declare -F ui_section >/dev/null; then
    EXTRAS_UI_DIRECTORY="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../common" &&
        pwd -P)" || return 1
    source "${EXTRAS_UI_DIRECTORY}/ui.sh" || return 1
    source "${EXTRAS_UI_DIRECTORY}/ui-prompts.sh" || return 1
fi

source "extras/tools-list.sh"
source "extras/tools-download.sh"
source "extras/tools-unpacking.sh"
source "extras/tools-deployment.sh"

ui_section "Command-line tools"

ui_description "Install selected command-line tools from the pinned manifest."

function extras_cleanup_workspace {
    local EXTRAS_CLEANUP_STATUS=0
    local EXTRAS_CLEANUP_COMMAND_STATUS=0

    if declare -F extras_cleanup_deployment_temporaries >/dev/null; then
        extras_cleanup_deployment_temporaries || {
            EXTRAS_CLEANUP_COMMAND_STATUS="${?}"
            if [ "${EXTRAS_CLEANUP_STATUS}" -eq 0 ]; then
                EXTRAS_CLEANUP_STATUS="${EXTRAS_CLEANUP_COMMAND_STATUS}"
            fi
        }
    fi

    if declare -F extras_rollback_deployment >/dev/null &&
        [ "${EXTRAS_DEPLOYMENT_COMPLETE:-0}" -ne 1 ]; then
        extras_rollback_deployment || {
            EXTRAS_CLEANUP_COMMAND_STATUS="${?}"
            ui_error "The command-line tool deployment could not be fully rolled back. Recovery backups, when available, remain in ${EXTRAS_DEPLOYMENT_BACKUP_DIRECTORY}."
            if [ "${EXTRAS_CLEANUP_STATUS}" -eq 0 ]; then
                EXTRAS_CLEANUP_STATUS="${EXTRAS_CLEANUP_COMMAND_STATUS}"
            fi
        }
    elif [ -n "${EXTRAS_DEPLOYMENT_BACKUP_DIRECTORY:-}" ] &&
        [ -d "${EXTRAS_DEPLOYMENT_BACKUP_DIRECTORY}" ]; then
        rm -rf -- "${EXTRAS_DEPLOYMENT_BACKUP_DIRECTORY}" || {
            EXTRAS_CLEANUP_COMMAND_STATUS="${?}"
            ui_warning "Could not remove the command-line tool recovery backups in ${EXTRAS_DEPLOYMENT_BACKUP_DIRECTORY}. The recovery backups were left in place."
            if [ "${EXTRAS_CLEANUP_STATUS}" -eq 0 ]; then
                EXTRAS_CLEANUP_STATUS="${EXTRAS_CLEANUP_COMMAND_STATUS}"
            fi
        }
    fi

    if [ -n "${EXTRAS_WORKSPACE:-}" ] &&
        [ -d "${EXTRAS_WORKSPACE}" ] &&
        [[ "${EXTRAS_WORKSPACE}" == "${EXTRAS_WORKSPACE_ROOT}/fedora-postinstall-extras."* ]]; then
        rm -rf -- "${EXTRAS_WORKSPACE}" || {
            EXTRAS_CLEANUP_COMMAND_STATUS="${?}"
            ui_error "Could not remove the command-line tool temporary workspace ${EXTRAS_WORKSPACE}."
            if [ "${EXTRAS_CLEANUP_STATUS}" -eq 0 ]; then
                EXTRAS_CLEANUP_STATUS="${EXTRAS_CLEANUP_COMMAND_STATUS}"
            fi
        }
    fi

    return "${EXTRAS_CLEANUP_STATUS}"
}

function extras_tool_is_registered {
    local selected="${1}"
    local registered

    for registered in "${CLI_TOOLS_LIST[@]}"; do
        if [ "${selected}" = "${registered}" ]; then
            return 0
        fi
    done

    return 1
}

EXTRAS_MANIFEST_FILE="${SCRIPT_PATH}/extras/tools-manifest.json"
if ! extras_validate_manifest_file; then
    ui_error "Could not load the command-line tool manifest. No command-line tools were installed."
    return 1
fi
if ! EXTRAS_ARCHITECTURE=$(extras_detect_architecture); then
    ui_error "Command-line tools do not support architecture ${POSTINSTALL_ARCHITECTURE:-$(uname -m)}. No command-line tools were installed."
    return 1
fi

CLI_TOOLS_AVAILABLE=()
while IFS= read -r available_tool; do
    [ -n "${available_tool}" ] && CLI_TOOLS_AVAILABLE+=("${available_tool}")
done < <(extras_available_tools_for_architecture "${EXTRAS_ARCHITECTURE}")

# Explicit selections come from the validated CLI/profile layer. Interactive
# selection remains the default for the extras flow.
CLI_TOOLS_TO_INSTALL=()
case "${POSTINSTALL_TOOL_SELECTION_MODE:-interactive}" in
none)
    CLI_TOOLS_SELECTION="-"
    ui_skip "No command-line tools were selected."
    return 0
    ;;
explicit | all)
    CLI_TOOLS_TO_INSTALL=("${CLI_SELECTED_TOOLS[@]}")
    ;;
interactive)
    if [ "${#CLI_TOOLS_AVAILABLE[@]}" -eq 0 ]; then
        ui_error "Command-line tools are not available for architecture ${EXTRAS_ARCHITECTURE}. Check the manifest and try again."
        return 1
    fi

    confirm_status=0
    ui_confirm \
        "Would you like to install any command-line tools?" \
        "Install" \
        "Skip" || confirm_status="${?}"
    if [ "${confirm_status}" -eq 1 ]; then
        CLI_TOOLS_SELECTION="-"
        ui_skip "Command-line tool installation was skipped."
        return 0
    fi
    if [ "${confirm_status}" -ne 0 ]; then
        return "${confirm_status}"
    fi

    # Only identifiers from the authoritative registry are accepted; arbitrary
    # terminal output never becomes a path.
    selection_status=0
    selection=$(ui_choose_many \
        "Select command-line tools" \
        "*" \
        "${CLI_TOOLS_AVAILABLE[@]}") || selection_status="${?}"
    if [ "${selection_status}" -ne 0 ]; then
        ui_error "Unable to read the command line tool selection; no command-line tools were installed."
        return "${selection_status}"
    fi
    while IFS= read -r selected_tool; do
        [ -n "${selected_tool}" ] || continue
        if ! extras_tool_is_registered "${selected_tool}"; then
            ui_warning "Ignoring unknown command line tool '${selected_tool}'."
            continue
        fi
        available=0
        for available_tool in "${CLI_TOOLS_AVAILABLE[@]}"; do
            if [ "${selected_tool}" = "${available_tool}" ]; then
                available=1
                break
            fi
        done
        if [ "${available}" -ne 1 ]; then
            ui_warning "Ignoring command-line tool '${selected_tool}', which is not available for ${EXTRAS_ARCHITECTURE}."
            continue
        fi
        duplicate=0
        for registered in "${CLI_TOOLS_TO_INSTALL[@]}"; do
            if [ "${selected_tool}" = "${registered}" ]; then
                duplicate=1
                break
            fi
        done
        if [ "${duplicate}" -eq 0 ]; then
            CLI_TOOLS_TO_INSTALL+=("${selected_tool}")
        fi
    done < <(printf '%s\n' "${selection}")
    ;;
*)
    ui_error "Invalid command-line tool selection mode '${POSTINSTALL_TOOL_SELECTION_MODE}'."
    return 1
    ;;
esac

CLI_TOOLS_SELECTION="$(printf '%s,' "${CLI_TOOLS_TO_INSTALL[@]}" | sed 's/,$//')"
if [ -z "${CLI_TOOLS_SELECTION}" ]; then
    CLI_TOOLS_SELECTION="-"
fi

if [ "${#CLI_TOOLS_TO_INSTALL[@]}" -eq 0 ]; then
    ui_skip "No command-line tools were selected."
    return 0
fi

ui_step "Installing ${#CLI_TOOLS_TO_INSTALL[@]} command-line tools for ${EXTRAS_ARCHITECTURE}."

require_command "python3" "needed to safely extract downloaded tool archives"

EXTRAS_WORKSPACE_ROOT="${TMPDIR:-/tmp}"
if [ -z "${POSTINSTALL_CACHE_DIR:-}" ]; then
    ui_error "The command-line tool cache directory is not configured. Set the cache directory and try again."
    return 1
fi
EXTRAS_CACHE_DIRECTORY="${POSTINSTALL_CACHE_DIR}/extras"
extras_validate_selected_tools "${CLI_TOOLS_TO_INSTALL[@]}" || {
    EXTRAS_SELECTION_STATUS="${?}"
    ui_error "Could not validate the selected command-line tools for ${EXTRAS_ARCHITECTURE}. No command-line tools were installed."
    return "${EXTRAS_SELECTION_STATUS}"
}

if ! EXTRAS_WORKSPACE=$(mktemp -d \
    "${EXTRAS_WORKSPACE_ROOT}/fedora-postinstall-extras.XXXXXXXX"); then
    ui_error "Could not create a temporary workspace for the command-line tools. No command-line tools were installed."
    return 1
fi
if ! runtime_register_cleanup "extras-workspace" extras_cleanup_workspace; then
    ui_error "Could not register cleanup for the temporary workspace. The installation stopped before any files were changed."
    return 1
fi

if ! mkdir -p \
    "${EXTRAS_WORKSPACE}/artifacts" \
    "${EXTRAS_WORKSPACE}/extracted" \
    "${EXTRAS_WORKSPACE}/staged" \
    "${EXTRAS_WORKSPACE}/backups"; then
    ui_error "Could not prepare the temporary workspace. No command-line tools were installed."
    return 1
fi
EXTRAS_ARTIFACT_LEDGER="${EXTRAS_WORKSPACE}/artifacts.tsv"
EXTRAS_STAGE_LEDGER="${EXTRAS_WORKSPACE}/staged.tsv"
if ! : >"${EXTRAS_ARTIFACT_LEDGER}" || ! : >"${EXTRAS_STAGE_LEDGER}"; then
    ui_error "Could not initialize the command-line tool ledgers. No command-line tools were installed."
    return 1
fi

# Conditional sourcing suppresses the ERR trap in Bash. Each wrapper checks
# every fallible operation and returns a failure status explicitly.
for CLI_TOOL_TO_INSTALL in "${CLI_TOOLS_TO_INSTALL[@]}"; do
    if ! source "extras/${CLI_TOOL_TO_INSTALL}-download.sh"; then
        ui_error "Could not download ${CLI_TOOL_TO_INSTALL}. No command-line tools were deployed."
        return 1
    fi
done

ui_step "Extracting the selected command-line tools."
if ! unpack_extras_tools "${CLI_TOOLS_TO_INSTALL[@]}"; then
    ui_error "Could not extract the selected command-line tools. No command-line tools were deployed."
    return 1
fi

ui_step "Deploying ${#CLI_TOOLS_TO_INSTALL[@]} command-line tools to ${HOME}/.local/bin."
if ! deploy_extras_tools; then
    ui_error "Could not deploy the selected command-line tools. The deployment was rolled back when possible."
    return 1
fi

ui_success "Installed ${#CLI_TOOLS_TO_INSTALL[@]} command-line tools (${#EXTRAS_STAGED_BINARIES[@]} commands) in ${HOME}/.local/bin."
