#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "direnv installation and configuration"

description "Load project-specific environment variables by directory."
echo

if question "Do you want to install and configure direnv?"; then

    # Keep the installer from modifying the shell profile.
    info "Installing and configuring direnv."
    export bin_path="${HOME}/.local/bin" && curl -sfL https://direnv.net/install.sh | bash
fi
