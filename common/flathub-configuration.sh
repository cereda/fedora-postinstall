#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Flathub installation and configuration"

description "Configure Flathub as a Flatpak source."
echo

if question "Do you want to install and configure Flathub?"; then

    # Flathub must be added as a remote and then explicitly enabled.

    info "Installing and configuring Flathub."
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

    info "Enabling Flathub."
    flatpak remote-modify --enable flathub
fi
