#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "GNOME night light"

description "Enable the GNOME night light."
echo

if question "Do you want to enable night light?"; then

    info "Enabling night light."
    gsettings set org.gnome.settings-daemon.plugins.color night-light-enabled true
fi
