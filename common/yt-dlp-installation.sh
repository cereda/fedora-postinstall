#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "yt-dlp installation and configuration"

ui_description "Install yt-dlp for command-line media downloads."

if ui_confirm "Install yt-dlp?" "Install" "Skip"; then

    ui_step "Downloading the latest yt-dlp release from GitHub."
    wget -q https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp

    ui_step "Installing yt-dlp in the local command directory."
    mv yt-dlp "${HOME}/.local/bin"
    chmod +x "${HOME}/.local/bin/yt-dlp"
else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "yt-dlp was not installed."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
