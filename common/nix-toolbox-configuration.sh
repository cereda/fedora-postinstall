#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Nix Toolbox configuration"

description "Nix Toolbox is a project that enhances the Fedora Toolbox \
container image by integrating the Nix package manager and optionally \
Home Manager. It supports Nix-based development environments and allows \
users to manage their home environment as code."

echo

question "Do you want to install and configure Nix Toolbox?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    # ask user input for the toolbox container name
    NIX_TOOLBOX_NAME=$(prompt_valid_container_name "Your Nix Toolbox container name: " "nix-toolbox-${FEDORA_VERSION}")

    info "Creating and configuring Nix Toolbox."
    toolbox create --image "ghcr.io/thrix/nix-toolbox:${FEDORA_VERSION}" "${NIX_TOOLBOX_NAME}"
fi
