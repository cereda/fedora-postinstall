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
source "common/doctor.sh" || exit 1
source "common/snapshot.sh" || exit 1

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
doctor)
    if [ "${CLI_JSON}" -eq 1 ]; then
        doctor_run --json || exit $?
    else
        doctor_run || exit $?
    fi
    exit 0
    ;;
snapshot)
    case "${CLI_SUBCOMMAND}" in
    list)
        POSTINSTALL_SNAPSHOT_LIST_LOCK=1
        export POSTINSTALL_SNAPSHOT_LIST_LOCK
        snapshot_list || exit $?
        exit 0
        ;;
    diff)
        POSTINSTALL_SNAPSHOT_LIST_LOCK=1
        export POSTINSTALL_SNAPSHOT_LIST_LOCK
        snapshot_diff "${CLI_ARGUMENTS[0]}" "${CLI_ARGUMENTS[1]}" || exit $?
        exit 0
        ;;
    esac
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

function root_render_selection_summary {
    local root_selection_flavor="${1:-not-applicable}"
    local root_selection_operation="${2:-installation}"
    local root_selection_profile="${3:-not-applicable}"
    local root_selection_modules="${4:-0}"
    local root_selection_tool_summary=""

    case "${CLI_TOOL_SELECTION_MODE:-interactive}" in
    none)
        root_selection_tool_summary="none"
        ;;
    explicit | all)
        if [ "${#CLI_SELECTED_TOOLS[@]}" -eq 0 ]; then
            root_selection_tool_summary="none"
        else
            root_selection_tool_summary="$(printf '%s, ' "${CLI_SELECTED_TOOLS[@]}")"
            root_selection_tool_summary="${root_selection_tool_summary%, }"
        fi
        ;;
    *)
        root_selection_tool_summary="interactive selection"
        ;;
    esac

    ui_text "Selection: ${root_selection_operation}, ${root_selection_flavor}, ${CLI_ARCHITECTURE:-unknown architecture}, profile '${root_selection_profile}', ${root_selection_modules} module(s) selected." || return $?
    ui_text "Extra tools: ${root_selection_tool_summary}." || return $?
}

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
if [ "${CLI_COMMAND}" = "install" ] || [ "${CLI_COMMAND}" = "extras" ]; then
    if ! SELECTED_ARCHITECTURE=$(detection_resolve_architecture); then
        exit 69
    fi
    CLI_ARCHITECTURE="${SELECTED_ARCHITECTURE}"
    export POSTINSTALL_ARCHITECTURE="${SELECTED_ARCHITECTURE}"
fi

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

if [ "${CLI_COMMAND}" = "install" ] || [ "${CLI_COMMAND}" = "extras" ]; then
    plan_resolve_tools "${SELECTED_ARCHITECTURE}" || exit $?
fi

# Validate the complete selection before requiring an interactive terminal.
# This preserves the established diagnostic statuses for unknown flavors,
# tools, profiles, and architectures while still preventing non-interactive
# installation or extra-tool mutation flows.
if { [ "${CLI_COMMAND}" = "install" ] || [ "${CLI_COMMAND}" = "extras" ]; } &&
    { [ ! -t 0 ] || [ ! -t 2 ]; }; then
    ui_error "A terminal is required for interactive installation and extra-tool commands."
    exit 64
fi
if [ "${CLI_COMMAND}" = "snapshot" ] &&
    [ "${CLI_SUBCOMMAND}" = "restore" ] &&
    { [ ! -t 0 ] || [ ! -t 2 ]; }; then
    ui_error "A terminal is required to confirm a snapshot restore."
    exit 64
fi

# Set the operation label and module total before the runtime starts so the
# final result and progress messages use the same accounting.
case "${CLI_COMMAND}" in
install)
    RUNTIME_OPERATION_LABEL="Installation"
    RUNTIME_MODULE_TOTAL=0
    while IFS= read -r RUNTIME_INVENTORY_MODULE; do
        [ -n "${RUNTIME_INVENTORY_MODULE}" ] &&
            RUNTIME_MODULE_TOTAL=$((RUNTIME_MODULE_TOTAL + 1))
    done < <(runtime_module_inventory_modules "${SELECTED_FLAVOR}")
    if [ "${PROFILE_EXTRAS_SELECTED}" -eq 1 ]; then
        RUNTIME_MODULE_TOTAL=$((RUNTIME_MODULE_TOTAL + 1))
    fi
    ;;
