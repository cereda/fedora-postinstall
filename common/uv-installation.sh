#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "uv installation and configuration"

description "Install uv for Python project management."
echo

if question "Do you want to install uv?"; then

    # Prevent uv from modifying the shell profile.
    info "Installing uv."
    export UV_NO_MODIFY_PATH=1 && curl -LsSf https://astral.sh/uv/install.sh | sh
fi
