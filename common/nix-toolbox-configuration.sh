#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Nix Toolbox configuration"

ui_description "Configure Nix inside a Fedora toolbox."

if ui_confirm "Install and configure Nix Toolbox?" "Install" "Skip"; then

    if NIX_TOOLBOX_NAME=$(prompt_valid_container_name "Your Nix Toolbox container name: " "nix-toolbox-${FEDORA_VERSION}"); then
        NIX_TOOLBOX_NAME_STATUS=0
    else
        NIX_TOOLBOX_NAME_STATUS="${?}"
    fi
    if [ "${NIX_TOOLBOX_NAME_STATUS}" -ne 0 ]; then
        return "${NIX_TOOLBOX_NAME_STATUS}"
    fi

    ui_step "Creating and configuring Nix Toolbox."
    toolbox create --image "ghcr.io/thrix/nix-toolbox:${FEDORA_VERSION}" "${NIX_TOOLBOX_NAME}"
else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "Nix Toolbox was not created."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
