#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Starship installation and configuration"

ui_description "Install and configure the Starship prompt."

ROLLING_INSTALL_DIRECTORY="${SCRIPT_PATH}/common"
source "${ROLLING_INSTALL_DIRECTORY}/rolling-install.sh" || return 1

if ui_confirm "Install and configure Starship?" "Install" "Skip"; then

    ui_step "Installing Starship."
    mkdir -p "${HOME}/.local/bin" || return $?

    # Install into ~/.local/bin and replace an existing binary.
    rolling_installer_run \
        "https://starship.rs/install.sh" \
        sh -b "${HOME}/.local/bin" -y || return $?
    ui_success "Starship was installed."

    ui_step "Configuring Starship."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/config/starship" || return $?
    (
        STARSHIP_CONFIG_TEMPORARY=$(mktemp \
            "${ROOT_DIRECTORY_STRUCTURE}/config/starship/starship.toml.tmp.XXXXXX") || exit 1
        trap 'rm -f -- "${STARSHIP_CONFIG_TEMPORARY}" 2>/dev/null || true' EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM

        cat >"${STARSHIP_CONFIG_TEMPORARY}" <<'TOML' || exit $?
[character]
success_symbol = "[➜](bold green)"
error_symbol = "[➜](bold red)"

[username]
show_always = true
format = "[$user]($style) at "
style_root = "bold red"
style_user = "bold yellow"

[hostname]
ssh_only = false
style = "bold blue"

[java]
style = "bold green"

# [status]
# disabled = false
# symbol = "🔴"
# symbol = "🟥"
# format = "[$symbol $status]($style) "
#
# [time]
# disabled = false
#
# [[battery.display]]
# threshold = 100
# style = "bold red"
#
# [custom.git_server]
# description = "Display symbol for the remote Git hosting provider"
# when = "git rev-parse --is-inside-work-tree >/dev/null 2>&1"
# shell = ["sh"]
# command = '''
# remote=$(git remote get-url origin 2>/dev/null) || remote=
# case "$remote" in
#     *github.com:*|*github.com/*|*github.com) printf "\\uF113 GitHub " ;;
#     *gitlab.com:*|*gitlab.com/*|*gitlab.com) printf "\\uF296 GitLab " ;;
#     *) printf "\\uE702 Git " ;;
# esac
# '''
# style = "bright-blue bold"
TOML
        chmod 0644 "${STARSHIP_CONFIG_TEMPORARY}" || exit $?
        mv -f -- "${STARSHIP_CONFIG_TEMPORARY}" \
            "${ROOT_DIRECTORY_STRUCTURE}/config/starship/starship.toml" || exit $?
        trap - EXIT HUP INT TERM
        exit 0
    ) || return $?
    ui_success "Starship was configured."

else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "Starship was not installed."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
