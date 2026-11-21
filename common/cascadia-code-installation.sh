#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Cascadia Code font installation"

description "Install the Cascadia Code programming font."
echo

if question "Do you want to install Cascadia Code?"; then

    info "Getting the latest version of Cascadia Code from GitHub."
    test -f cascadia-code.json || wget -q -O cascadia-code.json https://api.github.com/repos/microsoft/cascadia-code/releases/latest

    info "Downloading Cascadia Code from GitHub."
    wget -q -O cascadia-code.zip $(jq -r '.assets[] | select(.name | endswith("zip")).browser_download_url' cascadia-code.json)

    info "Extracting file."
    unzip -j cascadia-code.zip *.ttf -d "Cascadia Code"

    info "Creating local font directory."
    mkdir -p "${HOME}/.local/share/fonts"

    info "Moving font to the proper directory."
    mv "Cascadia Code" "${HOME}/.local/share/fonts/"

    info "Generating font cache."
    fc-cache -fv "${HOME}/.local/share/fonts"

    info "Regenerating font cache."
    fc-cache -fv "${HOME}/.local/share/fonts"
fi
