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

source "extras/tools-list.sh"
source "extras/tools-download.sh"
source "extras/tools-unpacking.sh"
source "extras/tools-deployment.sh"

section "Additional command line tools"

description "This section presents a collection of command line tools. \
These tools cover a wide range of functionalities, such as terminal based \
video recording, terminal sharing, vulnerability scanning, data processing, \
system monitoring, web development, and much more, providing users with a \
comprehensive set of utilities to enhance their productivity and workflow \
within the terminal environment."

echo

text "Do you want to install any of these command line tools?"

echo

function extras_cleanup_workspace {
    if declare -F extras_cleanup_deployment_temporaries >/dev/null; then
        extras_cleanup_deployment_temporaries
    fi

    if declare -F extras_rollback_deployment >/dev/null &&
        [ "${EXTRAS_DEPLOYMENT_COMPLETE:-0}" -ne 1 ]; then
        if ! extras_rollback_deployment; then
            text "The command line tool deployment could not be fully rolled back. Recovery backups were preserved in ${EXTRAS_DEPLOYMENT_BACKUP_DIRECTORY}."
        fi
    elif [ -n "${EXTRAS_DEPLOYMENT_BACKUP_DIRECTORY:-}" ] &&
        [ -d "${EXTRAS_DEPLOYMENT_BACKUP_DIRECTORY}" ]; then
        if ! rm -rf -- "${EXTRAS_DEPLOYMENT_BACKUP_DIRECTORY}"; then
            text "Unable to remove the command line tool recovery backups in ${EXTRAS_DEPLOYMENT_BACKUP_DIRECTORY}."
        fi
    fi

    if [ -n "${EXTRAS_WORKSPACE:-}" ] &&
        [ -d "${EXTRAS_WORKSPACE}" ] &&
        [[ "${EXTRAS_WORKSPACE}" == "${EXTRAS_WORKSPACE_ROOT}/fedora-postinstall-extras."* ]]; then
        rm -rf -- "${EXTRAS_WORKSPACE}"
    fi
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

# The list is rendered by gum. Only identifiers from the authoritative registry
# are accepted; arbitrary user or terminal output must never become a source path.
selection_status=0
selection=$("${GUM}" choose --no-limit --height 15 --selected='*' "${CLI_TOOLS_LIST[@]}") || selection_status="${?}"
if [ "${selection_status}" -ne 0 ]; then
    text "Unable to read the command line tool selection."
    return 1
fi
CLI_TOOLS_TO_INSTALL=()
while IFS= read -r selected_tool; do
    [ -n "${selected_tool}" ] || continue
    if ! extras_tool_is_registered "${selected_tool}"; then
        text "Ignoring unknown command line tool '${selected_tool}'."
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

if [ "${#CLI_TOOLS_TO_INSTALL[@]}" -eq 0 ]; then
    text "You haven't selected any items from the list. Moving on."
    return 0 2>/dev/null || exit 0
fi

text "You've selected ${#CLI_TOOLS_TO_INSTALL[@]} command line tool(s) to install. Please wait."

require_command "python3" "needed to safely extract downloaded tool archives"

EXTRAS_MANIFEST_FILE="${SCRIPT_PATH}/extras/tools-manifest.json"
EXTRAS_WORKSPACE_ROOT="${TMPDIR:-/tmp}"
if ! extras_validate_manifest_file; then
    text "Unable to load the command line tool manifest."
    return 1
fi
if ! EXTRAS_ARCHITECTURE=$(extras_detect_architecture); then
    text "Unsupported architecture for the additional command line tools: $(uname -m)."
    return 1
fi

if ! extras_validate_selected_tools "${CLI_TOOLS_TO_INSTALL[@]}"; then
    text "Unable to install the selected command line tools on ${EXTRAS_ARCHITECTURE}."
    return 1
fi

if ! EXTRAS_WORKSPACE=$(mktemp -d \
    "${EXTRAS_WORKSPACE_ROOT}/fedora-postinstall-extras.XXXXXXXX"); then
    text "Unable to create a temporary workspace for the additional command line tools."
    return 1
fi
if ! runtime_register_cleanup "extras-workspace" extras_cleanup_workspace; then
    text "Unable to register cleanup for the temporary workspace."
    return 1
fi

if ! mkdir -p \
    "${EXTRAS_WORKSPACE}/downloads" \
    "${EXTRAS_WORKSPACE}/extracted" \
    "${EXTRAS_WORKSPACE}/staged" \
    "${EXTRAS_WORKSPACE}/backups"; then
    text "Unable to prepare the temporary workspace for the additional command line tools."
    return 1
fi
EXTRAS_ARTIFACT_LEDGER="${EXTRAS_WORKSPACE}/artifacts.tsv"
EXTRAS_STAGE_LEDGER="${EXTRAS_WORKSPACE}/staged.tsv"
if ! : >"${EXTRAS_ARTIFACT_LEDGER}" || ! : >"${EXTRAS_STAGE_LEDGER}"; then
    text "Unable to initialize the command line tool ledgers."
    return 1
fi

for CLI_TOOL_TO_INSTALL in "${CLI_TOOLS_TO_INSTALL[@]}"; do
    if ! source "extras/${CLI_TOOL_TO_INSTALL}-download.sh"; then
        text "Unable to download ${CLI_TOOL_TO_INSTALL}. No tools were deployed."
        return 1
    fi
done

if ! unpack_extras_tools "${CLI_TOOLS_TO_INSTALL[@]}"; then
    text "Unable to unpack the selected command line tools. No tools were deployed."
    return 1
fi

if ! deploy_extras_tools; then
    text "Unable to deploy the selected command line tools."
    return 1
fi

info "Deployed ${#EXTRAS_STAGED_BINARIES[@]} executable(s) to ${HOME}/.local/bin."
