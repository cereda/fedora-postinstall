#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "GNOME notification banners"

ui_description "Disable GNOME notification banners."

if ui_confirm "Disable GNOME notification banners?" "Disable" "Keep"; then

    ui_step "Disabling notification banners and lock-screen notifications."
    gsettings set org.gnome.desktop.notifications show-banners false
    gsettings set org.gnome.desktop.notifications show-in-lock-screen false
else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "GNOME notification banners were left unchanged."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
