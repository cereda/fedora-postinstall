#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Nix installation"

ui_description "Install Nix on Fedora Silverblue."

if ui_confirm "Install Nix on Fedora Silverblue?" "Install" "Skip"; then

    ui_step "Installing Nix with the OSTree planner."
    curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install ostree --no-confirm --persistence=/var/lib/nix

    ui_success "Nix installed."
else
    ui_skip "Nix was not installed."
fi
