#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "GNOME font rendering"

description "Configure GNOME font rendering."
echo

if question "Do you want to improve font rendering?"; then

    info "Applying font antialiasing."
    gsettings set org.gnome.desktop.interface font-antialiasing rgba

    info "Applying font hinting."
    gsettings set org.gnome.desktop.interface font-hinting slight
fi
