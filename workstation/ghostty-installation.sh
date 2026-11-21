#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Ghostty installation"

description "Install the Ghostty terminal emulator."
echo

if question "Do you want to install Ghostty?"; then

    info "Enabling the Ghostty COPR."
    sudo dnf copr enable scottames/ghostty

    info "Installing Ghostty as an RPM package."
    sudo dnf install ghostty

fi
