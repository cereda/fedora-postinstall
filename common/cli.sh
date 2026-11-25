#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

declare -g CLI_COMMAND=""
declare -g CLI_FLAVOR=""
declare -g CLI_FLAVOR_EXPLICIT=0
declare -g CLI_FLAVOR_OPTION_EXPLICIT=0
declare -g CLI_ARCHITECTURE=""
declare -g CLI_ARCHITECTURE_EXPLICIT=0
declare -g CLI_PROFILE_REQUEST="default"
declare -g CLI_PROFILE_FILE=""
declare -g CLI_PROFILE_EXPLICIT=0
declare -g CLI_PROFILE_FILE_EXPLICIT=0
declare -g CLI_PROFILE_NAME=""
declare -g CLI_PROFILE_DESCRIPTION=""
declare -g CLI_PROFILE_DIGEST=""
declare -g CLI_DRY_RUN=0
declare -g CLI_RESUME=0
declare -g CLI_STATE_FILE=""
declare -g CLI_CACHE_DIR=""
declare -g CLI_LOCK_FILE=""
declare -g CLI_LOG_FILE=""
declare -g CLI_LOG_STDOUT=0
declare -g CLI_LOG_FORMAT="plain"
declare -g CLI_LOG_LEVEL="info"
declare -g CLI_TOOL_SELECTION_MODE="interactive"
declare -g CLI_TOOL_SELECTION_SOURCE="default"
declare -ga CLI_SELECTED_TOOLS=()
declare -g CLI_JSON=0

function cli_is_true {
    case "${1:-}" in
    1 | true | TRUE | yes | YES | on | ON) return 0 ;;
    *) return 1 ;;
    esac
}

function cli_normalize_flavor {
    local cli_local_value="${1:-}"

    case "${cli_local_value,,}" in
    auto)
        printf '\n'
        ;;
    workstation)
        printf '%s\n' "workstation"
        ;;
    silverblue)
        printf '%s\n' "silverblue"
        ;;
    *)
        return 1
        ;;
    esac
}

function cli_normalize_architecture {
    local cli_local_value="${1:-}"

    case "${cli_local_value,,}" in
    auto)
        printf '\n'
        ;;
    x86_64)
        printf '%s\n' "x86_64"
        ;;
    aarch64)
        printf '%s\n' "aarch64"
        ;;
    *)
        return 1
        ;;
    esac
}

function cli_set_flavor {
    local cli_local_value="${1:-}"

    case "${cli_local_value,,}" in
    auto)
        CLI_FLAVOR=""
        CLI_FLAVOR_EXPLICIT=0
        return 0
        ;;
    esac
    if ! cli_local_value=$(cli_normalize_flavor "${cli_local_value}"); then
        printf 'cli: invalid Fedora flavor: %s\n' "${1:-}" >&2
        return 1
    fi
    CLI_FLAVOR="${cli_local_value}"
    CLI_FLAVOR_EXPLICIT=1
}

function cli_set_architecture {
    local cli_local_value="${1:-}"

    case "${cli_local_value,,}" in
    auto)
        CLI_ARCHITECTURE=""
        CLI_ARCHITECTURE_EXPLICIT=0
        return 0
        ;;
    esac
    if ! cli_local_value=$(cli_normalize_architecture "${cli_local_value}"); then
        printf 'cli: invalid architecture: %s\n' "${1:-}" >&2
        return 1
    fi
    CLI_ARCHITECTURE="${cli_local_value}"
    CLI_ARCHITECTURE_EXPLICIT=1
}

function cli_set_log_format {
    local cli_local_value="${1:-}"

    case "${cli_local_value,,}" in
    plain)
        CLI_LOG_FORMAT="plain"
        ;;
    json)
        CLI_LOG_FORMAT="json"
        ;;
    *)
        printf 'cli: invalid log format: %s\n' "${cli_local_value}" >&2
        return 1
        ;;
    esac
}

function cli_set_log_level {
    local cli_local_value="${1:-}"

    case "${cli_local_value,,}" in
    debug | info | warn | error)
        CLI_LOG_LEVEL="${cli_local_value,,}"
        ;;
    *)
        printf 'cli: invalid log level: %s\n' "${cli_local_value}" >&2
        return 1
        ;;
    esac
}

