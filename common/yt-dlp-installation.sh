#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "yt-dlp installation and configuration"

description "Install and configure yt-dlp."
echo

if question "Do you want to install and configure yt-dlp?"; then

    info "Downloading the latest version of yt-dlp from GitHub."
    wget -q https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp

    info "Moving script to the local directory."
    mv yt-dlp "${HOME}/.local/bin"

    info "Changing permissions to make it executable."
    chmod +x "${HOME}/.local/bin/yt-dlp"
fi
