#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "GNOME Software"

ui_description "Disable automatic GNOME Software update downloads and notifications."

if ui_confirm "Disable automatic GNOME Software update downloads and notifications?" "Disable" "Keep"; then

    ui_step "Disabling automatic GNOME Software update downloads and notifications."
    gsettings set org.gnome.software download-updates false
    gsettings set org.gnome.software download-updates-notify false
else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "GNOME Software update downloads and notifications were left unchanged."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
