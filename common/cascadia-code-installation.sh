#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Cascadia Code font installation"

ui_description "Install the Cascadia Code programming font."

if ui_confirm "Install Cascadia Code?" "Install" "Skip"; then

    ui_step "Resolving the latest Cascadia Code release."
    test -f cascadia-code.json || wget -q -O cascadia-code.json https://api.github.com/repos/microsoft/cascadia-code/releases/latest

    ui_step "Downloading Cascadia Code."
    wget -q -O cascadia-code.zip "$(jq -r '.assets[] | select(.name | endswith("zip")).browser_download_url' cascadia-code.json)"

    ui_step "Extracting Cascadia Code."
    unzip -j cascadia-code.zip *.ttf -d "Cascadia Code"

    ui_step "Installing Cascadia Code."
    mkdir -p "${HOME}/.local/share/fonts"
    mv "Cascadia Code" "${HOME}/.local/share/fonts/"

    ui_step "Generating the Cascadia Code font cache."
    fc-cache -fv "${HOME}/.local/share/fonts"
    fc-cache -fv "${HOME}/.local/share/fonts"
else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "Cascadia Code was not installed."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
