#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

# Shared generator for the managed home-directory helper scripts. The
# generated files are standalone and do not depend on this repository or Gum.

declare -g HOME_HELPERS_TEMPORARY_PATH=""
declare -g HOME_HELPERS_CLEANUP_REGISTERED=0
declare -g HOME_HELPERS_MANAGED_ROOT=""

function home_helpers_reject_symlink_components {
    local home_helpers_local_path="${1:-}"
    local home_helpers_local_current
    local home_helpers_local_next

    if [ -z "${home_helpers_local_path}" ] ||
        [[ "${home_helpers_local_path}" != /* ]]; then
        printf 'home: invalid absolute path: %s\n' \
            "${home_helpers_local_path}" >&2
        return 1
    fi

    home_helpers_local_current="${home_helpers_local_path}"
    while [ "${home_helpers_local_current}" != "/" ]; do
        if [ -L "${home_helpers_local_current}" ]; then
            printf 'home: refusing to use a path with a symbolic-link component: %s\n' \
                "${home_helpers_local_path}" >&2
            return 1
        fi
        home_helpers_local_next=$(dirname -- "${home_helpers_local_current}") ||
            return 1
        if [ "${home_helpers_local_next}" = "${home_helpers_local_current}" ]; then
            break
        fi
        home_helpers_local_current="${home_helpers_local_next}"
    done
    if [ -L "/" ]; then
        printf 'home: refusing to use a path with a symbolic-link component: %s\n' \
            "${home_helpers_local_path}" >&2
        return 1
    fi
    return 0
}

function home_helpers_cleanup_temporary {
    if [ -z "${HOME_HELPERS_TEMPORARY_PATH}" ]; then
        return 0
    fi
    if [ -e "${HOME_HELPERS_TEMPORARY_PATH}" ] ||
        [ -L "${HOME_HELPERS_TEMPORARY_PATH}" ]; then
        rm -f -- "${HOME_HELPERS_TEMPORARY_PATH}" || return $?
    fi
    return 0
}

function home_helpers_remove_temporary {
    local home_helpers_local_cleanup_status=0

    home_helpers_cleanup_temporary ||
        home_helpers_local_cleanup_status="${?}"
    if [ "${home_helpers_local_cleanup_status}" -eq 0 ]; then
        HOME_HELPERS_TEMPORARY_PATH=""
        if [ "${HOME_HELPERS_CLEANUP_REGISTERED}" -eq 1 ] &&
            declare -F runtime_unregister_cleanup >/dev/null; then
            if runtime_unregister_cleanup "home-helpers-temporary"; then
                HOME_HELPERS_CLEANUP_REGISTERED=0
            fi
        fi
    fi
    return "${home_helpers_local_cleanup_status}"
}

function home_helpers_track_temporary {
    local home_helpers_local_temporary="${1:-}"

    HOME_HELPERS_TEMPORARY_PATH="${home_helpers_local_temporary}"
    if declare -F runtime_register_cleanup >/dev/null &&
        declare -F runtime_unregister_cleanup >/dev/null; then
        if ! runtime_register_cleanup \
            "home-helpers-temporary" home_helpers_cleanup_temporary; then
            return 1
        fi
        HOME_HELPERS_CLEANUP_REGISTERED=1
    fi
    return 0
}

function home_helpers_validate_file_target {
    local home_helpers_local_target="${1:-}"
    local home_helpers_local_parent
    local home_helpers_local_parent_real
    local home_helpers_local_root_real

    if [ -z "${home_helpers_local_target}" ] ||
        [[ "${home_helpers_local_target}" != /* ]] ||
        [[ "${home_helpers_local_target}" =~ [[:cntrl:]] ]]; then
        printf 'home: invalid generated-file path: %s\n' \
            "${home_helpers_local_target}" >&2
        return 1
    fi
    if ! home_helpers_reject_symlink_components "${home_helpers_local_target}"; then
        return 1
    fi
    if [ -e "${home_helpers_local_target}" ] &&
        [ ! -f "${home_helpers_local_target}" ]; then
        printf 'home: generated-file target is not a regular file: %s\n' \
            "${home_helpers_local_target}" >&2
        return 1
    fi

    home_helpers_local_parent=$(dirname -- "${home_helpers_local_target}") || return 1
    if [ ! -d "${home_helpers_local_parent}" ] ||
        [ -L "${home_helpers_local_parent}" ]; then
        printf 'home: generated-file directory is unavailable: %s\n' \
            "${home_helpers_local_parent}" >&2
        return 1
    fi
    if [ -n "${HOME_HELPERS_MANAGED_ROOT}" ]; then
        home_helpers_local_root_real=$(realpath -e -- \
            "${HOME_HELPERS_MANAGED_ROOT}") || return 1
        home_helpers_local_parent_real=$(realpath -e -- \
            "${home_helpers_local_parent}") || return 1
        if [ "${home_helpers_local_root_real}" != "/" ] &&
            [ "${home_helpers_local_parent_real}" != "${home_helpers_local_root_real}" ] &&
            [[ "${home_helpers_local_parent_real}" != "${home_helpers_local_root_real}/"* ]]; then
            printf 'home: generated-file directory escapes the managed root.\n' >&2
            return 1
        fi
    fi
    return 0
}

function home_helpers_write_file {
    local home_helpers_local_target="${1:-}"
    local home_helpers_local_mode="${2:-0644}"
    local home_helpers_local_temporary
    local home_helpers_local_status=0

    shift 2 || return 1
    if [ "$#" -eq 0 ]; then
        printf 'home: a generated-file renderer is required.\n' >&2
        return 1
    fi
    if ! [[ "${home_helpers_local_mode}" =~ ^[0-7]{3,4}$ ]]; then
        printf 'home: invalid generated-file mode: %s\n' \
            "${home_helpers_local_mode}" >&2
        return 1
    fi
    if ! home_helpers_validate_file_target "${home_helpers_local_target}"; then
        return 1
    fi

    home_helpers_local_temporary=$(mktemp \
        "${home_helpers_local_target}.tmp.XXXXXX") || return 1
    if ! home_helpers_track_temporary "${home_helpers_local_temporary}"; then
        home_helpers_remove_temporary || true
        return 1
    fi
    chmod "${home_helpers_local_mode}" \
        "${home_helpers_local_temporary}" ||
        home_helpers_local_status="${?}"
    if [ "${home_helpers_local_status}" -ne 0 ]; then
        home_helpers_remove_temporary || true
        return "${home_helpers_local_status}"
    fi
    "$@" >"${home_helpers_local_temporary}" ||
        home_helpers_local_status="${?}"
    if [ "${home_helpers_local_status}" -ne 0 ]; then
        home_helpers_remove_temporary || true
        return "${home_helpers_local_status}"
    fi
    mv -fT -- "${home_helpers_local_temporary}" \
        "${home_helpers_local_target}" ||
        home_helpers_local_status="${?}"
    if [ "${home_helpers_local_status}" -ne 0 ]; then
        home_helpers_remove_temporary || true
        return "${home_helpers_local_status}"
    fi
    home_helpers_remove_temporary || true
    return 0
}

function home_helpers_update_bashrc {
    local home_helpers_local_bashrc="${1:-}"
    local home_helpers_local_root="${2:-}"
    local home_helpers_local_begin="# BEGIN fedora-postinstall managed home configuration"
    local home_helpers_local_end="# END fedora-postinstall managed home configuration"
    local home_helpers_local_legacy="# managed home configuration"
    local home_helpers_local_mode="0644"
    local home_helpers_local_root_quoted
    local home_helpers_local_temporary
    local home_helpers_local_status=0

    if [ -z "${home_helpers_local_bashrc}" ] ||
        [ -z "${home_helpers_local_root}" ] ||
        [[ "${home_helpers_local_bashrc}" != /* ]] ||
        [[ "${home_helpers_local_root}" != /* ]] ||
        [[ "${home_helpers_local_bashrc}" =~ [[:cntrl:]] ]] ||
        [[ "${home_helpers_local_root}" =~ [[:cntrl:]] ]]; then
        printf 'home: the Bash entry point and managed root must be safe absolute paths.\n' >&2
        return 1
    fi
    if ! home_helpers_reject_symlink_components "${home_helpers_local_bashrc}"; then
        return 1
    fi
    if ! home_helpers_reject_symlink_components "${home_helpers_local_root}"; then
        return 1
    fi
    if [ -e "${home_helpers_local_bashrc}" ] &&
        [ ! -f "${home_helpers_local_bashrc}" ]; then
        printf 'home: the Bash entry point is not a regular file: %s\n' \
            "${home_helpers_local_bashrc}" >&2
        return 1
    fi
    if [ ! -d "$(dirname -- "${home_helpers_local_bashrc}")" ]; then
        printf 'home: the Bash entry-point directory is unavailable.\n' >&2
        return 1
    fi

    printf -v home_helpers_local_root_quoted '%q' "${home_helpers_local_root}"
    home_helpers_local_temporary=$(mktemp \
        "${home_helpers_local_bashrc}.tmp.XXXXXX") || return 1
    if ! home_helpers_track_temporary "${home_helpers_local_temporary}"; then
        home_helpers_remove_temporary || true
        return 1
    fi

    if [ -f "${home_helpers_local_bashrc}" ]; then
        home_helpers_local_mode=$(stat -c '%a' -- \
            "${home_helpers_local_bashrc}") || home_helpers_local_mode="0644"
        awk \
            -v begin_marker="${home_helpers_local_begin}" \
            -v end_marker="${home_helpers_local_end}" \
            -v legacy_marker="${home_helpers_local_legacy}" '
                function invalid_legacy() {
                    malformed = 1
                }
                $0 == begin_marker {
                    if (current_open || current_found || legacy_found) {
                        ambiguous = 1
                        next
                    }
                    current_open = 1
                    current_found = 1
                    next
                }
                $0 == end_marker {
                    if (!current_open) {
                        invalid = 1
                        next
                    }
                    current_open = 0
                    next
                }
                $0 == legacy_marker {
                    if (legacy_found || current_found || current_open) {
                        ambiguous = 1
                        next
                    }
                    legacy_line_one = ""
                    legacy_line_two = ""
                    legacy_line_three = ""
                    if ((getline legacy_line_one) <= 0 ||
                        (getline legacy_line_two) <= 0 ||
                        (getline legacy_line_three) <= 0) {
                        invalid_legacy()
                        next
                    }
                    if (legacy_line_three != "fi") {
                        invalid_legacy()
                        next
                    }
                    if (substr(legacy_line_one, 1, 9) != "if [ -e \"" ||
                        substr(legacy_line_one, length(legacy_line_one) - 8) != "\" ]; then" ||
                        substr(legacy_line_two, 1, 12) != "    source \"" ||
                        substr(legacy_line_two, length(legacy_line_two)) != "\"") {
                        invalid_legacy()
                        next
                    }
                    legacy_path_one = substr(legacy_line_one, 10, length(legacy_line_one) - 18)
                    legacy_path_two = substr(legacy_line_two, 13, length(legacy_line_two) - 13)
                    if (legacy_path_one !~ "^/[A-Za-z0-9_./-]+$" ||
                        legacy_path_two != legacy_path_one ||
                        length(legacy_path_one) <= 16 ||
                        substr(legacy_path_one, length(legacy_path_one) - 15) != "/scripts/bash.sh") {
                        invalid_legacy()
                        next
                    }
                    legacy_found = 1
                    next
                }
                current_open {
                    next
                }
                {
                    print
                }
                END {
                    if (ambiguous) {
                        exit 44
                    }
                    if (malformed) {
                        exit 45
                    }
                    if (current_open) {
                        exit 42
                    }
                    if (invalid) {
                        exit 43
                    }
                }
            ' "${home_helpers_local_bashrc}" \
            >"${home_helpers_local_temporary}" ||
            home_helpers_local_status="${?}"
        if [ "${home_helpers_local_status}" -ne 0 ]; then
            home_helpers_remove_temporary || true
            case "${home_helpers_local_status}" in
            42 | 43)
                printf 'home: the Bash entry point contains an unmatched managed block.\n' >&2
                ;;
            44)
                printf 'home: the Bash entry point contains an ambiguous managed block.\n' >&2
                ;;
            45)
                printf 'home: the Bash entry point contains a malformed legacy managed block.\n' >&2
                ;;
            *)
                printf 'home: unable to parse the Bash entry point safely.\n' >&2
                ;;
            esac
            return "${home_helpers_local_status}"
        fi
    fi

    {
        printf '%s\n' "${home_helpers_local_begin}"
        printf 'if [ -e %s/scripts/bash.sh ]; then\n' \
            "${home_helpers_local_root_quoted}"
        printf '    source %s/scripts/bash.sh\n' \
            "${home_helpers_local_root_quoted}"
        printf 'fi\n'
        printf '%s\n' "${home_helpers_local_end}"
    } >>"${home_helpers_local_temporary}" ||
        home_helpers_local_status="${?}"
    if [ "${home_helpers_local_status}" -ne 0 ]; then
        home_helpers_remove_temporary || true
        return "${home_helpers_local_status}"
    fi
    chmod "${home_helpers_local_mode}" \
        "${home_helpers_local_temporary}" ||
        home_helpers_local_status="${?}"
    if [ "${home_helpers_local_status}" -ne 0 ]; then
        home_helpers_remove_temporary || true
        return "${home_helpers_local_status}"
    fi
    mv -fT -- "${home_helpers_local_temporary}" \
        "${home_helpers_local_bashrc}" ||
        home_helpers_local_status="${?}"
    if [ "${home_helpers_local_status}" -ne 0 ]; then
        home_helpers_remove_temporary || true
        return "${home_helpers_local_status}"
    fi
    home_helpers_remove_temporary || true
    return 0
}

function home_helpers_validate_root_and_flavor {
    local home_helpers_local_root="${1:-}"
    local home_helpers_local_flavor="${2:-}"

    if [ -z "${home_helpers_local_root}" ] ||
        [[ "${home_helpers_local_root}" != /* ]] ||
        [[ "${home_helpers_local_root}" =~ [[:cntrl:]] ]]; then
        printf 'home: invalid managed root: %s\n' \
            "${home_helpers_local_root}" >&2
        return 1
    fi
    case "${home_helpers_local_flavor}" in
    workstation | silverblue) ;;
    *)
        printf 'home: unsupported helper flavor: %s\n' \
            "${home_helpers_local_flavor}" >&2
        return 1
        ;;
    esac
    return 0
}

function home_helpers_render_bash_content {
    local home_helpers_local_root="${1:-}"
    local home_helpers_local_flavor="${2:-}"
    local home_helpers_local_root_quoted

    if ! home_helpers_validate_root_and_flavor \
        "${home_helpers_local_root}" "${home_helpers_local_flavor}"; then
        return 1
    fi
    printf -v home_helpers_local_root_quoted '%q' "${home_helpers_local_root}"
    cat <<'HOME_HELPERS_BASH_HEADER'
#!/usr/bin/env bash

# Generated by fedora-postinstall. Manual edits are replaced on the next run.
HOME_HELPERS_BASH_HEADER
    printf 'HOME_CONFIGURATION_ROOT=%s\n' "${home_helpers_local_root_quoted}"
    printf 'HOME_CONFIGURATION_FLAVOR=%q\n' "${home_helpers_local_flavor}"
    cat <<'HOME_HELPERS_BASH'

if [ -f /usr/bin/fortune ]; then
    /usr/bin/fortune
fi

for home_configuration_script in aliases completion colors rust go toolbox; do
    if [ -e "${HOME_CONFIGURATION_ROOT}/scripts/${home_configuration_script}.sh" ]; then
        source "${HOME_CONFIGURATION_ROOT}/scripts/${home_configuration_script}.sh"
    fi
done

if [ "${HOME_CONFIGURATION_FLAVOR}" = "silverblue" ] &&
    [ -e "${HOME_CONFIGURATION_ROOT}/scripts/homebrew.sh" ]; then
    source "${HOME_CONFIGURATION_ROOT}/scripts/homebrew.sh"
fi

if [ "${HOME_CONFIGURATION_FLAVOR}" = "workstation" ]; then
    for home_configuration_script in taskwarrior forgit; do
        if [ -e "${HOME_CONFIGURATION_ROOT}/scripts/${home_configuration_script}.sh" ]; then
            source "${HOME_CONFIGURATION_ROOT}/scripts/${home_configuration_script}.sh"
        fi
    done
fi

if [ -x "$(command -v starship)" ]; then
    export STARSHIP_CONFIG="${HOME_CONFIGURATION_ROOT}/config/starship/starship.toml"
    export STARSHIP_LOG="error"
    eval "$(starship init bash)"
fi

if [ -x "$(command -v direnv)" ]; then
    eval "$(direnv hook bash)"
fi

if [ -x "$(command -v carapace)" ]; then
    export CARAPACE_BRIDGES='zsh,fish,bash,inshellisense'
    source <(carapace _carapace)
fi

if [ -x "$(command -v zoxide)" ]; then
    export _ZO_DATA_DIR="${HOME_CONFIGURATION_ROOT}/data/zoxide"
    eval "$(zoxide init bash)"
fi

if [ -x "$(command -v mise)" ]; then
    export MISE_DATA_DIR="${HOME_CONFIGURATION_ROOT}/data/mise"
    export MISE_CONFIG_DIR="${HOME_CONFIGURATION_ROOT}/config/mise"
fi

if [ "${HOME_CONFIGURATION_FLAVOR}" = "workstation" ] &&
    [ -x "$(command -v fzf)" ]; then
    eval "$(fzf --bash)"
fi
HOME_HELPERS_BASH
}

function home_helpers_render_aliases_content {
    local home_helpers_local_root="${1:-}"
    local home_helpers_local_flavor="${2:-}"
    local home_helpers_local_command="${3:-}"
    local home_helpers_local_retention_available="${4:-1}"
    local home_helpers_local_keep_ids_value="${5:-}"
    local home_helpers_local_keep_id
    local -a home_helpers_local_keep_ids=()

    if ! home_helpers_validate_render_arguments \
        "${home_helpers_local_root}" \
        "${home_helpers_local_flavor}" \
        "${home_helpers_local_command}" \
        "${home_helpers_local_retention_available}" \
        "${home_helpers_local_keep_ids_value}"; then
        return 1
    fi
    if [ -n "${home_helpers_local_keep_ids_value}" ]; then
        while IFS= read -r home_helpers_local_keep_id; do
            [ -n "${home_helpers_local_keep_id}" ] || continue
            home_helpers_local_keep_ids+=("${home_helpers_local_keep_id}")
        done <<<"${home_helpers_local_keep_ids_value}"
    fi

    cat <<'HOME_HELPERS_ALIASES_HEADER'
#!/usr/bin/env bash

# Generated by fedora-postinstall. Manual edits are replaced on the next run.
HOME_HELPERS_ALIASES_HEADER
    printf 'HOME_CONFIGURATION_ROOT=%q\n' "${home_helpers_local_root}"
    printf 'HOME_CONFIGURATION_FLAVOR=%q\n' "${home_helpers_local_flavor}"
    printf 'HOME_CONFIGURATION_COMMAND=%q\n' "${home_helpers_local_command}"
    printf 'HOME_CONFIGURATION_FLATPAKS_RETENTION_AVAILABLE=%q\n' \
        "${home_helpers_local_retention_available}"
    printf 'HOME_CONFIGURATION_FLATPAKS_KEEP_FILTER=()\n'
    printf '_HOST_ROLLING_LOCK_FD=""\n'
    printf '_HOST_ROLLING_CHILD_PID=""\n'
    printf '_HOST_ROLLING_RECEIVED_SIGNAL_STATUS=0\n'
    printf '_HOST_ROLLING_RECEIVED_SIGNAL_NAME=""\n'
    printf '_HOST_ROLLING_RUNNER_RECEIVED_SIGNAL_STATUS=0\n'
    printf '_HOST_ROLLING_RUNNER_RECEIVED_SIGNAL_NAME=""\n'
    printf '_HOST_ROLLING_TEMPORARY_PATH=""\n'
    printf '_HOST_ROLLING_PREVIOUS_EXIT_TRAP=""\n'
    for home_helpers_local_keep_id in "${home_helpers_local_keep_ids[@]}"; do
        [ -n "${home_helpers_local_keep_id}" ] || continue
        printf 'HOME_CONFIGURATION_FLATPAKS_KEEP_FILTER+=("-not" "-name" %q)\n' \
            "${home_helpers_local_keep_id}"
    done
    cat <<'HOME_HELPERS_ALIASES'

_host_info() {
    printf 'info: %s\n' "$*"
}

_host_done() {
    printf 'done: %s\n' "$*"
}

_host_warn() {
    printf 'warning: %s\n' "$*" >&2
}

_host_error() {
    printf 'error: %s\n' "$*" >&2
}

_host_print_usage() {
    printf '%s\n' \
        "Fedora ${HOME_CONFIGURATION_FLAVOR} command helper." \
        "Usage: ${HOME_CONFIGURATION_COMMAND} <action> <target> [arguments]" >&2
    cat <<'USAGE' >&2
Actions and targets:
  upgrade system|starship|tex|sdk|vim|nvim|node|youtube|rust|deno|bun|flatpak|conda|distrobox|direnv|uv|mise|brew|world
  clean   flatpak|logs|cache|system|permissions
  config  reset
  use     sdk|conda|node|server|mise

Additional targets:
  clean permissions reset       reset every Flatpak permission-store grant after an export
  clean permissions app APP_ID  reset one application's permission-store grants
  config reset app-grid         reset the GNOME application-grid layout
  use server [DIRECTORY] [--public]
                                 serve DIRECTORY (default: current directory)
USAGE
}

_host_confirm_exact() {
    local host_confirmation_prompt="${1:-}"
    local host_confirmation_expected="${2:-}"
    local host_confirmation_response=""
    local host_confirmation_status=0

    if [ ! -t 0 ] || [ ! -t 2 ]; then
        _host_error "A terminal is required to confirm this operation."
        return 64
    fi
    printf '%s' "${host_confirmation_prompt}" >&2
    IFS= read -r host_confirmation_response || host_confirmation_status="${?}"
    if [ "${host_confirmation_status}" -ne 0 ]; then
        _host_error "Unable to read the confirmation."
        return "${host_confirmation_status}"
    fi
    if [ "${host_confirmation_response}" != "${host_confirmation_expected}" ]; then
        _host_info "The operation was canceled."
        return 1
    fi
    return 0
}

_host_confirm_yes_no() {
    local host_confirmation_prompt="${1:-}"
    local host_confirmation_response=""
    local host_confirmation_status=0

    if [ ! -t 0 ] || [ ! -t 2 ]; then
        _host_error "A terminal is required to confirm this operation."
        return 64
    fi
    printf '%s' "${host_confirmation_prompt}" >&2
    IFS= read -r host_confirmation_response || host_confirmation_status="${?}"
    if [ "${host_confirmation_status}" -ne 0 ]; then
        _host_error "Unable to read the Firefox confirmation."
        return "${host_confirmation_status}"
    fi
    case "${host_confirmation_response}" in
    [yY] | [yY][eE][sS]) return 0 ;;
    *)
        _host_error "Firefox was not stopped; cache cleanup was canceled."
        return 1
        ;;
    esac
}

_host_is_toolbox() {
    [[ -f /run/.containerenv && -f /run/.toolboxenv ]]
}

_host_rolling_tool_from_url() {
    local host_rolling_url="${1:-}"
    local host_rolling_hash
    local host_rolling_tool

    case "${host_rolling_url}" in
    https://starship.rs/*)
        host_rolling_tool="starship"
        ;;
    https://direnv.net/*)
        host_rolling_tool="direnv"
        ;;
    https://raw.githubusercontent.com/*/distrobox/*)
        host_rolling_tool="distrobox"
        ;;
    *)
        host_rolling_hash=$(
            printf '%s' "${host_rolling_url}" | sha256sum
        ) || return 1
        host_rolling_hash="${host_rolling_hash%% *}"
        host_rolling_tool="url-${host_rolling_hash:0:16}"
        ;;
    esac
    printf '%s\n' "${host_rolling_tool}"
}

_host_rolling_lock_path() {
    local host_rolling_url="${1:-}"
    local host_rolling_base=""
    local host_rolling_tool
    local host_rolling_uid

    host_rolling_tool=$(_host_rolling_tool_from_url \
        "${host_rolling_url}") || return 1
    if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
        host_rolling_base="${XDG_RUNTIME_DIR}"
        if [ ! -d "${host_rolling_base}" ] ||
            [ -L "${host_rolling_base}" ] ||
            [ ! -O "${host_rolling_base}" ]; then
            return 1
        fi
    else
        host_rolling_uid=$(id -u) || return 1
        host_rolling_base="/tmp/fedora-postinstall-${host_rolling_uid}"
        if [ -L "${host_rolling_base}" ]; then
            return 1
        fi
        if [ -e "${host_rolling_base}" ] &&
            [ ! -d "${host_rolling_base}" ]; then
            return 1
        fi
        mkdir -p -m 0700 -- "${host_rolling_base}" || return 1
        chmod 0700 -- "${host_rolling_base}" || return 1
        if [ -L "${host_rolling_base}" ] ||
            [ ! -d "${host_rolling_base}" ] ||
            [ ! -O "${host_rolling_base}" ]; then
            return 1
        fi
    fi
    printf '%s/rolling-install-%s.lock\n' \
        "${host_rolling_base}" "${host_rolling_tool}"
}

_host_rolling_lock_acquire() {
    local host_rolling_url="${1:-}"
    local host_rolling_path
    local host_rolling_status=0
    local host_rolling_timeout="${ROLLING_INSTALLER_LOCK_TIMEOUT_SECONDS:-300}"

    if ! [[ "${host_rolling_timeout}" =~ ^[0-9]+$ ]] ||
        [ "${host_rolling_timeout}" -lt 1 ] ||
        [ "${host_rolling_timeout}" -gt 3600 ]; then
        return 64
    fi
    command -v flock >/dev/null 2>&1 || return 127
    host_rolling_path=$(_host_rolling_lock_path \
        "${host_rolling_url}") || return 1
    if [ -L "${host_rolling_path}" ]; then
        return 1
    fi
    if [ -e "${host_rolling_path}" ] &&
        [ ! -f "${host_rolling_path}" ]; then
        return 1
    fi
    (
        umask 077
        : >>"${host_rolling_path}"
    ) || return 1
    if [ -L "${host_rolling_path}" ] ||
        [ ! -f "${host_rolling_path}" ] ||
        [ ! -O "${host_rolling_path}" ]; then
        return 1
    fi

    exec {_HOST_ROLLING_LOCK_FD}<>"${host_rolling_path}" || return 1
    flock -w "${host_rolling_timeout}" -x \
        "${_HOST_ROLLING_LOCK_FD}" ||
        host_rolling_status="${?}"
    if [ "${host_rolling_status}" -ne 0 ]; then
        exec {_HOST_ROLLING_LOCK_FD}>&- || true
        _HOST_ROLLING_LOCK_FD=""
        return "${host_rolling_status}"
    fi
    return 0
}

_host_rolling_lock_release() {
    local host_rolling_status=0

    if [ -z "${_HOST_ROLLING_LOCK_FD}" ]; then
        return 0
    fi
    flock -u "${_HOST_ROLLING_LOCK_FD}" ||
        host_rolling_status="${?}"
    exec {_HOST_ROLLING_LOCK_FD}>&- ||
        host_rolling_status="${?}"
    _HOST_ROLLING_LOCK_FD=""
    return "${host_rolling_status}"
}

_host_rolling_process_group_id() {
    local host_rolling_pid="${1:-}"
    local host_rolling_stat=""
    local host_rolling_fields_text=""
    local host_rolling_group_id=""
    local -a host_rolling_fields=()

    if ! [[ "${host_rolling_pid}" =~ ^[0-9]+$ ]] ||
        [ "${host_rolling_pid}" -le 1 ] ||
        [ ! -r "/proc/${host_rolling_pid}/stat" ]; then
        return 1
    fi
    host_rolling_stat=$(
        cat "/proc/${host_rolling_pid}/stat" 2>/dev/null
    ) || return 1
    host_rolling_fields_text="${host_rolling_stat##*) }"
    read -r -a host_rolling_fields <<<"${host_rolling_fields_text}"
    if [ "${#host_rolling_fields[@]}" -le 2 ]; then
        return 1
    fi
    host_rolling_group_id="${host_rolling_fields[2]}"
    if ! [[ "${host_rolling_group_id}" =~ ^[0-9]+$ ]] ||
        [ "${host_rolling_group_id}" -le 1 ]; then
        return 1
    fi
    printf '%s\n' "${host_rolling_group_id}"
}

_host_rolling_signal_process_tree() {
    local host_rolling_signal="${1:-TERM}"
    local host_rolling_pid="${2:-}"
    local host_rolling_children=""
    local host_rolling_child
    local host_rolling_group_id=""

    if ! [[ "${host_rolling_pid}" =~ ^[0-9]+$ ]] ||
        [ "${host_rolling_pid}" -le 1 ]; then
        return 1
    fi
    if ! kill -0 "${host_rolling_pid}" 2>/dev/null; then
        return 1
    fi

    # The installer is launched in its own process group. A group-directed
    # signal reaches the installer and every helper it started, even when a
    # descendant changes its own signal disposition. Only use the group form
    # after verifying that the child is its leader; otherwise a numeric group
    # could refer to an unrelated process.
    host_rolling_group_id=$(_host_rolling_process_group_id \
        "${host_rolling_pid}") || host_rolling_group_id=""
    if [ "${host_rolling_group_id}" = "${host_rolling_pid}" ]; then
        kill -s "${host_rolling_signal}" -- \
            "-${host_rolling_pid}" 2>/dev/null ||
            kill -s "${host_rolling_signal}" \
                "${host_rolling_pid}" 2>/dev/null ||
            return 1
        return 0
    fi

    # Fall back to walking the direct descendants if process-group metadata is
    # unavailable. This path is slower and inherently racy, but it remains
    # bounded and never signals an unverified process group.
    if command -v pgrep >/dev/null 2>&1; then
        host_rolling_children=$(
            pgrep -P "${host_rolling_pid}" 2>/dev/null
        ) || host_rolling_children=""
        for host_rolling_child in ${host_rolling_children}; do
            _host_rolling_signal_process_tree \
                "${host_rolling_signal}" "${host_rolling_child}" || true
        done
        sleep 0.1 || true
        kill -s "${host_rolling_signal}" \
            "${host_rolling_pid}" 2>/dev/null || true
        return 0
    fi
    kill -s "${host_rolling_signal}" \
        "${host_rolling_pid}" 2>/dev/null || return 1
    return 0
}

_host_rolling_handle_signal() {
    local host_rolling_signal="${1:-TERM}"
    local host_rolling_status="${2:-143}"

    if [ "${_HOST_ROLLING_RECEIVED_SIGNAL_STATUS}" -eq 0 ]; then
        _HOST_ROLLING_RECEIVED_SIGNAL_STATUS="${host_rolling_status}"
        _HOST_ROLLING_RECEIVED_SIGNAL_NAME="${host_rolling_signal}"
    fi
    if [ -n "${_HOST_ROLLING_CHILD_PID}" ]; then
        _host_rolling_signal_process_tree \
            "${host_rolling_signal}" "${_HOST_ROLLING_CHILD_PID}" || true
    fi
    return 0
}

_host_rolling_process_running() {
    local host_rolling_pid="${1:-}"
    local host_rolling_state=""
    local host_rolling_stat=""

    if ! [[ "${host_rolling_pid}" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    kill -0 "${host_rolling_pid}" 2>/dev/null || return 1
    if [ -r "/proc/${host_rolling_pid}/stat" ]; then
        host_rolling_stat=$(
            cat "/proc/${host_rolling_pid}/stat" 2>/dev/null
        ) || return 1
        host_rolling_state="${host_rolling_stat##*) }"
        host_rolling_state="${host_rolling_state%% *}"
        if [ "${host_rolling_state}" = "Z" ]; then
            return 1
        fi
    fi
    return 0
}

_host_rolling_restore_trap() {
    local host_rolling_previous="${1:-}"
    local host_rolling_signal="${2:-HUP}"

    if [ -n "${host_rolling_previous}" ]; then
        eval "${host_rolling_previous}"
    else
        trap - "${host_rolling_signal}"
    fi
}

_host_rolling_execute() {
    local host_rolling_shell="${1:-}"
    local host_rolling_path="${2:-}"
    local host_rolling_timeout="${ROLLING_INSTALLER_TIMEOUT_SECONDS:-600}"
    local host_rolling_grace="${ROLLING_INSTALLER_KILL_GRACE_SECONDS:-5}"
    local host_rolling_child_status=0
    local host_rolling_marker
    local host_rolling_marker_directory
    local host_rolling_monitor_enabled=0
    local host_rolling_watchdog_monitor_enabled=0
    local host_rolling_previous_hup
    local host_rolling_previous_int
    local host_rolling_previous_term
    local host_rolling_status=0
    local host_rolling_watchdog
    local host_rolling_watchdog_status=0

    shift 2 || return 1
    if [ -z "${host_rolling_shell}" ] ||
        [ -z "${host_rolling_path}" ]; then
        return 64
    fi
    if ! [[ "${host_rolling_timeout}" =~ ^[0-9]+$ ]] ||
        [ "${host_rolling_timeout}" -lt 1 ] ||
        [ "${host_rolling_timeout}" -gt 86400 ]; then
        return 64
    fi
    if ! [[ "${host_rolling_grace}" =~ ^[0-9]+$ ]] ||
        [ "${host_rolling_grace}" -lt 1 ] ||
        [ "${host_rolling_grace}" -gt 60 ]; then
        return 64
    fi

    host_rolling_marker_directory=$(mktemp -d \
        "${TMPDIR:-/tmp}/fedora-postinstall-rolling-timeout.XXXXXX") || return 1
    host_rolling_marker="${host_rolling_marker_directory}/timeout"
    host_rolling_previous_hup=$(trap -p HUP) || true
    host_rolling_previous_int=$(trap -p INT) || true
    host_rolling_previous_term=$(trap -p TERM) || true

    # Run the installer in its own process group. This restores the default
    # SIGINT disposition for a non-interactive helper shell and lets one
    # group-directed signal reach the installer and every helper it started.
    _HOST_ROLLING_RECEIVED_SIGNAL_STATUS=0
    _HOST_ROLLING_RECEIVED_SIGNAL_NAME=""

    # Install the forwarding traps before the child can announce readiness.
    # Otherwise a signal arriving in the small launch window would be handled
    # by the caller's default trap and could mask the installer's status.
    trap '_host_rolling_handle_signal HUP 129' HUP
    trap '_host_rolling_handle_signal INT 130' INT
    trap '_host_rolling_handle_signal TERM 143' TERM

    if [[ "$-" == *m* ]]; then
        host_rolling_monitor_enabled=1
    else
        set -m
    fi
    "${host_rolling_shell}" "${host_rolling_path}" "$@" &
    _HOST_ROLLING_CHILD_PID="${!}"
    if [ "${host_rolling_monitor_enabled}" -eq 0 ]; then
        set +m
    fi
    if [ -n "${_HOST_ROLLING_RECEIVED_SIGNAL_NAME}" ]; then
        _host_rolling_handle_signal \
            "${_HOST_ROLLING_RECEIVED_SIGNAL_NAME}" \
            "${_HOST_ROLLING_RECEIVED_SIGNAL_STATUS}"
    fi

    # Give the watchdog its own process group so it can be terminated
    # together with its sleeping child without touching the installer group.
    if [[ "$-" == *m* ]]; then
        host_rolling_watchdog_monitor_enabled=1
    else
        set -m
    fi
    (
        sleep "${host_rolling_timeout}" || exit 0
        if _host_rolling_process_running "${_HOST_ROLLING_CHILD_PID}"; then
            mkdir -- "${host_rolling_marker}" 2>/dev/null || true
            _host_rolling_signal_process_tree TERM \
                "${_HOST_ROLLING_CHILD_PID}" || true
            sleep "${host_rolling_grace}" || true
            _host_rolling_signal_process_tree KILL \
                "${_HOST_ROLLING_CHILD_PID}" || true
        fi
    ) >/dev/null 2>&1 &
    host_rolling_watchdog="${!}"
    if [ "${host_rolling_watchdog_monitor_enabled}" -eq 0 ]; then
        set +m
    fi

    # Avoid waiting directly on a live asynchronous child: Bash can defer an
    # INT trap until that child exits. Short foreground sleeps keep the trap
    # responsive so the signal can be forwarded promptly; wait then reaps the
    # exited child and preserves its exact status.
    while _host_rolling_process_running "${_HOST_ROLLING_CHILD_PID}"; do
        sleep 0.1 || true
    done
    if wait "${_HOST_ROLLING_CHILD_PID}"; then
        host_rolling_child_status=0
    else
        host_rolling_child_status="${?}"
    fi

    # Terminate the watchdog's verified process group, including its sleep
    # child. The installer has a separate group and is never included.
    _host_rolling_signal_process_tree TERM \
        "${host_rolling_watchdog}" || true
    if wait "${host_rolling_watchdog}"; then
        host_rolling_watchdog_status=0
    else
        host_rolling_watchdog_status="${?}"
    fi
    _host_rolling_restore_trap "${host_rolling_previous_hup}" HUP
    _host_rolling_restore_trap "${host_rolling_previous_int}" INT
    _host_rolling_restore_trap "${host_rolling_previous_term}" TERM

    if [ -d "${host_rolling_marker}" ]; then
        host_rolling_status=124
        _host_error \
            "The rolling installer timed out after ${host_rolling_timeout} seconds."
    elif [ "${host_rolling_child_status}" -ne 0 ]; then
        host_rolling_status="${host_rolling_child_status}"
    elif [ "${_HOST_ROLLING_RECEIVED_SIGNAL_STATUS}" -ne 0 ]; then
        host_rolling_status="${_HOST_ROLLING_RECEIVED_SIGNAL_STATUS}"
    fi
    rmdir -- "${host_rolling_marker}" 2>/dev/null || true
    rmdir -- "${host_rolling_marker_directory}" 2>/dev/null || true
    _HOST_ROLLING_CHILD_PID=""
    _HOST_ROLLING_RECEIVED_SIGNAL_STATUS=0
    _HOST_ROLLING_RECEIVED_SIGNAL_NAME=""
    return "${host_rolling_status}"
}

_host_rolling_cleanup_temporary() {
    local host_rolling_path="${_HOST_ROLLING_TEMPORARY_PATH:-}"

    if [ -z "${host_rolling_path}" ]; then
        return 0
    fi
    if [ -e "${host_rolling_path}" ] || [ -L "${host_rolling_path}" ]; then
        rm -f -- "${host_rolling_path}" || return $?
    fi
    _HOST_ROLLING_TEMPORARY_PATH=""
    return 0
}

_host_rolling_prepare_previous_exit_action() {
    local host_rolling_previous="${1:-}"
    local host_rolling_action=""

    if [ -z "${host_rolling_previous}" ]; then
        return 0
    fi
    host_rolling_action="${host_rolling_previous#trap -- }"
    case "${host_rolling_action}" in
        *" EXIT") host_rolling_action="${host_rolling_action% EXIT}" ;;
        *) return 0 ;;
    esac
    eval "_host_rolling_previous_exit_action() { eval ${host_rolling_action}; }" ||
        return 1
}

_host_rolling_exit_cleanup() {
    local host_rolling_status=0

    _host_rolling_cleanup_temporary || host_rolling_status="${?}"
    if declare -F _host_rolling_previous_exit_action >/dev/null; then
        _host_rolling_previous_exit_action || true
    fi
    return "${host_rolling_status}"
}

_host_run_rolling_installer_inner() {
    local host_installer_url="${1:-}"
    local host_installer_shell="${2:-}"
    local host_installer_path=""
    local host_installer_status=0
    local host_cleanup_status=0
    local host_lock_status=0
    local host_lock_release_status=0
    local host_previous_exit

    if [ -z "${host_installer_url}" ] ||
        [ -z "${host_installer_shell}" ]; then
        _host_error "A rolling installer URL and interpreter are required."
        return 64
    fi
    if [[ "${host_installer_url}" != https://* ]]; then
        _host_error "Rolling installer URLs must use HTTPS."
        return 64
    fi
    shift 2

    if [ -n "${_HOST_ROLLING_TEMPORARY_PATH:-}" ]; then
        host_cleanup_status=0
        _host_rolling_cleanup_temporary || host_cleanup_status="${?}"
        if [ "${host_cleanup_status}" -ne 0 ]; then
            _host_error "Unable to remove the previous rolling installer temporary file."
            return "${host_cleanup_status}"
        fi
        _host_rolling_restore_trap "${_HOST_ROLLING_PREVIOUS_EXIT_TRAP}" EXIT
        _HOST_ROLLING_PREVIOUS_EXIT_TRAP=""
        unset -f _host_rolling_previous_exit_action 2>/dev/null || true
    fi

    host_previous_exit=$(trap -p EXIT) || true
    _HOST_ROLLING_PREVIOUS_EXIT_TRAP="${host_previous_exit}"
    if ! _host_rolling_prepare_previous_exit_action "${host_previous_exit}"; then
        _host_error "Unable to preserve the existing exit cleanup handler."
        return 1
    fi

    _host_rolling_lock_acquire "${host_installer_url}" ||
        host_lock_status="${?}"
    if [ "${host_lock_status}" -ne 0 ]; then
        _host_error "Unable to acquire the rolling installer update lock."
        return "${host_lock_status}"
    fi

    host_installer_path=$(mktemp \
        "${TMPDIR:-/tmp}/fedora-postinstall-rolling-installer.XXXXXX") || {
        _host_rolling_lock_release || true
        return 1
    }
    _HOST_ROLLING_TEMPORARY_PATH="${host_installer_path}"
    trap '_host_rolling_exit_cleanup' EXIT

    curl \
        --disable \
        --fail \
        --location \
        --silent \
        --show-error \
        --retry 3 \
        --retry-delay 2 \
        --connect-timeout 20 \
        --max-time 300 \
        --proto '=https' \
        --tlsv1.2 \
        --output "${host_installer_path}" \
        "${host_installer_url}" ||
        host_installer_status="${?}"
    if [ "${host_installer_status}" -ne 0 ]; then
        _host_error "Unable to download the rolling installer from ${host_installer_url}."
    elif [ ! -s "${host_installer_path}" ]; then
        host_installer_status=1
        _host_error "The rolling installer downloaded from ${host_installer_url} was empty."
    fi
    if [ "${host_installer_status}" -eq 0 ]; then
        _host_rolling_execute \
            "${host_installer_shell}" "${host_installer_path}" "$@" ||
            host_installer_status="${?}"
    fi

    host_cleanup_status=0
    _host_rolling_cleanup_temporary || host_cleanup_status="${?}"
    if [ "${host_cleanup_status}" -ne 0 ]; then
        # Retry immediately so a transient removal failure does not produce a
        # false failure after the downloaded installer was actually removed.
        if _host_rolling_cleanup_temporary; then
            host_cleanup_status=0
        else
            host_cleanup_status="${?}"
        fi
    fi
    _host_rolling_lock_release ||
        host_lock_release_status="${?}"
    if [ "${host_installer_status}" -ne 0 ]; then
        _host_error "The rolling installer from ${host_installer_url} failed with status ${host_installer_status}."
    fi
    if [ "${host_cleanup_status}" -ne 0 ]; then
        _host_error "The rolling installer completed, but its temporary file could not be removed."
    fi
    if [ "${host_lock_release_status}" -ne 0 ]; then
        _host_error "The rolling installer completed, but its update lock could not be released."
    fi
    if [ "${host_cleanup_status}" -eq 0 ]; then
        _host_rolling_restore_trap "${host_previous_exit}" EXIT
        _HOST_ROLLING_PREVIOUS_EXIT_TRAP=""
        unset -f _host_rolling_previous_exit_action 2>/dev/null || true
    fi
    if [ "${host_installer_status}" -ne 0 ]; then
        return "${host_installer_status}"
    fi
    if [ "${host_cleanup_status}" -ne 0 ]; then
        return "${host_cleanup_status}"
    fi
    if [ "${host_lock_release_status}" -ne 0 ]; then
        return "${host_lock_release_status}"
    fi
    return 0
}

_host_rolling_runner_handle_signal() {
    local host_rolling_signal="${1:-TERM}"
    local host_rolling_status="${2:-143}"

    if [ "${_HOST_ROLLING_RUNNER_RECEIVED_SIGNAL_STATUS}" -eq 0 ]; then
        _HOST_ROLLING_RUNNER_RECEIVED_SIGNAL_STATUS="${host_rolling_status}"
        _HOST_ROLLING_RUNNER_RECEIVED_SIGNAL_NAME="${host_rolling_signal}"
    fi
    if [ -n "${_HOST_ROLLING_CHILD_PID}" ]; then
        _host_rolling_signal_process_tree \
            "${host_rolling_signal}" "${_HOST_ROLLING_CHILD_PID}" || true
    fi
    return 0
}

_host_run_rolling_installer() {
    local host_rolling_runner_signal_status=0
    local host_rolling_runner_status=0
    local host_rolling_previous_hup
    local host_rolling_previous_int
    local host_rolling_previous_term

    host_rolling_previous_hup=$(trap -p HUP) || true
    host_rolling_previous_int=$(trap -p INT) || true
    host_rolling_previous_term=$(trap -p TERM) || true

    _HOST_ROLLING_RUNNER_RECEIVED_SIGNAL_STATUS=0
    _HOST_ROLLING_RUNNER_RECEIVED_SIGNAL_NAME=""
    trap '_host_rolling_runner_handle_signal HUP 129' HUP
    trap '_host_rolling_runner_handle_signal INT 130' INT
    trap '_host_rolling_runner_handle_signal TERM 143' TERM

    _host_run_rolling_installer_inner "$@" ||
        host_rolling_runner_status="${?}"

    host_rolling_runner_signal_status="${_HOST_ROLLING_RUNNER_RECEIVED_SIGNAL_STATUS}"
    _host_rolling_restore_trap "${host_rolling_previous_hup}" HUP
    _host_rolling_restore_trap "${host_rolling_previous_int}" INT
    _host_rolling_restore_trap "${host_rolling_previous_term}" TERM
    _HOST_ROLLING_RUNNER_RECEIVED_SIGNAL_STATUS=0
    _HOST_ROLLING_RUNNER_RECEIVED_SIGNAL_NAME=""

    if [ "${host_rolling_runner_status}" -ne 0 ]; then
        return "${host_rolling_runner_status}"
    fi
    if [ "${host_rolling_runner_signal_status}" -ne 0 ]; then
        return "${host_rolling_runner_signal_status}"
    fi
    return 0
}

_host_export_permissions() {
    local host_permission_app="${1:-}"
    local host_permission_component
    local host_permission_directory="${HOME:-}/.host/backups/flatpak-permissions"
    local host_permission_timestamp
    local host_permission_target
    local host_permission_temporary
    local host_permission_filtered
    local host_permission_status=0

    if [ -z "${HOME:-}" ] || [[ "${HOME}" != /* ]]; then
        _host_error "HOME must be an absolute path to store Flatpak permission exports."
        return 1
    fi
    for host_permission_component in \
        "${HOME}/.host" \
        "${HOME}/.host/backups" \
        "${host_permission_directory}"; do
        if [ -L "${host_permission_component}" ]; then
            _host_error "Refusing to store Flatpak permissions through a symbolic link: ${host_permission_component}."
            return 1
        fi
    done

    install -d -m 0700 "${HOME}/.host" &&
        install -d -m 0700 "${HOME}/.host/backups" &&
        install -d -m 0700 "${host_permission_directory}" &&
        chmod 0700 "${HOME}/.host" \
        "${HOME}/.host/backups" "${host_permission_directory}"
    host_permission_status="${?}"
    if [ "${host_permission_status}" -ne 0 ]; then
        _host_error "Unable to create the private Flatpak permission backup directory."
        return "${host_permission_status}"
    fi
    for host_permission_component in \
        "${HOME}/.host" \
        "${HOME}/.host/backups" \
        "${host_permission_directory}"; do
        if [ -L "${host_permission_component}" ] ||
            [ ! -d "${host_permission_component}" ]; then
            _host_error "The private Flatpak permission backup directory is unsafe: ${host_permission_component}."
            return 1
        fi
    done
    host_permission_timestamp=$(date -u +"%Y%m%dT%H%M%SZ") || return 1
    if [ -n "${host_permission_app}" ]; then
        host_permission_target=$(mktemp --suffix=.txt \
            "${host_permission_directory}/flatpak-permissions-${host_permission_app}-${host_permission_timestamp}-XXXXXX") ||
            return 1
    else
        host_permission_target=$(mktemp --suffix=.txt \
            "${host_permission_directory}/flatpak-permissions-${host_permission_timestamp}-XXXXXX") ||
            return 1
    fi
    (
        host_permission_temporary=""
        host_permission_filtered=""
        host_permission_cleanup() {
            if [ -n "${host_permission_temporary}" ]; then
                rm -f -- "${host_permission_temporary}" 2>/dev/null || true
            fi
            if [ -n "${host_permission_filtered}" ]; then
                rm -f -- "${host_permission_filtered}" 2>/dev/null || true
            fi
            rm -f -- "${host_permission_target}" 2>/dev/null || true
        }
        trap 'host_permission_cleanup' EXIT
        host_permission_temporary=$(mktemp \
            "${host_permission_directory}/.flatpak-permissions.XXXXXX") || {
            host_permission_status="${?}"
            exit "${host_permission_status}"
        }
        host_permission_filtered="${host_permission_temporary}.filtered"
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM

        flatpak permissions >"${host_permission_temporary}" || {
            host_permission_status="${?}"
            _host_error "Unable to export the Flatpak permissions."
            exit "${host_permission_status}"
        }
        if [ -n "${host_permission_app}" ]; then
            awk -F '\t' -v app="${host_permission_app}" \
                '$3 == app { print }' "${host_permission_temporary}" \
                >"${host_permission_filtered}" || {
                host_permission_status="${?}"
                exit "${host_permission_status}"
            }
            mv -fT -- "${host_permission_filtered}" \
                "${host_permission_temporary}" || {
                host_permission_status="${?}"
                exit "${host_permission_status}"
            }
            host_permission_filtered=""
        fi
        chmod 0600 "${host_permission_temporary}" || exit $?
        mv -fT -- "${host_permission_temporary}" "${host_permission_target}" || {
            host_permission_status="${?}"
            _host_error "Unable to store the Flatpak permission export."
            exit "${host_permission_status}"
        }
        host_permission_temporary=""
        host_permission_filtered=""
        trap - EXIT HUP INT TERM
        exit 0
    )
    host_permission_status="${?}"
    if [ "${host_permission_status}" -ne 0 ]; then
        return "${host_permission_status}"
    fi
    HOST_PERMISSION_EXPORT="${host_permission_target}"
    _host_done "Flatpak permissions exported to ${host_permission_target}."
    return 0
}

_host_reset_all_permissions() {
    local host_permission_line=""
    local host_permission_remainder=""
    local host_permission_table=""
    local host_permission_id=""
    local host_permission_app=""
    local host_permission_reset_apps=""
    local host_permission_global_pairs="|"
    local host_permission_status=0

    _host_export_permissions || return $?
    _host_confirm_exact \
        "Reset every Flatpak permission-store grant? Type RESET to continue: " \
        "RESET" || return $?

    while IFS= read -r host_permission_line; do
        case "${host_permission_line}" in
            *$'\t'*$'\t'*) ;;
            *) continue ;;
        esac
        host_permission_table="${host_permission_line%%$'\t'*}"
        host_permission_remainder="${host_permission_line#*$'\t'}"
        host_permission_id="${host_permission_remainder%%$'\t'*}"
        host_permission_remainder="${host_permission_remainder#*$'\t'}"
        host_permission_app="${host_permission_remainder%%$'\t'*}"

        if [ -n "${host_permission_app}" ]; then
            case " ${host_permission_reset_apps} " in
                *" ${host_permission_app} "*) ;;
                *)
                    host_permission_reset_apps+=" ${host_permission_app}"
                    flatpak permission-reset "${host_permission_app}" || {
                        host_permission_status="${?}"
                        break
                    }
                    ;;
            esac
        elif [ -n "${host_permission_table}" ] &&
            [ -n "${host_permission_id}" ]; then
            case "${host_permission_global_pairs}" in
                *"|${host_permission_table}:${host_permission_id}|"*) ;;
                *)
                    host_permission_global_pairs+="${host_permission_table}:${host_permission_id}|"
                    flatpak permission-remove \
                        "${host_permission_table}" "${host_permission_id}" || {
                        host_permission_status="${?}"
                        break
                    }
                    ;;
            esac
        fi
    done <"${HOST_PERMISSION_EXPORT}"
    if [ "${host_permission_status}" -ne 0 ]; then
        _host_error "Unable to reset the Flatpak permissions for ${host_permission_app:-the host}. Grants processed before the failure may already be reset; the private export was retained at ${HOST_PERMISSION_EXPORT}."
        return "${host_permission_status}"
    fi
    _host_done "All Flatpak permission-store grants were reset."
}

_host_reset_application_permissions() {
    local host_permission_app="${1:-}"
    local host_permission_status=0

    if [[ ! "${host_permission_app}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        _host_error "Invalid Flatpak application identifier: ${host_permission_app}."
        return 1
    fi
    _host_export_permissions "${host_permission_app}" || return $?
    _host_confirm_exact \
        "Reset Flatpak permission-store grants for ${host_permission_app}? Type RESET to continue: " \
        "RESET" || return $?
    flatpak permission-reset "${host_permission_app}" ||
        host_permission_status="${?}"
    if [ "${host_permission_status}" -ne 0 ]; then
        _host_error "Unable to reset the Flatpak permissions for ${host_permission_app}."
        return "${host_permission_status}"
    fi
    _host_done "Flatpak permissions were reset for ${host_permission_app}."
}

_host_clean_logs() {
    local host_log_status=0

    _host_confirm_exact \
        "Vacuum system journals older than two weeks and clear the DNF package cache? Type CLEAN to continue: " \
        "CLEAN" || return $?
    sudo journalctl --vacuum-time=2weeks || host_log_status="${?}"
    if [ "${host_log_status}" -eq 0 ] && command -v dnf >/dev/null 2>&1; then
        sudo dnf clean packages || host_log_status="${?}"
    fi
    if [ "${host_log_status}" -ne 0 ]; then
        _host_error "Unable to clean the system journals and package cache."
        return "${host_log_status}"
    fi
    _host_done "System journals and the DNF package cache were cleaned."
}

_host_stop_firefox_if_running() {
    local host_firefox_status=0
    local host_killall_status=0

    if command -v pidof >/dev/null 2>&1; then
        pidof -q firefox || host_firefox_status="${?}"
    elif command -v pgrep >/dev/null 2>&1; then
        pgrep -x firefox || host_firefox_status="${?}"
    else
        _host_error "Unable to determine whether Firefox is running; cache cleanup was canceled."
        return 127
    fi
    if [ "${host_firefox_status}" -eq 0 ]; then
        _host_confirm_yes_no \
            "Firefox is running. Stop it now? Unsaved work may be lost. [y/N] " ||
            return $?
        killall firefox || {
            host_killall_status="${?}"
            _host_error "Unable to stop Firefox; cache cleanup was canceled."
            return "${host_killall_status}"
        }
    elif [ "${host_firefox_status}" -ne 1 ]; then
        _host_error "Unable to determine whether Firefox is running; cache cleanup was canceled."
        return "${host_firefox_status}"
    fi
    return 0
}

_host_serve_directory() {
    local host_server_directory="${PWD}"
    local host_server_directory_argument=""
    local host_server_bind="127.0.0.1"
    local host_server_public=0
    local host_server_status=0

    while [ "$#" -gt 0 ]; do
        case "${1}" in
            --public)
                host_server_public=1
                shift
                ;;
            *)
                if [ -n "${host_server_directory_argument}" ]; then
                    _host_error "Only one server directory may be specified."
                    return 1
                fi
                host_server_directory_argument="${1}"
                shift
                ;;
        esac
    done
    if [ -n "${host_server_directory_argument}" ]; then
        host_server_directory=$(realpath -e -- \
            "${host_server_directory_argument}") || return 1
    fi
    if [ ! -d "${host_server_directory}" ]; then
        _host_error "The server directory does not exist: ${host_server_directory}."
        return 1
    fi
    if [ "${host_server_public}" -eq 1 ]; then
        host_server_bind="0.0.0.0"
        _host_warn "The server is exposed on every network interface."
        _host_info "Host addresses: $(hostname -I 2>/dev/null || true)"
    fi
    _host_info "Serving ${host_server_directory} on ${host_server_bind}:8000."
    if command -v python3 >/dev/null 2>&1; then
        python3 -m http.server --bind "${host_server_bind}" \
            --directory "${host_server_directory}" 8000 || return $?
    elif command -v python >/dev/null 2>&1; then
        python -m http.server --bind "${host_server_bind}" \
            --directory "${host_server_directory}" 8000 || return $?
    else
        _host_error "Python is unavailable for the file server."
        return 127
    fi
}

host_command() {
    local host_action="${1:-}"
    local host_target="${2:-}"
    local host_firefox_status=0
    local host_killall_status=0
    local host_cache_status=0
    local host_flatpak_applications=""
    local host_flatpak_status=0
    local host_flatpak_cleanup_list=""
    local host_flatpak_cleanup_path=""
    local host_flatpak_cleanup_status=0
    local host_installer=""
    local host_installer_status=0
    local host_mise_activation=""
    local host_mise_status=0
    local host_server_directory_argument=""
    local host_upgrade_status=0

    if [ "$#" -lt 2 ]; then
        _host_error "Expected an action and a target."
        _host_print_usage
        return 1
    fi
    shift 2

    case "${host_action}" in
        upgrade)
            if [ "$#" -ne 0 ]; then
                _host_error "The upgrade action does not accept extra arguments."
                _host_print_usage
                return 1
            fi
            case "${host_target}" in
                system)
                    if [ "${HOME_CONFIGURATION_FLAVOR}" = "silverblue" ]; then
                        if [[ -f /run/.containerenv && -f /run/.toolboxenv ]]; then
                            sudo dnf upgrade --refresh || return $?
                            sudo dnf autoremove || return $?
                        else
                            rpm-ostree upgrade || return $?
                        fi
                    else
                        sudo dnf upgrade --refresh || return $?
                        sudo dnf autoremove || return $?
                    fi
                    ;;
                starship)
                    _host_run_rolling_installer \
                        "https://starship.rs/install.sh" \
                        sh -b "${HOME}/.local/bin" -y || return $?
                    ;;
                tex)
                    if [ -x "$(command -v tlmgr)" ]; then
                        tlmgr update --self --all --reinstall-forcibly-removed || return $?
                    elif [ "${HOME_CONFIGURATION_FLAVOR}" = "silverblue" ]; then
                        _host_warn "TeX Live is unavailable outside the Toolbox."
                    fi
                    ;;
                sdk)
                    if [ -e "${HOME_CONFIGURATION_ROOT}/scripts/sdk.sh" ]; then
                        source "${HOME_CONFIGURATION_ROOT}/scripts/sdk.sh"
                        sdk selfupdate || return $?
                        sdk upgrade || return $?
                        sdk update || return $?
                    fi
                    ;;
                vim)
                    if [ "${HOME_CONFIGURATION_FLAVOR}" = "workstation" ] &&
                        [ -x "$(command -v vim)" ]; then
                        vim -c "PlugUpgrade" -c "PlugUpdate" -c "q" -c "q" || return $?
                    fi
                    ;;
                nvim)
                    if [ "${HOME_CONFIGURATION_FLAVOR}" = "silverblue" ]; then
                        if [[ ! -f /run/.containerenv || ! -f /run/.toolboxenv ]]; then
                            _host_warn "Neovim is unavailable outside the Toolbox."
                            return 1
                        fi
                    fi
                    if [ -x "$(command -v nvim)" ]; then
                        nvim --headless "+Lazy! sync" +qa || return $?
                    fi
                    ;;
                node)
                    if [ -e "${HOME_CONFIGURATION_ROOT}/scripts/node.sh" ]; then
                        source "${HOME_CONFIGURATION_ROOT}/scripts/node.sh"
                        nvm install node || return $?
                    fi
                    ;;
                youtube)
                    if [ -x "$(command -v yt-dlp)" ]; then
                        yt-dlp -U || return $?
                    fi
                    ;;
                rust)
                    if [ -x "$(command -v rustup)" ]; then
                        rustup upgrade || return $?
                    fi
                    ;;
                deno)
                    if [ -x "$(command -v deno)" ]; then
                        deno upgrade || return $?
                    fi
                    ;;
                bun)
                    if [ -x "$(command -v bun)" ]; then
                        bun upgrade --stable || return $?
                    fi
                    ;;
                flatpak)
                    if [ "${HOME_CONFIGURATION_FLAVOR}" = "silverblue" ] &&
                        [[ -f /run/.containerenv && -f /run/.toolboxenv ]]; then
                        _host_warn "Flatpak is unavailable inside the Toolbox."
                        return 1
                    fi
                    flatpak upgrade -y || return $?
                    flatpak remove --unused -y || return $?
                    ;;
                conda)
                    if [ -e "${HOME_CONFIGURATION_ROOT}/applications/miniconda/3/bin/conda" ]; then
                        eval "$("${HOME_CONFIGURATION_ROOT}/applications/miniconda/3/bin/conda" shell.bash hook)"
                        conda upgrade --all || return $?
                    fi
                    ;;
                distrobox)
                    _host_run_rolling_installer \
                        "https://raw.githubusercontent.com/89luca89/distrobox/main/install" \
                        sh --prefix "${HOME}/.local" || return $?
                    ;;
                direnv)
                    export bin_path="${HOME}/.local/bin"
                    _host_run_rolling_installer \
                        "https://direnv.net/install.sh" bash || return $?
                    ;;
                uv)
                    if [ -x "$(command -v uv)" ]; then
                        uv self update || return $?
                    fi
                    ;;
                mise)
                    if [ -x "$(command -v mise)" ]; then
                        mise self-update --yes || return $?
                        mise upgrade --bump || return $?
                    fi
                    ;;
                brew)
                    if [ "${HOME_CONFIGURATION_FLAVOR}" = "silverblue" ]; then
                        if [ -x "$(command -v brew)" ]; then
                            brew update || return $?
                            brew upgrade || return $?
                        fi
                    fi
                    ;;
                world)
                    if [ "${HOME_CONFIGURATION_FLAVOR}" = "silverblue" ] &&
                        _host_is_toolbox; then
                        _host_info "Skipping Flatpak updates inside the Toolbox."
                    else
                        host_command upgrade flatpak || return $?
                    fi
                    host_command upgrade tex || return $?
                    host_command upgrade sdk || return $?
                    if [ "${HOME_CONFIGURATION_FLAVOR}" = "workstation" ]; then
                        host_command upgrade vim || return $?
                    fi
                    if [ "${HOME_CONFIGURATION_FLAVOR}" = "silverblue" ] &&
                        ! _host_is_toolbox; then
                        _host_info "Skipping Neovim updates outside the Toolbox."
                    else
                        host_command upgrade nvim || return $?
                    fi
                    host_command upgrade node || return $?
                    host_command upgrade youtube || return $?
                    host_command upgrade rust || return $?
                    host_command upgrade deno || return $?
                    host_command upgrade bun || return $?
                    host_command upgrade conda || return $?
                    host_command upgrade uv || return $?
                    host_command upgrade mise || return $?
                    if [ "${HOME_CONFIGURATION_FLAVOR}" = "silverblue" ]; then
                        host_command upgrade brew || return $?
                        if _host_is_toolbox; then
                            _host_info "Skipping Flatpak cleanup inside the Toolbox."
                        else
                            host_command clean flatpak || return $?
                        fi
                    else
                        host_command clean flatpak || return $?
                    fi
                    host_command clean cache || return $?
                    ;;
                *)
                    _host_error "Unknown upgrade target: ${host_target}."
                    _host_print_usage
                    return 1
                    ;;
            esac
            ;;
        clean)
            if [ "${host_target}" = "permissions" ]; then
                case "${1:-}" in
                    reset)
                        [ "$#" -eq 1 ] || {
                            _host_error "The permissions reset target does not accept extra arguments."
                            return 1
                        }
                        _host_reset_all_permissions
                        return $?
                        ;;
                    app)
                        [ "$#" -eq 2 ] || {
                            _host_error "Usage: ${HOME_CONFIGURATION_COMMAND} clean permissions app APP_ID."
                            return 1
                        }
                        _host_reset_application_permissions "${2}"
                        return $?
                        ;;
                    *)
                        _host_error "Choose 'reset' or 'app APP_ID' for Flatpak permissions."
                        _host_print_usage
                        return 1
                        ;;
                esac
            fi
            if [ "$#" -ne 0 ]; then
                _host_error "The clean action does not accept extra arguments."
                _host_print_usage
                return 1
            fi
            case "${host_target}" in
                flatpak)
                    if [ "${HOME_CONFIGURATION_FLATPAKS_RETENTION_AVAILABLE}" != "1" ]; then
                        _host_error "Flatpak cache-retention state is unavailable; application data was not changed."
                        return 1
                    fi
                    if [ "${HOME_CONFIGURATION_FLAVOR}" = "silverblue" ] &&
                        [[ -f /run/.containerenv && -f /run/.toolboxenv ]]; then
                        _host_warn "Flatpak is unavailable inside the Toolbox."
                        return 1
                    fi
                    flatpak remove --unused -y || {
                        host_flatpak_status="${?}"
                        _host_error "unable to remove unused Flatpak applications."
                        return "${host_flatpak_status}"
                    }
                    (
                        host_flatpak_cleanup_list=$(mktemp \
                            "${TMPDIR:-/tmp}/fedora-postinstall-flatpak-cleanup.XXXXXX") || {
                            _host_error "unable to enumerate Flatpak application data."
                            exit 1
                        }
                        host_flatpak_cleanup_remove() {
                            rm -f -- "${host_flatpak_cleanup_list}"
                        }
                        trap 'host_flatpak_cleanup_remove || true' EXIT
                        trap 'exit 129' HUP
                        trap 'exit 130' INT
                        trap 'exit 143' TERM

                        host_flatpak_status=0
                        if [ -d "${HOME}/.var/app" ]; then
                            find "${HOME}/.var/app" -maxdepth 1 -mindepth 1 \
                                "${HOME_CONFIGURATION_FLATPAKS_KEEP_FILTER[@]}" -type d -print0 \
                                >"${host_flatpak_cleanup_list}" ||
                                host_flatpak_status="${?}"
                        fi
                        if [ "${host_flatpak_status}" -eq 0 ] &&
                            [ -d "/run/user/$(id --user)/app" ]; then
                            find "/run/user/$(id --user)/app" -maxdepth 1 -mindepth 1 \
                                -type d -print0 >>"${host_flatpak_cleanup_list}" ||
                                host_flatpak_status="${?}"
                        fi
                        if [ "${host_flatpak_status}" -ne 0 ]; then
                            _host_error "unable to enumerate Flatpak application data."
                        else
                            while IFS= read -r -d '' host_flatpak_cleanup_path; do
                                rm -rf -- "${host_flatpak_cleanup_path}" || {
                                    host_flatpak_status="${?}"
                                    break
                                }
                            done <"${host_flatpak_cleanup_list}"
                            if [ "${host_flatpak_status}" -ne 0 ]; then
                                _host_error "unable to reset Flatpak application data."
                            fi
                        fi

                        host_flatpak_cleanup_status=0
                        host_flatpak_cleanup_remove ||
                            host_flatpak_cleanup_status="${?}"
                        if [ "${host_flatpak_cleanup_status}" -ne 0 ]; then
                            _host_error "unable to remove the temporary Flatpak cleanup list."
                        fi
                        if [ "${host_flatpak_status}" -ne 0 ]; then
                            exit "${host_flatpak_status}"
                        fi
                        if [ "${host_flatpak_cleanup_status}" -ne 0 ]; then
                            # Keep the EXIT trap armed so the temporary list
                            # receives one cleanup retry.
                            exit "${host_flatpak_cleanup_status}"
                        fi
                        trap - EXIT HUP INT TERM
                        exit 0
                    ) || return $?
                    ;;
                logs)
                    _host_clean_logs
                    return $?
                    ;;
                cache)
                    _host_stop_firefox_if_running || return $?
                    if [ "${HOME_CONFIGURATION_FLAVOR}" = "silverblue" ]; then
                        if [[ -f /run/.containerenv && -f /run/.toolboxenv ]]; then
                            _host_warn "BleachBit is unavailable inside the Toolbox."
                            return 1
                        fi
                        host_flatpak_status=0
                        host_flatpak_applications=$(flatpak list --app) ||
                            host_flatpak_status="${?}"
                        if [ "${host_flatpak_status}" -ne 0 ]; then
                            _host_error "Unable to list Flatpak applications; cache cleanup was canceled."
                            return "${host_flatpak_status}"
                        fi
                        case "${host_flatpak_applications}" in
                            *bleachbit*)
                                flatpak run org.bleachbit.BleachBit \
                                    --preset --clean system.custom || {
                                    host_cache_status="${?}"
                                    _host_error "Unable to clean cached data with BleachBit; cache cleanup was canceled."
                                    return "${host_cache_status}"
                                }
                                ;;
                        esac
                    elif command -v bleachbit >/dev/null 2>&1; then
                        bleachbit --preset --clean system.custom || {
                            host_cache_status="${?}"
                            _host_error "Unable to clean cached data with BleachBit; cache cleanup was canceled."
                            return "${host_cache_status}"
                        }
                    fi
                    gio trash --empty || {
                        host_cache_status="${?}"
                        _host_error "Unable to empty the trash; cache cleanup failed."
                        return "${host_cache_status}"
                    }
                    ;;
                system)
                    host_cache_status=0
                    host_command clean cache || host_cache_status="${?}"
                    if [ "${host_cache_status}" -ne 0 ]; then
                        _host_error "Cache cleanup failed; shutdown was canceled."
                        return "${host_cache_status}"
                    fi
                    shutdown -h now || return $?
                    ;;
                *)
                    _host_error "Unknown clean target: ${host_target}."
                    _host_print_usage
                    return 1
                    ;;
            esac
            ;;
        config)
            if [ "${host_target}" = "reset" ]; then
                [ "$#" -eq 1 ] && [ "${1:-}" = "app-grid" ] || {
                    _host_error "Usage: ${HOME_CONFIGURATION_COMMAND} config reset app-grid."
                    return 1
                }
                gsettings reset org.gnome.shell app-picker-layout || return $?
                _host_done "The GNOME application-grid layout was reset."
                return 0
            fi
            if [ "${host_target}" = "toolbox" ] &&
                [ "${HOME_CONFIGURATION_FLAVOR}" = "silverblue" ]; then
                [ "$#" -eq 0 ] || {
                    _host_error "The toolbox configuration does not accept extra arguments."
                    return 1
                }
                if [[ -f /run/.containerenv && -f /run/.toolboxenv ]]; then
                    _host_info "Packages selected for the Toolbox:"
                    if [ -r "${HOME_CONFIGURATION_ROOT}/data/toolbox/packages.txt" ]; then
                        cat "${HOME_CONFIGURATION_ROOT}/data/toolbox/packages.txt"
                    fi
                    return 0
                fi
                _host_warn "This action is available only inside a Toolbox."
                return 1
            fi
            _host_error "Unknown configuration target: ${host_target}."
            _host_print_usage
            return 1
            ;;
        use)
            if [ "${host_target}" = "server" ]; then
                _host_serve_directory "$@"
                return $?
            fi
            if [ "$#" -ne 0 ]; then
                _host_error "The use action does not accept extra arguments."
                _host_print_usage
                return 1
            fi
            case "${host_target}" in
                sdk)
                    if [ -e "${HOME_CONFIGURATION_ROOT}/scripts/sdk.sh" ]; then
                        source "${HOME_CONFIGURATION_ROOT}/scripts/sdk.sh"
                    fi
                    ;;
                conda)
                    if [ -e "${HOME_CONFIGURATION_ROOT}/applications/miniconda/3/bin/conda" ]; then
                        eval "$("${HOME_CONFIGURATION_ROOT}/applications/miniconda/3/bin/conda" shell.bash hook)"
                    fi
                    ;;
                node)
                    if [ -e "${HOME_CONFIGURATION_ROOT}/scripts/node.sh" ]; then
                        source "${HOME_CONFIGURATION_ROOT}/scripts/node.sh"
                    fi
                    ;;
                mise)
                    if [ -x "$(command -v mise)" ]; then
                        host_mise_status=0
                        host_mise_activation=$(mise activate bash) ||
                            host_mise_status="${?}"
                        if [ "${host_mise_status}" -ne 0 ]; then
                            _host_error "Unable to activate mise."
                            return "${host_mise_status}"
                        fi
                        eval "${host_mise_activation}" || return $?
                    fi
                    ;;
                *)
                    _host_error "Unknown use target: ${host_target}."
                    _host_print_usage
                    return 1
                    ;;
            esac
            ;;
        *)
            _host_error "Unknown action: ${host_action}."
            _host_print_usage
            return 1
            ;;
    esac
}

_host_prepare_output_directory() {
    local host_output_directory="${1:-}"

    if [ -z "${host_output_directory}" ]; then
        _host_error "An output directory is required."
        return 64
    fi
    mkdir -p -- "${host_output_directory}" || return $?
    host_output_directory=$(realpath -e -- "${host_output_directory}") || return 1
    if [ ! -d "${host_output_directory}" ]; then
        _host_error "The output path is not a directory: ${host_output_directory}."
        return 1
    fi
    printf '%s\n' "${host_output_directory}"
}

_host_playlist() {
    local host_playlist_directory=""

    if [ "$#" -ne 2 ]; then
        _host_error "Usage: playlist URL OUTPUT_DIRECTORY."
        return 64
    fi
    command -v yt-dlp >/dev/null 2>&1 || {
        _host_error "yt-dlp is required to create a playlist."
        return 127
    }
    host_playlist_directory=$(_host_prepare_output_directory "$2") ||
        return $?
    yt-dlp \
        --yes-playlist \
        --no-overwrites \
        --format "bv*+ba/b" \
        --merge-output-format mp4 \
        --output "${host_playlist_directory}/%(playlist_index)03d - %(title)s [%(id)s].%(ext)s" \
        "$1" || return $?
    _host_done "Playlist downloaded to ${host_playlist_directory}."
}

_host_video_downloader() {
    local host_video_directory=""
    local host_video_link=""
    local host_video_cookies="${YTDLP_COOKIES_FROM_BROWSER:-}"
    local -a host_video_options=()

    if [ "$#" -lt 2 ]; then
        _host_error "Usage: video-downloader OUTPUT_DIRECTORY URL [URL...]."
        return 64
    fi
    command -v yt-dlp >/dev/null 2>&1 || {
        _host_error "yt-dlp is required to download videos."
        return 127
    }
    host_video_directory=$(_host_prepare_output_directory "$1") || return $?
    shift
    if [ -n "${host_video_cookies}" ]; then
        host_video_options+=(--cookies-from-browser "${host_video_cookies}")
    fi
    for host_video_link in "$@"; do
        yt-dlp \
            --no-playlist \
            --no-overwrites \
            --format "bv*+ba/b" \
            --merge-output-format mp4 \
            "${host_video_options[@]}" \
            --output "${host_video_directory}/%(title)s [%(id)s].%(ext)s" \
            "${host_video_link}" || return $?
    done
    _host_done "Videos downloaded to ${host_video_directory}."
}

_host_audio_to_ogg() {
    local host_audio_source=""
    local host_audio_directory=""
    local host_audio_output=""

    if [ "$#" -ne 2 ]; then
        _host_error "Usage: audio-to-ogg SOURCE OUTPUT_DIRECTORY."
        return 64
    fi
    host_audio_source="$1"
    host_audio_directory=$(_host_prepare_output_directory "$2") || return $?
    case "${host_audio_source}" in
        http://* | https://*)
            command -v yt-dlp >/dev/null 2>&1 || {
                _host_error "yt-dlp is required to extract remote audio."
                return 127
            }
            yt-dlp \
                --extract-audio \
                --audio-format vorbis \
                --no-playlist \
                --no-overwrites \
                --output "${host_audio_directory}/%(title)s [%(id)s].%(ext)s" \
                "${host_audio_source}" || return $?
            ;;
        *)
            [ -f "${host_audio_source}" ] || {
                _host_error "The audio source does not exist: ${host_audio_source}."
                return 1
            }
            command -v ffmpeg >/dev/null 2>&1 || {
                _host_error "ffmpeg is required to convert local audio."
                return 127
            }
            host_audio_output="${host_audio_directory}/$(basename -- "${host_audio_source}")"
            host_audio_output="${host_audio_output%.*}.ogg"
            if [ -e "${host_audio_output}" ]; then
                _host_error "The output file already exists: ${host_audio_output}."
                return 1
            fi
            ffmpeg -nostdin -n -i "${host_audio_source}" -vn \
                -c:a libvorbis -b:a 64k "${host_audio_output}" || return $?
            ;;
    esac
    _host_done "Audio saved to ${host_audio_directory}."
}

playlist() {
    _host_playlist "$@"
}

video-downloader() {
    _host_video_downloader "$@"
}

audio-to-ogg() {
    _host_audio_to_ogg "$@"
}
HOME_HELPERS_ALIASES

    printf '%s() {\n    host_command "$@"\n}\n' "${home_helpers_local_command}"
}

function home_helpers_render_completion_content {
    local home_helpers_local_command="${1:-}"
    local home_helpers_local_upgrade_targets="${2:-}"

    if ! [[ "${home_helpers_local_command}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
        [[ "${home_helpers_local_upgrade_targets}" =~ [[:cntrl:]] ]]; then
        return 1
    fi

    printf 'HOME_CONFIGURATION_UPGRADE_TARGETS=%q\n' \
        "${home_helpers_local_upgrade_targets}"
    printf '_%s() {\n' "${home_helpers_local_command}"
    cat <<'HOME_HELPERS_COMPLETION'
    local cur prev action

    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    action="${COMP_WORDS[COMP_CWORD-2]}"

    case "${COMP_CWORD}" in
        1)
            COMPREPLY=($(compgen -W "upgrade clean config use" -- "${cur}"))
            ;;
        2)
            case "${prev}" in
                upgrade)
                    COMPREPLY=($(compgen -W "${HOME_CONFIGURATION_UPGRADE_TARGETS}" -- "${cur}"))
                    ;;
                clean)
                    COMPREPLY=($(compgen -W "flatpak logs cache system permissions" -- "${cur}"))
                    ;;
                config)
                    COMPREPLY=($(compgen -W "reset toolbox" -- "${cur}"))
                    ;;
                use)
                    COMPREPLY=($(compgen -W "sdk conda node server mise" -- "${cur}"))
                    ;;
            esac
            ;;
        3)
            if [ "${action}" = "clean" ] && [ "${prev}" = "permissions" ]; then
                COMPREPLY=($(compgen -W "reset app" -- "${cur}"))
            elif [ "${action}" = "config" ] && [ "${prev}" = "reset" ]; then
                COMPREPLY=($(compgen -W "app-grid" -- "${cur}"))
            fi
            ;;
        *)
            COMPREPLY=()
            ;;
    esac
}
HOME_HELPERS_COMPLETION
    printf 'complete -F _%s %s\n' \
        "${home_helpers_local_command}" "${home_helpers_local_command}"
}

function home_helpers_render_toolbox_content {
    local home_helpers_local_root="${1:-}"
    local home_helpers_local_flavor="${2:-}"
    local home_helpers_local_path="/var/run/host/opt/texbin"

    if ! home_helpers_validate_root_and_flavor \
        "${home_helpers_local_root}" "${home_helpers_local_flavor}"; then
        return 1
    fi
    if [ "${home_helpers_local_flavor}" = "silverblue" ]; then
        home_helpers_local_path="${home_helpers_local_root}/applications/texlive/current"
    fi
    cat <<'HOME_HELPERS_TOOLBOX'
#!/usr/bin/env bash

# Generated by fedora-postinstall. Manual edits are replaced on the next run.

if [[ -f /run/.containerenv && -f /run/.toolboxenv ]]; then
    pathmunge() {
        if ! echo $PATH | /bin/grep -E -q "(^|:)$1($|:)"; then
            if [ "$2" = "after" ]; then
                PATH=$PATH:$1
            else
                PATH=$1:$PATH
            fi
        fi
    }
HOME_HELPERS_TOOLBOX
    printf '    pathmunge %q after\n' "${home_helpers_local_path}"
    cat <<'HOME_HELPERS_TOOLBOX'
    unset -f pathmunge
fi
HOME_HELPERS_TOOLBOX
}

function home_helpers_validate_render_arguments {
    local home_helpers_local_root="${1:-}"
    local home_helpers_local_flavor="${2:-}"
    local home_helpers_local_command="${3:-}"
    local home_helpers_local_retention_available="${4:-1}"
    local home_helpers_local_keep_ids="${5:-}"
    local home_helpers_local_keep_id

    if ! home_helpers_validate_root_and_flavor \
        "${home_helpers_local_root}" "${home_helpers_local_flavor}"; then
        return 1
    fi
    if ! [[ "${home_helpers_local_command}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        printf 'home: invalid helper command name: %s\n' \
            "${home_helpers_local_command}" >&2
        return 1
    fi
    case "${home_helpers_local_retention_available}" in
    0 | 1) ;;
    *)
        printf 'home: invalid Flatpak retention state: %s\n' \
            "${home_helpers_local_retention_available}" >&2
        return 1
        ;;
    esac
    if [ -n "${home_helpers_local_keep_ids}" ]; then
        while IFS= read -r home_helpers_local_keep_id; do
            [ -n "${home_helpers_local_keep_id}" ] || continue
            if ! [[ "${home_helpers_local_keep_id}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*(\.[A-Za-z0-9][A-Za-z0-9_-]*)*$ ]]; then
                printf 'home: invalid Flatpak application identifier: %s\n' \
                    "${home_helpers_local_keep_id}" >&2
                return 1
            fi
        done <<<"${home_helpers_local_keep_ids}"
    fi
    return 0
}

function home_helpers_validate_render_paths {
    local home_helpers_local_root="${1:-}"
    local home_helpers_local_scripts
    local home_helpers_local_target

    home_helpers_local_scripts="${home_helpers_local_root}/scripts"
    if ! home_helpers_reject_symlink_components "${home_helpers_local_root}"; then
        return 1
    fi
    if [ ! -d "${home_helpers_local_root}" ] ||
        [ ! -d "${home_helpers_local_scripts}" ]; then
        printf 'home: the managed scripts directory is unavailable.\n' >&2
        return 1
    fi
    HOME_HELPERS_MANAGED_ROOT="${home_helpers_local_root}"
    for home_helpers_local_target in \
        "${home_helpers_local_scripts}/bash.sh" \
        "${home_helpers_local_scripts}/aliases.sh" \
        "${home_helpers_local_scripts}/completion.sh" \
        "${home_helpers_local_scripts}/toolbox.sh"; do
        if ! home_helpers_validate_file_target "${home_helpers_local_target}"; then
            return 1
        fi
    done
    return 0
}

function home_helpers_render_all {
    local home_helpers_local_root="${1:-}"
    local home_helpers_local_flavor="${2:-}"
    local home_helpers_local_command="${3:-}"
    local home_helpers_local_retention_available="${4:-1}"
    local home_helpers_local_keep_ids="${5:-}"
    local home_helpers_local_scripts
    local home_helpers_local_upgrade_targets

    if ! home_helpers_validate_render_arguments \
        "${home_helpers_local_root}" \
        "${home_helpers_local_flavor}" \
        "${home_helpers_local_command}" \
        "${home_helpers_local_retention_available}" \
        "${home_helpers_local_keep_ids}"; then
        return 1
    fi
    if ! home_helpers_validate_render_paths "${home_helpers_local_root}"; then
        return 1
    fi

    case "${home_helpers_local_flavor}" in
    workstation)
        home_helpers_local_upgrade_targets="system starship tex sdk vim nvim node youtube rust deno bun flatpak conda distrobox direnv uv mise world"
        ;;
    silverblue)
        home_helpers_local_upgrade_targets="system starship tex sdk nvim node youtube rust deno bun flatpak conda distrobox direnv uv mise brew world"
        ;;
    *)
        printf 'home: unsupported helper flavor: %s\n' \
            "${home_helpers_local_flavor}" >&2
        return 1
        ;;
    esac

    home_helpers_local_scripts="${home_helpers_local_root}/scripts"
    HOME_HELPERS_MANAGED_ROOT="${home_helpers_local_root}"
    home_helpers_write_file \
        "${home_helpers_local_scripts}/bash.sh" "0644" \
        home_helpers_render_bash_content \
        "${home_helpers_local_root}" "${home_helpers_local_flavor}" || return 1
    home_helpers_write_file \
        "${home_helpers_local_scripts}/aliases.sh" "0644" \
        home_helpers_render_aliases_content \
        "${home_helpers_local_root}" \
        "${home_helpers_local_flavor}" \
        "${home_helpers_local_command}" \
        "${home_helpers_local_retention_available}" \
        "${home_helpers_local_keep_ids}" || return 1
    home_helpers_write_file \
        "${home_helpers_local_scripts}/completion.sh" "0644" \
        home_helpers_render_completion_content \
        "${home_helpers_local_command}" \
        "${home_helpers_local_upgrade_targets}" || return 1
    home_helpers_write_file \
        "${home_helpers_local_scripts}/toolbox.sh" "0644" \
        home_helpers_render_toolbox_content \
        "${home_helpers_local_root}" "${home_helpers_local_flavor}" || return 1
    return 0
}
