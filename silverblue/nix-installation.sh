#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Nix installation and configuration"

description "Install Nix on Fedora Silverblue."
echo

if question "Do you want to install and configure Nix?"; then

    info "Installing Nix using the OSTree planner."
    curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install ostree --no-confirm --persistence=/var/lib/nix
fi