extras)
    RUNTIME_OPERATION_LABEL="Additional tools installation"
    RUNTIME_MODULE_TOTAL=1
    ;;
snapshot)
    RUNTIME_OPERATION_LABEL="Snapshot ${CLI_SUBCOMMAND}"
    RUNTIME_MODULE_TOTAL=1
    ;;
esac

cli_apply_options
runtime_initialize || exit $?
if [ "${CLI_COMMAND}" = "snapshot" ] &&
    { [ "${CLI_SUBCOMMAND}" = "create" ] || [ "${CLI_SUBCOMMAND}" = "restore" ]; }; then
    snapshot_preflight || exit $?
fi
runtime_register_cleanup "install-lock" runtime_release_install_lock || exit $?
runtime_acquire_install_lock || exit $?

source "common/dependencies.sh" || exit 1

if [ "${CLI_COMMAND}" = "snapshot" ]; then
    require_command "python3" "needed to create and restore snapshots" || exit 1
    require_command "flock" "needed to serialize post-installation runs" || exit 1

    ui_title "Fedora snapshot manager" || exit $?
    case "${CLI_SUBCOMMAND}" in
    recover)
        ui_step "Recovering interrupted snapshot transactions." || exit $?
        snapshot_recover || exit $?
        RUNTIME_MODULE_COMPLETED=1
        runtime_render_result_summary \
            "Snapshot recovery complete" \
            "${RUNTIME_MODULE_TOTAL}" \
            "${RUNTIME_MODULE_COMPLETED}" \
            "${RUNTIME_MODULE_SKIPPED}" \
            "${RUNTIME_MODULE_FAILED}" || exit $?
        exit 0
        ;;
    create)
        ui_description "Create a verified snapshot of the managed home directory." || exit $?
        ui_text "Selection: snapshot creation, ${CLI_ARGUMENTS[0]:-automatic identifier}, complete managed directory." || exit $?
        ui_step "Creating the managed-home snapshot." || exit $?
        snapshot_create "${CLI_ARGUMENTS[0]:-}" || exit $?
        ui_success "Snapshot created."
        RUNTIME_MODULE_COMPLETED=1
        runtime_render_result_summary \
            "Snapshot creation complete" \
            "${RUNTIME_MODULE_TOTAL}" \
            "${RUNTIME_MODULE_COMPLETED}" \
            "${RUNTIME_MODULE_SKIPPED}" \
            "${RUNTIME_MODULE_FAILED}" || exit $?
        exit 0
        ;;
    restore)
        source "common/ui-prompts.sh" || exit 1
        # gum-setup reuses a supported installed Gum and checks the download
        # dependencies only when its checksum-pinned fallback is required.
        source "common/gum-setup.sh" || exit 1

        ui_description "Restore a verified snapshot of the managed home directory." || exit $?
        if [ "${#CLI_SNAPSHOT_PATHS[@]}" -eq 0 ]; then
            ui_text "Selection: snapshot restore, ${CLI_ARGUMENTS[0]}, complete managed directory." || exit $?
        else
            ui_text "Selection: snapshot restore, ${CLI_ARGUMENTS[0]}, selected paths: ${CLI_SNAPSHOT_PATHS[*]}." || exit $?
        fi
        SNAPSHOT_RESTORE_CONFIRM_STATUS=0
        if [ "${#CLI_SNAPSHOT_PATHS[@]}" -eq 0 ]; then
            SNAPSHOT_RESTORE_CONFIRMATION="Restore snapshot '${CLI_ARGUMENTS[0]}'? The current managed directory will be replaced."
        else
            SNAPSHOT_RESTORE_CONFIRMATION="Restore snapshot '${CLI_ARGUMENTS[0]}'? The selected snapshot paths will be replaced."
        fi
        ui_confirm \
            "${SNAPSHOT_RESTORE_CONFIRMATION}" \
            "Restore" "Cancel" ||
            SNAPSHOT_RESTORE_CONFIRM_STATUS="${?}"
        if [ "${SNAPSHOT_RESTORE_CONFIRM_STATUS}" -ne 0 ]; then
            ui_skip "Snapshot restore was canceled."
            RUNTIME_MODULE_SKIPPED=1
            runtime_render_result_summary \
                "Snapshot restore canceled" \
                "${RUNTIME_MODULE_TOTAL}" \
                "${RUNTIME_MODULE_COMPLETED}" \
                "${RUNTIME_MODULE_SKIPPED}" \
                "${RUNTIME_MODULE_FAILED}" || true
            exit "${SNAPSHOT_RESTORE_CONFIRM_STATUS}"
        fi

        SNAPSHOT_RESTORE_ARGUMENTS=("${CLI_ARGUMENTS[0]}")
        for SNAPSHOT_RESTORE_PATH in "${CLI_SNAPSHOT_PATHS[@]}"; do
            SNAPSHOT_RESTORE_ARGUMENTS+=("--path" "${SNAPSHOT_RESTORE_PATH}")
        done
        ui_step "Restoring the managed-home snapshot." || exit $?
        snapshot_restore "${SNAPSHOT_RESTORE_ARGUMENTS[@]}" --yes || exit $?
        ui_success "Snapshot restored."
        RUNTIME_MODULE_COMPLETED=1
        runtime_render_result_summary \
            "Snapshot restore complete" \
            "${RUNTIME_MODULE_TOTAL}" \
            "${RUNTIME_MODULE_COMPLETED}" \
            "${RUNTIME_MODULE_SKIPPED}" \
            "${RUNTIME_MODULE_FAILED}" || exit $?
        exit 0
        ;;
    esac
