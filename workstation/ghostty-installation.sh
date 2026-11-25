#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Ghostty installation"

ui_description "Install the Ghostty terminal emulator from its COPR repository."

if ui_confirm "Install Ghostty?" "Install" "Skip"; then

    ui_step "Enabling the Ghostty COPR and installing Ghostty."
    sudo dnf copr enable scottames/ghostty
    sudo dnf install ghostty

    ui_success "Ghostty installed."
else
    ui_skip "Ghostty was not installed."
fi
