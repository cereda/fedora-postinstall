#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "FlatPark installation and configuration"

ui_description "Configure the FlatPark Flatpak source."

if ui_confirm "Install and configure FlatPark?" "Install" "Skip"; then

    # registers the signed FlatPark repository (per user, no admin needed)
    ui_step "Adding FlatPark as a Flatpak source."
    flatpak --user remote-add --if-not-exists flatpark https://dl.flatpark.org/flatpark.flatpakrepo
else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "FlatPark was not configured."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
