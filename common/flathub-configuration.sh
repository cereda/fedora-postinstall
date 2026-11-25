#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Flathub installation and configuration"

ui_description "Configure Flathub as a Flatpak source."

if ui_confirm "Install and configure Flathub?" "Install" "Skip"; then

    # Flathub must be added as a remote and then explicitly enabled.

    ui_step "Adding Flathub as a Flatpak source."
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

    ui_step "Enabling Flathub."
    flatpak remote-modify --enable flathub
else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "Flathub was not configured."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
