#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Yazi installation"

ui_description "Install Yazi and its optional dependencies from its COPR repository."
ui_warning "Yazi is also available as a standalone command-line tool. Choose Skip to keep the installation lightweight."

if ui_confirm "Install Yazi from its COPR repository?" "Install" "Skip"; then

    ui_step "Enabling the Yazi COPR and installing Yazi."
    sudo dnf copr enable lihaohong/yazi
    sudo dnf install yazi

    ui_success "Yazi installed."
else
    ui_skip "Yazi was not installed."
fi
