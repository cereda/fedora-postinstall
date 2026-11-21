#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "yazi installation"

description "Install and configure the Yazi file manager."
echo

warning "yazi is also available as a standalone binary in the additional \
command line tools section. If you want a minimal footprint (no optional \
dependencies), reply "No" to this prompt and install yazi later."

echo

if question "Do you want to install yazi?"; then

    info "Enabling the yazi COPR."
    sudo dnf copr enable lihaohong/yazi

    info "Installing yazi as an RPM package."
    sudo dnf install yazi

fi
