#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "GNOME technical reports"

ui_description "Disable GNOME technical reports."

if ui_confirm "Disable GNOME technical reports?" "Disable" "Keep"; then

    ui_step "Disabling GNOME technical problem reporting."
    gsettings set org.gnome.desktop.privacy report-technical-problems false
else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "GNOME technical reports were left unchanged."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
