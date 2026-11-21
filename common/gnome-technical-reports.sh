#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "GNOME technical reports"

description "Disable GNOME technical reports."
echo

if question "Do you want to disable technical reports?"; then

    info "Disabling technical problem reporting."
    gsettings set org.gnome.desktop.privacy report-technical-problems false
fi
