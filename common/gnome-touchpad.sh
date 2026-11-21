#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "GNOME touchpad configuration"

description "Configure the GNOME touchpad."
echo

if question "Do you want to configure your laptop touchpad?"; then

    info "Enabling tap to click."
    gsettings set org.gnome.desktop.peripherals.touchpad tap-to-click true

    info "Enabling two finger scrolling."
    gsettings set org.gnome.desktop.peripherals.touchpad two-finger-scrolling-enabled true
fi
