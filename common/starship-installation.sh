#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Starship installation and configuration"

ui_description "Install and configure the Starship prompt."

if ui_confirm "Install and configure Starship?" "Install" "Skip"; then

    ui_step "Installing Starship."
    mkdir -p "${HOME}/.local/bin"

    # Install into ~/.local/bin and replace an existing binary.
    runtime_capture_output INSTALLER_SCRIPT curl -fsSL https://starship.rs/install.sh || return $?
    sh -c "${INSTALLER_SCRIPT}" -- -b "${HOME}/.local/bin" -y

    ui_step "Configuring Starship."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/config/starship"
    cat >"${ROOT_DIRECTORY_STRUCTURE}/config/starship/starship.toml" <<'TOML'
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

else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "Starship was not installed."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
