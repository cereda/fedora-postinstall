#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "GNOME Display Manager"

ui_description "Remove the Fedora logo from GDM."

if ui_confirm "Remove the Fedora logo from GDM?" "Remove" "Keep"; then

    ui_step "Removing the Fedora logo from GDM."
    sudo -u gdm gsettings set org.gnome.login-screen logo ''
else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "The Fedora logo setting was left unchanged."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
