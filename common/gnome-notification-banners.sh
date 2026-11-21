#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "GNOME notification banners"

description "Disable GNOME notification banners."
echo

if question "Do you want to disable notification banners?"; then

    info "Disabling notification banners."
    gsettings set org.gnome.desktop.notifications show-banners false

    info "Disabling notifications in lock screen."
    gsettings set org.gnome.desktop.notifications show-in-lock-screen false
fi
