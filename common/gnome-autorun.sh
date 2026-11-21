#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Autorun settings for removable media"

description "Disable removable-media autorun in GNOME."
echo

if question "Do you want to disable autorun for removable media?"; then

    info "Disabling autorun for removable media."
    gsettings set org.gnome.desktop.media-handling autorun-never true
fi
