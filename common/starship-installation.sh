#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "starship installation and configuration"

description "Install and configure the Starship prompt."
echo

if question "Do you want to install starship?"; then

    info "Preparing the installation directory."
    mkdir -p "${HOME}/.local/bin"

    # Install into ~/.local/bin and replace an existing binary.
    info "Installing starship."
    runtime_capture_output INSTALLER_SCRIPT curl -fsSL https://starship.rs/install.sh || return 1
    sh -c "${INSTALLER_SCRIPT}" -- -b "${HOME}/.local/bin" -y

    info "Preparing the configuration directory."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/config/starship"

    info "Creating the configuration file for starship."
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

fi