function cli_tool_identifier_is_valid {
    [[ "${1:-}" =~ ^[a-z0-9][a-z0-9-]*$ ]]
}

function cli_append_tool {
    local cli_local_tool="${1:-}"
    local cli_local_existing

    if ! cli_tool_identifier_is_valid "${cli_local_tool}"; then
        printf 'cli: invalid tool identifier: %s\n' "${cli_local_tool}" >&2
        return 1
    fi
    for cli_local_existing in "${CLI_SELECTED_TOOLS[@]}"; do
        if [ "${cli_local_existing}" = "${cli_local_tool}" ]; then
            printf 'cli: duplicate tool identifier: %s\n' "${cli_local_tool}" >&2
            return 1
        fi
    done
    CLI_SELECTED_TOOLS+=("${cli_local_tool}")
}

function cli_split_tool_list {
    local cli_local_raw="${1:-}"
    local cli_local_item
    local -a cli_local_items=()

    CLI_SELECTED_TOOLS=()
    if [ -z "${cli_local_raw}" ]; then
        return 0
    fi

    IFS=',' read -r -a cli_local_items <<<"${cli_local_raw}"
    for cli_local_item in "${cli_local_items[@]}"; do
        cli_local_item="${cli_local_item//[[:space:]]/}"
        if [ -z "${cli_local_item}" ]; then
            continue
        fi
        cli_append_tool "${cli_local_item}" || return 1
    done
    return 0
}

