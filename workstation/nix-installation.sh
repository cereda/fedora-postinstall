#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Nix installation"

ui_description "Install Nix on Fedora Workstation."

if ui_confirm "Install Nix on Fedora Workstation?" "Install" "Skip"; then

    ui_step "Installing Nix with the Linux planner."
    curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install linux --no-confirm

    ui_success "Nix installed."
else
    ui_skip "Nix was not installed."
fi
