#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "tmux installation and configuration"

ui_description "Install tmux, TPM, and a managed configuration."

if ui_confirm "Install and configure tmux?" "Install" "Skip"; then

    ui_step "Installing tmux."
    sudo dnf install tmux -y

    ui_step "Installing TPM and writing the tmux configuration."
    mkdir -p "${HOME}/.config/tmux/plugins"
    git clone https://github.com/tmux-plugins/tpm "${HOME}/.config/tmux/plugins/tpm"

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

    ui_success "tmux and its configuration are ready."
else
    ui_skip "tmux was not installed."
fi
