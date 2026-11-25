#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "direnv installation and configuration"

ui_description "Load project-specific environment variables by directory."

if ui_confirm "Install and configure direnv?" "Install" "Skip"; then

    # Keep the installer from modifying the shell profile.
    ui_step "Installing and configuring direnv."
    export bin_path="${HOME}/.local/bin" && curl -sfL https://direnv.net/install.sh | bash
else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "direnv was not installed."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
