#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Cascadia Code font installation"

description "Cascadia Code is a monospaced font designed for programming, \
featuring clear letterforms, ligatures, and support for a wide range of \
programming languages and symbols."

echo

question "Do you want to install Cascadia Code?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    # Note: GitHub may apply rate limits to the API endpoint, which could
    # cause this section to fail (been there, done that)

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
