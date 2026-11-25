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

# Mutation flows use the semantic native renderer. Query and dry-run paths
# intentionally remain Gum-independent and retain their stable plain output.
source "common/ui.sh" || exit 1

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

source "common/ui-prompts.sh" || exit 1
source "common/validation.sh" || exit 1
source "common/dependencies.sh" || exit 1

require_runtime_dependencies || exit 1

# 'gum' is required for interactive installation, so in case it is not
# available, the script downloads a fixed version from the authoritative
# manifest.
source "common/gum-setup.sh" || exit 1

# Determine the Fedora version from the RPM macro.
if ! FEDORA_VERSION=$(rpm -E %fedora); then
    ui_error "Unable to determine the Fedora version from RPM."
    exit 1
fi
if ! [[ "${FEDORA_VERSION}" =~ ^[0-9]{1,3}$ ]]; then
    ui_error "Unable to determine a valid Fedora version from RPM (${FEDORA_VERSION})."
    exit 1
fi

if [ "${CLI_COMMAND}" = "install" ]; then
    case "${SELECTED_FLAVOR}" in
    workstation)
        FEDORA_FLAVOR="Workstation"
        ;;
    silverblue)
        FEDORA_FLAVOR="Silverblue"
        ;;
    *)
        ui_error "Unable to determine the Fedora flavor for the installation."
        exit 69
        ;;
    esac

    ui_title "Fedora post-installer" || exit $?
    ui_description "Install and configure Fedora ${FEDORA_FLAVOR}." || exit $?

    # The installer does not perform an upgrade itself. Make that prerequisite
    # explicit so the answer has a clear meaning before any module runs.
    UPGRADE_CONFIRM_STATUS=0
    ui_confirm \
        "This installer assumes the system is already upgraded. Continue?" \
        "Continue" "Stop" || UPGRADE_CONFIRM_STATUS="${?}"
    if [ "${UPGRADE_CONFIRM_STATUS}" -ne 0 ]; then
        ui_skip "Installation stopped before any installation modules ran."
        exit "${UPGRADE_CONFIRM_STATUS}"
    fi

    ui_text "Running Fedora ${FEDORA_VERSION} ${FEDORA_FLAVOR}." || exit $?

    POSTINSTALL_STATE_NAMESPACE="${SELECTED_FLAVOR}"
    export POSTINSTALL_STATE_NAMESPACE
    runtime_run_module "${SELECTED_FLAVOR}/post-installation.sh" orchestrator
else
    ui_title "Fedora post-installer" || exit $?
    ui_description "Install selected command-line tools." || exit $?
fi

# The additional tools remain the final step of both the install and extras
# flows. A profile may explicitly omit this module.
if [ "${PROFILE_EXTRAS_SELECTED}" -eq 1 ]; then
    POSTINSTALL_STATE_NAMESPACE="extras"
    export POSTINSTALL_STATE_NAMESPACE
    runtime_run_module "extras/additional-tools.sh" mutating CLI_TOOLS_SELECTION
fi

if [ "${CLI_COMMAND}" = "install" ]; then
    ui_summary "Installation complete." || exit $?
else
    ui_summary "Additional tools installation complete." || exit $?
fi
