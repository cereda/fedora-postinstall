#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "GNOME clock"

description "Show the weekday in the GNOME clock."
echo

if question "Do you want to configure the GNOME clock?"; then

    info "Showing weekday."
    gsettings set org.gnome.desktop.interface clock-show-weekday true
fi
