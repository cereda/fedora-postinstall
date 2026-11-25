#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "GNOME clock"

ui_description "Show the weekday in the GNOME clock."

if ui_confirm "Show the weekday in the GNOME clock?" "Enable" "Keep"; then

    ui_step "Showing the weekday in the GNOME clock."
    gsettings set org.gnome.desktop.interface clock-show-weekday true
else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "The GNOME clock was left unchanged."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
