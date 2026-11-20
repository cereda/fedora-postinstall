#!/usr/bin/env bash

# MIT License
#
# Copyright (c) 2025, Paulo Cereda
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

SCRIPT_PATH=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
cd "${SCRIPT_PATH}" || exit 1

# Load the CLI and runtime without starting any installation work. Query and
# dry-run commands are dispatched before dependency checks or gum bootstrap.
source "common/runtime.sh" || exit 1
source "common/cli.sh" || exit 1
source "common/detection.sh" || exit 1
source "common/module-inventory.sh" || exit 1
source "common/profile.sh" || exit 1
source "common/plan.sh" || exit 1

cli_parse_arguments "$@" || exit $?

case "${CLI_COMMAND}" in
help)
    cli_render_help
    exit 0
    ;;
detect)
    detection_render || exit 1
    if [ -n "${CLI_LOG_FILE}" ] || [ "${CLI_LOG_STDOUT}" -eq 1 ]; then
        cli_apply_options
        runtime_initialize || exit 1
        runtime_log "INFO" "Detection completed." "detect.complete"
    fi
    exit 0
    ;;
plan)
    plan_prepare "plan" || exit $?
    if [ -n "${CLI_LOG_FILE}" ] || [ "${CLI_LOG_STDOUT}" -eq 1 ]; then
        cli_apply_options
        runtime_initialize || exit 1
        runtime_log "INFO" "Plan generated without executing installation modules." \
            "plan.complete"
    fi
    plan_render || exit 1
    exit 0
    ;;
esac

if [ "${CLI_DRY_RUN}" -eq 1 ]; then
    plan_prepare "${CLI_COMMAND}" || exit $?
    if [ -n "${CLI_LOG_FILE}" ] || [ "${CLI_LOG_STDOUT}" -eq 1 ]; then
        cli_apply_options
        runtime_initialize || exit 1
        runtime_log "INFO" "Dry-run plan generated without executing installation modules." \
            "plan.complete"
    fi
    plan_render || exit 1
    exit 0
fi

# Resolve target architecture before any installation module is considered.
if ! SELECTED_ARCHITECTURE=$(detection_resolve_architecture); then
    exit 69
fi
CLI_ARCHITECTURE="${SELECTED_ARCHITECTURE}"
export POSTINSTALL_ARCHITECTURE="${SELECTED_ARCHITECTURE}"

# An explicit install command may use automatic flavor detection. An
# implicit invocation retains the legacy interactive chooser unless the user
# supplied --flavor on the command line; POSTINSTALL_FLAVOR is honored by
# explicit install commands but cannot silently bypass that chooser.
SELECTED_FLAVOR=""
FLAVOR_STATUS=0
if [ "${CLI_COMMAND}" = "install" ]; then
    if [ "${CLI_COMMAND_EXPLICIT}" -eq 1 ] ||
        [ "${CLI_FLAVOR_OPTION_EXPLICIT}" -eq 1 ]; then
        if SELECTED_FLAVOR=$(detection_resolve_flavor); then
            CLI_FLAVOR="${SELECTED_FLAVOR}"
        else
            FLAVOR_STATUS="${?}"
            if [ "${FLAVOR_STATUS}" -eq 69 ]; then
                exit 69
            fi
        fi
    fi
fi

# Profiles are validated before any dependency download or system mutation.
if [ "${CLI_COMMAND}" = "install" ]; then
    profile_load || exit $?
    if [ -n "${SELECTED_FLAVOR}" ]; then
        profile_apply_flavor "${SELECTED_FLAVOR}" || exit $?
    fi
fi

# Resolve and validate the extras selection before the runtime starts.
if [ "${CLI_COMMAND}" = "extras" ]; then
    PROFILE_EXTRAS_SELECTED=1
    PROFILE_EFFECTIVE_MODULES=("extras/additional-tools.sh")
    RUNTIME_PROFILE_ENABLED=1
    RUNTIME_PROFILE_MODULES=("${PROFILE_EFFECTIVE_MODULES[@]}")
