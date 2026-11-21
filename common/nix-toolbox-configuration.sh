#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Nix Toolbox configuration"

description "Configure Nix inside a Fedora toolbox."
echo

if question "Do you want to install and configure Nix Toolbox?"; then

    NIX_TOOLBOX_NAME=$(prompt_valid_container_name "Your Nix Toolbox container name: " "nix-toolbox-${FEDORA_VERSION}")

    info "Creating and configuring Nix Toolbox."
    toolbox create --image "ghcr.io/thrix/nix-toolbox:${FEDORA_VERSION}" "${NIX_TOOLBOX_NAME}"
fi
