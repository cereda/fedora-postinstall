#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Nix installation and configuration"

description "Install Nix on Fedora Workstation."
echo

if question "Do you want to install and configure Nix?"; then

    info "Installing Nix using the Linux planner."
    curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install linux --no-confirm
fi