fi
plan_resolve_tools "${SELECTED_ARCHITECTURE}" || exit $?

cli_apply_options
runtime_initialize || exit 1

source "common/gum-functions.sh" || exit 1
source "common/validation.sh" || exit 1
source "common/dependencies.sh" || exit 1

require_runtime_dependencies || exit 1

# 'gum' is required for interactive installation, so in case it is not
# available, the script downloads a fixed version from the authoritative
# manifest.
source "common/gum-setup.sh" || exit 1

# Determine the Fedora version from the RPM macro.
if ! FEDORA_VERSION=$(rpm -E %fedora); then
    printf 'Unable to determine the Fedora version from RPM.\n' >&2
    exit 1
fi
if ! [[ "${FEDORA_VERSION}" =~ ^[0-9]{1,3}$ ]]; then
    printf 'Unable to determine a valid Fedora version from RPM (%s).\n' \
        "${FEDORA_VERSION}" >&2
    exit 1
fi

if [ "${CLI_COMMAND}" = "install" ]; then
    chapter "Paulo's Fedora ${FEDORA_VERSION} post installation script"

    description "Fedora Linux is a free and open source operating system \
sponsored by Red Hat, focused on innovation, security, and community \
collaboration. It provides a stable, cutting-edge platform for \
developers, enthusiasts, and users seeking a modern, reliable Linux \
distribution."

    echo

    # Preserve the legacy upgrade confirmation for actual installations.
    question "Did you upgrade your system?" || exit 1

    if [ -z "${SELECTED_FLAVOR}" ]; then
        text "Welcome to my post installation script for Fedora! \
Please select which flavour of Fedora you are currently running."

        echo

        if ! runtime_capture_output FEDORA_FLAVOUR "${GUM}" choose "Workstation" "Silverblue"; then
            text "Unable to read the Fedora flavour selection. Aborting."
            exit 1
        fi
        if [ -z "${FEDORA_FLAVOUR}" ]; then
            text "No Fedora flavour was selected. Aborting to avoid applying the wrong configuration."
            exit 1
        fi
        case "${FEDORA_FLAVOUR}" in
        Workstation) SELECTED_FLAVOR="workstation" ;;
        Silverblue) SELECTED_FLAVOR="silverblue" ;;
        *)
            text "Invalid Fedora flavour '${FEDORA_FLAVOUR}'. Aborting."
            exit 1
            ;;
        esac
        CLI_FLAVOR="${SELECTED_FLAVOR}"
        export POSTINSTALL_FLAVOR="${SELECTED_FLAVOR}"
        profile_apply_flavor "${SELECTED_FLAVOR}" || exit $?
    fi

    case "${SELECTED_FLAVOR}" in
    workstation)
        FEDORA_FLAVOUR="Workstation"
        ;;
    silverblue)
        FEDORA_FLAVOUR="Silverblue"
        ;;
    esac
    text "You are running Fedora ${FEDORA_FLAVOUR} ${FEDORA_VERSION}. Let's go!"

    POSTINSTALL_STATE_NAMESPACE="${SELECTED_FLAVOR}"
    export POSTINSTALL_STATE_NAMESPACE
    runtime_run_module "${SELECTED_FLAVOR}/post-installation.sh" orchestrator
else
    text "Welcome to my post installation script for Fedora! It appears you \
have chosen to skip the flavour selection. The script will now proceed \
directly to the installation of additional command line tools."
fi

# The additional tools remain the final step of both the install and extras
# flows. A profile may explicitly omit this module.
if [ "${PROFILE_EXTRAS_SELECTED}" -eq 1 ]; then
    POSTINSTALL_STATE_NAMESPACE="extras"
    export POSTINSTALL_STATE_NAMESPACE
    runtime_run_module "extras/additional-tools.sh" mutating CLI_TOOLS_SELECTION
fi

echo

text "That's all, folks! Have fun with Fedora!"