function cli_path_is_valid {
    local cli_local_path="${1:-}"

    [ -n "${cli_local_path}" ] || return 1
    [[ ! "${cli_local_path}" =~ [[:cntrl:]] ]] || return 1
    case "/${cli_local_path}/" in
    */../*) return 1 ;;
    esac
    return 0
}

function cli_normalize_path {
    local cli_local_path="${1:-}"
    local cli_local_base
    local cli_local_component
    local -a cli_local_components=()
    local -a cli_local_normalized=()

    if [[ "${cli_local_path}" != /* ]]; then
        if [ -n "${POSTINSTALL_INVOCATION_DIRECTORY:-}" ]; then
            cli_local_base="${POSTINSTALL_INVOCATION_DIRECTORY}"
        elif [ -n "${SCRIPT_PATH:-}" ]; then
            cli_local_base="${SCRIPT_PATH}"
        else
            cli_local_base=$(pwd -P) || return 1
        fi
        cli_local_path="${cli_local_base}/${cli_local_path}"
    fi

    IFS='/' read -r -a cli_local_components <<<"${cli_local_path}"
    for cli_local_component in "${cli_local_components[@]}"; do
        case "${cli_local_component}" in
        "" | .) ;;
        ..)
            if [ "${#cli_local_normalized[@]}" -gt 0 ]; then
                unset "cli_local_normalized[$((${#cli_local_normalized[@]} - 1))]"
            fi
            ;;
        *) cli_local_normalized+=("${cli_local_component}") ;;
        esac
    done

    if [ "${#cli_local_normalized[@]}" -eq 0 ]; then
        printf '/\n'
        return 0
    fi

    local IFS='/'
    printf '/%s\n' "${cli_local_normalized[*]}"
}

function cli_default_cache_dir {
    local cli_local_cache_root="${XDG_CACHE_HOME:-}"
    local cli_local_home="${HOME:-}"

    if [[ "${cli_local_cache_root}" != /* ]]; then
        if [ -n "${cli_local_home}" ]; then
            cli_local_cache_root="${cli_local_home}/.cache"
        else
            cli_local_cache_root="${POSTINSTALL_INVOCATION_DIRECTORY:-${SCRIPT_PATH:-$(pwd -P)}}/.cache"
        fi
    fi

    cli_normalize_path "${cli_local_cache_root%/}/fedora-postinstall"
}

function cli_finalize_paths {
    if [ -z "${CLI_CACHE_DIR}" ]; then
        CLI_CACHE_DIR=$(cli_default_cache_dir) || return 1
    fi
    if ! cli_path_is_valid "${CLI_CACHE_DIR}"; then
        printf 'cli: invalid cache directory path\n' >&2
        return 1
    fi
    CLI_CACHE_DIR=$(cli_normalize_path "${CLI_CACHE_DIR}") || return 1

    if [ -z "${CLI_LOCK_FILE}" ]; then
        CLI_LOCK_FILE="${CLI_CACHE_DIR}/postinstall.lock"
    fi
    if ! cli_path_is_valid "${CLI_LOCK_FILE}"; then
        printf 'cli: invalid lock file path\n' >&2
        return 1
    fi
    CLI_LOCK_FILE=$(cli_normalize_path "${CLI_LOCK_FILE}") || return 1
    return 0
}

function cli_reset_options {
    CLI_COMMAND=""
    CLI_FLAVOR=""
    CLI_FLAVOR_EXPLICIT=0
    CLI_FLAVOR_OPTION_EXPLICIT=0
    CLI_ARCHITECTURE=""
    CLI_ARCHITECTURE_EXPLICIT=0
    CLI_PROFILE_REQUEST="${POSTINSTALL_PROFILE:-default}"
    CLI_PROFILE_FILE="${POSTINSTALL_PROFILE_FILE:-}"
    CLI_PROFILE_EXPLICIT=0
    CLI_PROFILE_FILE_EXPLICIT=0
    if [ -n "${POSTINSTALL_PROFILE:-}" ]; then
        CLI_PROFILE_EXPLICIT=1
    fi
    if [ -n "${POSTINSTALL_PROFILE_FILE:-}" ]; then
        CLI_PROFILE_FILE_EXPLICIT=1
    fi
    CLI_PROFILE_NAME=""
    CLI_PROFILE_DESCRIPTION=""
    CLI_PROFILE_DIGEST=""
    CLI_DRY_RUN=0
    CLI_RESUME=0
    CLI_STATE_FILE="${POSTINSTALL_STATE_FILE:-}"
    CLI_CACHE_DIR="${POSTINSTALL_CACHE_DIR:-}"
    CLI_LOCK_FILE="${POSTINSTALL_LOCK_FILE:-}"
    CLI_LOG_FILE="${POSTINSTALL_LOG_FILE:-}"
    CLI_LOG_STDOUT=0
    CLI_LOG_FORMAT="plain"
    CLI_LOG_LEVEL="info"
    CLI_TOOL_SELECTION_MODE="interactive"
    CLI_TOOL_SELECTION_SOURCE="default"
    CLI_SELECTED_TOOLS=()
    CLI_JSON=0

    if [ -n "${POSTINSTALL_FLAVOR:-}" ]; then
        cli_set_flavor "${POSTINSTALL_FLAVOR}" || return 1
    fi
    if [ -n "${POSTINSTALL_ARCHITECTURE:-}" ]; then
        cli_set_architecture "${POSTINSTALL_ARCHITECTURE}" || return 1
    fi
    if cli_is_true "${POSTINSTALL_DRY_RUN:-0}"; then
        CLI_DRY_RUN=1
    fi
    if cli_is_true "${POSTINSTALL_RESUME:-0}"; then
        CLI_RESUME=1
    fi
    if cli_is_true "${POSTINSTALL_LOG_STDOUT:-0}"; then
        CLI_LOG_STDOUT=1
    fi
    if [ -n "${POSTINSTALL_LOG_FORMAT:-}" ]; then
        cli_set_log_format "${POSTINSTALL_LOG_FORMAT}" || return 1
    fi
    if [ -n "${POSTINSTALL_LOG_LEVEL:-}" ]; then
        cli_set_log_level "${POSTINSTALL_LOG_LEVEL}" || return 1
    fi
    if [ -n "${POSTINSTALL_TOOLS:-}" ]; then
        cli_split_tool_list "${POSTINSTALL_TOOLS}" || return 1
        CLI_TOOL_SELECTION_MODE="explicit"
        CLI_TOOL_SELECTION_SOURCE="environment"
    fi

    return 0
}

function cli_parse_arguments {
    local cli_local_argument
    local cli_local_value
    local cli_local_command_set=0
    local cli_local_profile_option_set=0
    local cli_local_profile_file_option_set=0
    local cli_local_tool_option_set=0
    local cli_local_all_option_set=0

    cli_reset_options || return 64

    while [ "$#" -gt 0 ]; do
        cli_local_argument="${1}"
        case "${cli_local_argument}" in
        --help | -h)
            CLI_COMMAND="help"
            cli_local_command_set=1
            shift
            ;;
        --flavor=*)
            cli_local_value="${cli_local_argument#*=}"
            cli_set_flavor "${cli_local_value}" || return 64
            CLI_FLAVOR_OPTION_EXPLICIT=1
            shift
            ;;
        --flavor)
            shift
            if [ "$#" -eq 0 ]; then
                printf 'cli: --flavor requires a value\n' >&2
                return 64
            fi
            cli_set_flavor "${1}" || return 64
            CLI_FLAVOR_OPTION_EXPLICIT=1
            shift
            ;;
        --architecture=*)
            cli_local_value="${cli_local_argument#*=}"
            cli_set_architecture "${cli_local_value}" || return 64
            shift
            ;;
        --architecture)
            shift
            if [ "$#" -eq 0 ]; then
                printf 'cli: --architecture requires a value\n' >&2
                return 64
            fi
            cli_set_architecture "${1}" || return 64
            shift
            ;;
        --profile=*)
            cli_local_value="${cli_local_argument#*=}"
            if [ -z "${cli_local_value}" ]; then
                printf 'cli: --profile requires a value\n' >&2
                return 64
            fi
            CLI_PROFILE_REQUEST="${cli_local_value}"
            CLI_PROFILE_FILE=""
            CLI_PROFILE_EXPLICIT=1
            CLI_PROFILE_FILE_EXPLICIT=0
            cli_local_profile_option_set=1
            shift
            ;;
        --profile)
            shift
            if [ "$#" -eq 0 ]; then
                printf 'cli: --profile requires a value\n' >&2
                return 64
            fi
            if [ -z "${1}" ]; then
                printf 'cli: --profile requires a value\n' >&2
                return 64
            fi
            CLI_PROFILE_REQUEST="${1}"
            CLI_PROFILE_FILE=""
            CLI_PROFILE_EXPLICIT=1
            CLI_PROFILE_FILE_EXPLICIT=0
            cli_local_profile_option_set=1
            shift
            ;;
        --profile-file=*)
            cli_local_value="${cli_local_argument#*=}"
            if [ -z "${cli_local_value}" ]; then
                printf 'cli: --profile-file requires a value\n' >&2
                return 64
            fi
            CLI_PROFILE_FILE="${cli_local_value}"
            CLI_PROFILE_REQUEST="default"
            CLI_PROFILE_EXPLICIT=0
            CLI_PROFILE_FILE_EXPLICIT=1
            cli_local_profile_file_option_set=1
            shift
            ;;
        --profile-file)
            shift
            if [ "$#" -eq 0 ]; then
                printf 'cli: --profile-file requires a value\n' >&2
                return 64
            fi
            if [ -z "${1}" ]; then
                printf 'cli: --profile-file requires a value\n' >&2
                return 64
            fi
            CLI_PROFILE_FILE="${1}"
            CLI_PROFILE_REQUEST="default"
            CLI_PROFILE_EXPLICIT=0
            CLI_PROFILE_FILE_EXPLICIT=1
            cli_local_profile_file_option_set=1
            shift
            ;;
        --tool=*)
            if [ "${CLI_TOOL_SELECTION_SOURCE}" = "environment" ]; then
                CLI_SELECTED_TOOLS=()
                CLI_TOOL_SELECTION_SOURCE="command-line"
            fi
            cli_append_tool "${cli_local_argument#*=}" || return 64
            cli_local_tool_option_set=1
            shift
            ;;
        --tool)
            shift
            if [ "$#" -eq 0 ]; then
                printf 'cli: --tool requires a value\n' >&2
                return 64
            fi
            if [ "${CLI_TOOL_SELECTION_SOURCE}" = "environment" ]; then
                CLI_SELECTED_TOOLS=()
                CLI_TOOL_SELECTION_SOURCE="command-line"
            fi
            cli_append_tool "${1}" || return 64
            cli_local_tool_option_set=1
            shift
            ;;
        --tools=*)
            cli_split_tool_list "${cli_local_argument#*=}" || return 64
            cli_local_tool_option_set=1
            shift
            ;;
        --tools)
            shift
            if [ "$#" -eq 0 ]; then
                printf 'cli: --tools requires a value\n' >&2
                return 64
            fi
            cli_split_tool_list "${1}" || return 64
            cli_local_tool_option_set=1
            shift
            ;;
        --all-extras)
            cli_local_all_option_set=1
            shift
            ;;
        --cache-dir=*)
            cli_local_value="${cli_local_argument#*=}"
            if [ -z "${cli_local_value}" ]; then
                printf 'cli: --cache-dir requires a value\n' >&2
                return 64
            fi
            CLI_CACHE_DIR="${cli_local_value}"
            shift
            ;;
        --cache-dir)
            shift
            if [ "$#" -eq 0 ] || [ -z "${1}" ]; then
                printf 'cli: --cache-dir requires a value\n' >&2
                return 64
            fi
            CLI_CACHE_DIR="${1}"
            shift
            ;;
        --lock-file=*)
            cli_local_value="${cli_local_argument#*=}"
            if [ -z "${cli_local_value}" ]; then
                printf 'cli: --lock-file requires a value\n' >&2
                return 64
            fi
            CLI_LOCK_FILE="${cli_local_value}"
            shift
            ;;
        --lock-file)
            shift
            if [ "$#" -eq 0 ] || [ -z "${1}" ]; then
                printf 'cli: --lock-file requires a value\n' >&2
                return 64
            fi
            CLI_LOCK_FILE="${1}"
            shift
            ;;
        --state-file=*)
            CLI_STATE_FILE="${cli_local_argument#*=}"
            shift
            ;;
        --state-file)
            shift
            if [ "$#" -eq 0 ]; then
                printf 'cli: --state-file requires a value\n' >&2
                return 64
            fi
            CLI_STATE_FILE="${1}"
            shift
            ;;
        --log-file=*)
            CLI_LOG_FILE="${cli_local_argument#*=}"
            shift
            ;;
        --log-file)
            shift
            if [ "$#" -eq 0 ]; then
                printf 'cli: --log-file requires a value\n' >&2
                return 64
            fi
            CLI_LOG_FILE="${1}"
            shift
            ;;
        --log-format=*)
            cli_set_log_format "${cli_local_argument#*=}" || return 64
            shift
            ;;
        --log-format)
            shift
            if [ "$#" -eq 0 ]; then
                printf 'cli: --log-format requires a value\n' >&2
                return 64
            fi
            cli_set_log_format "${1}" || return 64
            shift
            ;;
        --log-level=*)
            cli_set_log_level "${cli_local_argument#*=}" || return 64
            shift
            ;;
        --log-level)
            shift
            if [ "$#" -eq 0 ]; then
                printf 'cli: --log-level requires a value\n' >&2
                return 64
            fi
            cli_set_log_level "${1}" || return 64
            shift
            ;;
        --dry-run)
            CLI_DRY_RUN=1
            shift
            ;;
        --resume)
            CLI_RESUME=1
            shift
            ;;
        --log-stdout)
            CLI_LOG_STDOUT=1
            shift
            ;;
        --json)
            CLI_JSON=1
            shift
            ;;
        --)
            shift
            if [ "$#" -gt 0 ]; then
                printf 'cli: unexpected positional argument: %s\n' "${1}" >&2
                return 64
            fi
            ;;
        -*)
            printf 'cli: unknown option: %s\n' "${cli_local_argument}" >&2
            return 64
            ;;
        *)
            if [ "${cli_local_command_set}" -eq 1 ]; then
                printf 'cli: unexpected positional argument: %s\n' \
                    "${cli_local_argument}" >&2
                return 64
            fi
            case "${cli_local_argument}" in
            install)
                CLI_COMMAND="install"
                ;;
            extras)
                CLI_COMMAND="extras"
                ;;
            detect)
                CLI_COMMAND="detect"
                ;;
            plan)
                CLI_COMMAND="plan"
                ;;
            help)
                CLI_COMMAND="help"
                ;;
            *)
                printf 'cli: unknown command: %s\n' "${cli_local_argument}" >&2
                return 64
                ;;
            esac
            cli_local_command_set=1
            shift
            ;;
        esac
    done

    if [ "${cli_local_command_set}" -eq 0 ]; then
        printf 'cli: a command is required (install, extras, detect, plan, or help)\n' >&2
        return 64
    fi

    cli_finalize_paths || return 64

    if [ "${cli_local_profile_option_set}" -eq 1 ] &&
        [ "${cli_local_profile_file_option_set}" -eq 1 ]; then
        printf 'cli: --profile and --profile-file cannot be used together\n' >&2
        return 64
    fi

    # A command-line profile selection replaces both environment profile
    # settings. Without an explicit command-line selection, conflicting
    # environment settings remain invalid.
    if [ "${cli_local_profile_option_set}" -eq 0 ] &&
        [ "${cli_local_profile_file_option_set}" -eq 0 ] &&
        [ -n "${POSTINSTALL_PROFILE:-}" ] &&
        [ -n "${POSTINSTALL_PROFILE_FILE:-}" ]; then
        printf 'cli: POSTINSTALL_PROFILE and POSTINSTALL_PROFILE_FILE cannot be used together\n' >&2
        return 64
    fi

    if [ "${cli_local_tool_option_set}" -eq 1 ] && [ "${cli_local_all_option_set}" -eq 1 ]; then
        printf 'cli: --tool and --all-extras cannot be used together\n' >&2
        return 64
    fi
    if [ "${cli_local_all_option_set}" -eq 1 ]; then
        if [ "${CLI_TOOL_SELECTION_SOURCE}" = "environment" ]; then
            printf 'cli: --all-extras conflicts with POSTINSTALL_TOOLS\n' >&2
            return 64
        fi
        CLI_TOOL_SELECTION_MODE="all"
        CLI_TOOL_SELECTION_SOURCE="command-line"
        CLI_SELECTED_TOOLS=()
    elif [ "${cli_local_tool_option_set}" -eq 1 ]; then
        CLI_TOOL_SELECTION_MODE="explicit"
        CLI_TOOL_SELECTION_SOURCE="command-line"
    fi

    case "${CLI_COMMAND}" in
    help) ;;
    detect)
        if [ "${CLI_PROFILE_EXPLICIT}" -eq 1 ] ||
            [ "${CLI_PROFILE_FILE_EXPLICIT}" -eq 1 ] ||
            [ "${CLI_TOOL_SELECTION_SOURCE}" != "default" ] || [ "${CLI_DRY_RUN}" -eq 1 ] ||
            [ "${CLI_RESUME}" -eq 1 ]; then
            printf 'cli: profile, tool, dry-run, and resume options are not valid for detect\n' >&2
            return 64
        fi
        ;;
    plan)
        if [ "${CLI_DRY_RUN}" -eq 1 ] || [ "${CLI_RESUME}" -eq 1 ]; then
            printf 'cli: dry-run and resume options are not valid for plan\n' >&2
            return 64
        fi
        ;;
    install)
        if [ "${CLI_JSON}" -eq 1 ] && [ "${CLI_DRY_RUN}" -ne 1 ]; then
            printf 'cli: --json is only valid for detect, plan, and dry runs\n' >&2
            return 64
        fi
        ;;
    extras)
        if [ "${CLI_FLAVOR_OPTION_EXPLICIT}" -eq 1 ] ||
            [ "${CLI_PROFILE_EXPLICIT}" -eq 1 ] ||
            [ "${CLI_PROFILE_FILE_EXPLICIT}" -eq 1 ]; then
            printf 'cli: flavor and profile options are not valid for extras\n' >&2
            return 64
        fi
        if [ "${CLI_JSON}" -eq 1 ] && [ "${CLI_DRY_RUN}" -ne 1 ]; then
            printf 'cli: --json is only valid for detect, plan, and dry runs\n' >&2
            return 64
        fi
        ;;
    esac

    return 0
}

function cli_apply_options {
    export POSTINSTALL_COMMAND="${CLI_COMMAND}"
    export POSTINSTALL_DRY_RUN="${CLI_DRY_RUN}"
    export POSTINSTALL_RESUME="${CLI_RESUME}"
    export POSTINSTALL_LOG_STDOUT="${CLI_LOG_STDOUT}"
    export POSTINSTALL_LOG_FORMAT="${CLI_LOG_FORMAT}"
    export POSTINSTALL_LOG_LEVEL="${CLI_LOG_LEVEL}"
    export POSTINSTALL_JSON="${CLI_JSON}"
    export POSTINSTALL_FLAVOR="${CLI_FLAVOR}"
    export POSTINSTALL_ARCHITECTURE="${CLI_ARCHITECTURE}"
    if [ -n "${CLI_PROFILE_NAME}" ]; then
        export POSTINSTALL_PROFILE="${CLI_PROFILE_NAME}"
    else
        export POSTINSTALL_PROFILE="${CLI_PROFILE_REQUEST}"
    fi
    export POSTINSTALL_STATE_FILE="${CLI_STATE_FILE}"
    export POSTINSTALL_CACHE_DIR="${CLI_CACHE_DIR}"
    export POSTINSTALL_LOCK_FILE="${CLI_LOCK_FILE}"
    export POSTINSTALL_LOG_FILE="${CLI_LOG_FILE}"
    export POSTINSTALL_PROFILE_FILE="${CLI_PROFILE_FILE}"
    export POSTINSTALL_TOOL_SELECTION_MODE="${CLI_TOOL_SELECTION_MODE}"
    export POSTINSTALL_SELECTED_TOOLS="$(printf '%s,' "${CLI_SELECTED_TOOLS[@]}" | sed 's/,$//')"
}

function cli_render_help {
    cat <<'HELP'
Usage: bash fedora-postinstall.sh <command> [OPTIONS]

A command is required. Commands:
  install              Run the Fedora post-installation flow
  extras               Install only the additional command-line tools
  detect               Show detected OS, flavor, and architecture
  plan                 Show the module plan without changing the system
  help                 Show this help

Options:
  --flavor NAME        Fedora flavor: auto, workstation, or silverblue
  --architecture NAME  Target architecture: auto, x86_64, or aarch64
  --profile NAME|PATH  Built-in/user profile name or JSON profile path
  --profile-file PATH  Read a profile from an explicit JSON file
  --cache-dir PATH     Cache directory for verified tool downloads
  --lock-file PATH     Installer lock file
  --tool ID            Select an extra tool (repeatable)
  --tools LIST         Select comma-separated extra tools
  --all-extras         Select every extra tool available for the architecture
  --dry-run            Print a non-mutating plan (JSON with --json)
  --resume             Reuse compatible completed state
  --state-file PATH    Resume state file
  --log-file PATH      Structured runtime log file
  --log-format FORMAT  Runtime log format: plain or json (JSON Lines)
  --log-level LEVEL    Log level: debug, info, warn, or error
  --log-stdout         Also write logs to stdout (JSON logs to stderr)
  --json               Emit machine-readable detect, plan, or dry-run output
  -h, --help           Show this help

Environment equivalents include POSTINSTALL_FLAVOR, POSTINSTALL_ARCHITECTURE,
POSTINSTALL_PROFILE, POSTINSTALL_PROFILE_FILE, POSTINSTALL_TOOLS,
POSTINSTALL_CACHE_DIR, POSTINSTALL_LOCK_FILE, POSTINSTALL_DRY_RUN,
POSTINSTALL_RESUME, POSTINSTALL_STATE_FILE, POSTINSTALL_LOG_FILE,
POSTINSTALL_LOG_FORMAT, POSTINSTALL_LOG_LEVEL, and
POSTINSTALL_LOG_STDOUT.
HELP
}
