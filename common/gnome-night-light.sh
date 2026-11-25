#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "GNOME night light"

ui_description "Enable the GNOME night light."

if ui_confirm "Enable the GNOME night light?" "Enable" "Keep"; then

    ui_step "Enabling the GNOME night light."
    gsettings set org.gnome.settings-daemon.plugins.color night-light-enabled true
else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "The GNOME night light was left unchanged."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
