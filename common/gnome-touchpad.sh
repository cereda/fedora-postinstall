#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "GNOME touchpad configuration"

ui_description "Configure the GNOME touchpad."

if ui_confirm "Configure the GNOME touchpad?" "Enable" "Keep"; then

    ui_step "Enabling tap-to-click and two-finger scrolling."
    gsettings set org.gnome.desktop.peripherals.touchpad tap-to-click true
    gsettings set org.gnome.desktop.peripherals.touchpad two-finger-scrolling-enabled true
else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "The GNOME touchpad was left unchanged."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
