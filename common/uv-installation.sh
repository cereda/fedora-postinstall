#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "uv installation and configuration"

ui_description "Install uv for Python project management."

if ui_confirm "Install uv?" "Install" "Skip"; then

    # Prevent uv from modifying the shell profile.
    ui_step "Installing uv."
    export UV_NO_MODIFY_PATH=1 && curl -LsSf https://astral.sh/uv/install.sh | sh
else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "uv was not installed."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