fi

source "common/ui-prompts.sh" || exit 1
source "common/validation.sh" || exit 1

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
    root_render_selection_summary \
        "Fedora ${FEDORA_FLAVOR}" "installation" \
        "${CLI_PROFILE_NAME:-default}" "${#PROFILE_EFFECTIVE_MODULES[@]}" ||
        exit $?

    # The installer does not perform an upgrade itself. Make that prerequisite
    # explicit so the answer has a clear meaning before any module runs.
    UPGRADE_CONFIRM_STATUS=0
    ui_confirm \
        "This installer assumes the system is already upgraded. Continue?" \
        "Continue" "Stop" || UPGRADE_CONFIRM_STATUS="${?}"
    if [ "${UPGRADE_CONFIRM_STATUS}" -ne 0 ]; then
        ui_skip "Installation stopped before any installation modules ran."
        runtime_render_result_summary \
            "Installation canceled" \
            "${RUNTIME_MODULE_TOTAL}" \
            "${RUNTIME_MODULE_COMPLETED}" \
            "${RUNTIME_MODULE_SKIPPED}" \
            "${RUNTIME_MODULE_FAILED}" || true
        exit "${UPGRADE_CONFIRM_STATUS}"
    fi

    ui_text "Running Fedora ${FEDORA_VERSION} ${FEDORA_FLAVOR}." || exit $?

    POSTINSTALL_STATE_NAMESPACE="${SELECTED_FLAVOR}"
    export POSTINSTALL_STATE_NAMESPACE
    runtime_run_module "${SELECTED_FLAVOR}/post-installation.sh" orchestrator
else
    ui_title "Fedora post-installer" || exit $?
    ui_description "Install selected command-line tools." || exit $?
    root_render_selection_summary \
        "standalone extras" "additional tools installation" \
        "not-applicable" "1" || exit $?
fi

# The additional tools remain the final step of both the install and extras
# flows. A profile may explicitly omit this module.
if [ "${PROFILE_EXTRAS_SELECTED}" -eq 1 ]; then
    POSTINSTALL_STATE_NAMESPACE="extras"
    export POSTINSTALL_STATE_NAMESPACE
    runtime_run_module "extras/additional-tools.sh" mutating CLI_TOOLS_SELECTION
fi

if [ "${CLI_COMMAND}" = "install" ]; then
    runtime_render_result_summary \
        "Installation complete" \
        "${RUNTIME_MODULE_TOTAL}" \
        "${RUNTIME_MODULE_COMPLETED}" \
        "${RUNTIME_MODULE_SKIPPED}" \
        "${RUNTIME_MODULE_FAILED}" || exit $?
else
    runtime_render_result_summary \
        "Additional tools installation complete" \
        "${RUNTIME_MODULE_TOTAL}" \
        "${RUNTIME_MODULE_COMPLETED}" \
        "${RUNTIME_MODULE_SKIPPED}" \
        "${RUNTIME_MODULE_FAILED}" || exit $?
fi
