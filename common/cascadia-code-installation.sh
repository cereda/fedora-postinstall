#!/usr/bin/env bash

# MIT License
# 
# Copyright (c) 2025, Paulo Cereda
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

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
