#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "GNOME Nautilus"

ui_description "Configure Nautilus folder views and thumbnails."

if ui_confirm "Configure Nautilus folder views and thumbnails?" "Apply" "Keep"; then

    ui_step "Configuring Nautilus folder views and thumbnails."
    gsettings set org.gnome.nautilus.preferences default-folder-viewer icon-view
    gsettings set org.gnome.nautilus.preferences show-image-thumbnails never
else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "Nautilus was left unchanged."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
