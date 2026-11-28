#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Distrobox installation and configuration"

ui_description "Run Linux distributions in isolated containers."
ui_warning "BoxBuddy provides a separate graphical interface for Distrobox. Consider installing it when you prefer a desktop workflow."

ROLLING_INSTALL_DIRECTORY="${SCRIPT_PATH}/common"
source "${ROLLING_INSTALL_DIRECTORY}/rolling-install.sh" || return 1

if ui_confirm "Install and configure Distrobox?" "Install" "Skip"; then

    # Install under the user prefix without changing the shell profile.
    ui_step "Installing and configuring Distrobox from GitHub."
    rolling_installer_run \
        "https://raw.githubusercontent.com/89luca89/distrobox/main/install" \
        sh --prefix "${HOME}/.local" || return $?
    ui_success "Distrobox was installed."
else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "Distrobox was not installed."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
