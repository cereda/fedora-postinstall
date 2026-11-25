#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "GNOME font rendering"

ui_description "Configure GNOME font rendering."

if ui_confirm "Enable improved font rendering?" "Enable" "Keep"; then

    ui_step "Applying font antialiasing and hinting."
    gsettings set org.gnome.desktop.interface font-antialiasing rgba
    gsettings set org.gnome.desktop.interface font-hinting slight
else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "GNOME font rendering was left unchanged."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
