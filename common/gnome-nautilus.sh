#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "GNOME Nautilus"

description "Configure Nautilus folder views and thumbnails."
echo

if question "Do you want to configure Nautilus?"; then

    info "Setting default folder viewer."
    gsettings set org.gnome.nautilus.preferences default-folder-viewer icon-view

    info "Disabling image thumbnails."
    gsettings set org.gnome.nautilus.preferences show-image-thumbnails never
fi
