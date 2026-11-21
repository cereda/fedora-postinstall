#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Terra installation"

description "Configure the Terra RPM repository."
echo

if question "Do you want to install the Terra repository?"; then

    info "Configuring the repository."
    sudo dnf install --nogpgcheck --repofrompath "terra,https://repos.fyralabs.com/terra${FEDORA_VERSION}" terra-release
fi
