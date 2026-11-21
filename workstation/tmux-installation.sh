#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "tmux installation and configuration"

description "Install and configure tmux."
echo

if question "Do you want to install and configure tmux?"; then

    info "Installing tmux as an RPM package."
    sudo dnf install tmux -y

    info "Creating the configuration directories for tmux."
    mkdir -p "${HOME}/.config/tmux/plugins"

    info "Downloading the tmux plugin manager (TPM)."
    git clone https://github.com/tmux-plugins/tpm "${HOME}/.config/tmux/plugins/tpm"

    info "Creating the configuration file."
    cat >"${HOME}/.config/tmux/tmux.conf" <<'TMUX'
# default plugins to make tpm work
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-sensible'

# my personal configuration
set -g @plugin 'jaclu/tmux-menus'
set -g @plugin 'wfxr/tmux-power'
set -g @tmux_power_theme 'moon'

# initialize the plugin manager
run '~/.config/tmux/plugins/tpm/tpm'
TMUX

fi
