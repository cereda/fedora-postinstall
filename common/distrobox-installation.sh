#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Distrobox installation and configuration"

description "Run Linux distributions in isolated containers."
echo

warning "Consider installing BoxBuddy, a graphical user interface for \
Distrobox. This application makes creating and using containers simple \
and convenient by providing a simple UI for many common tasks."

echo

if question "Do you want to install and configure Distrobox?"; then

    # Install under the user prefix without changing the shell profile.
    info "Installing and configuring Distrobox from GitHub."
    curl -s https://raw.githubusercontent.com/89luca89/distrobox/main/install | sh -s -- --prefix ~/.local
fi
