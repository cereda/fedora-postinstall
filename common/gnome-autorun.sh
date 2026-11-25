#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Autorun settings for removable media"

ui_description "Disable removable-media autorun in GNOME."

if ui_confirm "Disable autorun for removable media?" "Disable" "Keep"; then

    ui_step "Disabling autorun for removable media."
    gsettings set org.gnome.desktop.media-handling autorun-never true
else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "Removable-media autorun was left unchanged."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
