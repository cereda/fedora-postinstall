#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "GNOME Software"

description "Disable GNOME Software update notifications."
echo

if question "Do you want to disable notifications from GNOME Software?"; then

    info "Disabling download updates."
    gsettings set org.gnome.software download-updates false

    info "Disabling notify updates."
    gsettings set org.gnome.software download-updates-notify false
fi
