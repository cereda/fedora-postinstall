#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

POSTINSTALL_INVOCATION_DIRECTORY=$(pwd -P) || exit 1
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
cli_apply_options

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

# Resolve the Fedora flavor before any dependency download, cache creation,
# lock acquisition, or installation module is considered. An explicit
# install uses the selected flavor, POSTINSTALL_FLAVOR, or reliable automatic
# detection; it never falls back to an interactive chooser.
SELECTED_FLAVOR=""
if [ "${CLI_COMMAND}" = "install" ]; then
    SELECTED_FLAVOR=$(detection_resolve_flavor)
    FLAVOR_STATUS="${?}"
    if [ "${FLAVOR_STATUS}" -ne 0 ]; then
        exit "${FLAVOR_STATUS}"
    fi
    CLI_FLAVOR="${SELECTED_FLAVOR}"
    export POSTINSTALL_FLAVOR="${SELECTED_FLAVOR}"
fi

# Resolve target architecture before any installation module is considered.
if ! SELECTED_ARCHITECTURE=$(detection_resolve_architecture); then
    exit 69
fi
CLI_ARCHITECTURE="${SELECTED_ARCHITECTURE}"
export POSTINSTALL_ARCHITECTURE="${SELECTED_ARCHITECTURE}"

# Profiles are validated before any dependency download or system mutation.
if [ "${CLI_COMMAND}" = "install" ]; then
    profile_load || exit $?
    profile_apply_flavor "${SELECTED_FLAVOR}" || exit $?
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
runtime_initialize || exit $?
runtime_register_cleanup "install-lock" runtime_release_install_lock || exit $?
runtime_acquire_install_lock || exit $?

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

    description "Install and configure the selected Fedora flavor."

    echo

    # Keep the upgrade confirmation for actual installations.
    question "Did you upgrade your system?" || exit 1

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
    text "Welcome to my post installation script for Fedora! The script will now proceed \
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
