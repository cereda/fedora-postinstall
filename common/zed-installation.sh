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

section "Zed installation and configuration"

description "Zed is an open-source, cross-platform code editor \
that aims to provide a modern, efficient, and customizable text \
editing experience. It is designed to be fast, lightweight, \
and highly extensible, allowing developers to tailor the \
editor to their specific needs and workflows."

echo

question "Do you want to install and configure Zed?"

    info "Getting the latest version of Zed from GitHub."
    test -f zed-editor.json || wget -q -O zed-editor.json https://api.github.com/repos/zed-industries/zed/releases/latest

    info "Downloading Zed from GitHub."
    wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux") and (contains("remote")|not)).browser_download_url' zed-editor.json)

    info "Extracting Zed into the current directory."
    tar xzf zed-linux-x86_64.tar.gz

    info "Moving Zed to the local applications directory."
    mv zed.app "${ROOT_DIRECTORY_STRUCTURE}/applications/"

    info "Creating configuration file for Zed."
    mkdir -p "${HOME}/.config/zed"
    tee "${HOME}/.config/zed/settings.json" <<EOF
{
  "telemetry": {
    "metrics": false,
    "diagnostics": false
  },
  "ui_font_size": 16,
  "buffer_font_size": 17,
  "theme": {
    "mode": "system",
    "light": "One Light",
    "dark": "One Dark"
  },
  "autosave": "off",
  "restore_on_startup": "none",
  "buffer_font_family": "Cascadia Code",
  "buffer_font_features": {
    "calt": true
  },
  "confirm_quit": false,
  "indent_guides": {
    "enabled": true
  },
  "show_whitespaces": "selection",
  "soft_wrap": "none"
}
EOF

    info "Creating a desktop shortcut for Zed."
    mkdir -p "${HOME}/.local/share/applications"
    tee "${HOME}/.local/share/applications/zed.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Zed
GenericName=Text Editor
Comment=A high-performance, multiplayer code editor.
TryExec=${ROOT_DIRECTORY_STRUCTURE}/applications/zed.app/bin/zed
StartupNotify=true
Exec=${ROOT_DIRECTORY_STRUCTURE}/applications/zed.app/bin/zed %U
Icon=${ROOT_DIRECTORY_STRUCTURE}/applications/zed.app/share/icons/hicolor/512x512/apps/zed.png
Categories=Utility;TextEditor;Development;IDE;
Keywords=zed;
MimeType=text/plain;application/x-zerosize;x-scheme-handler/zed;
Actions=NewWorkspace;

[Desktop Action NewWorkspace]
Exec=${ROOT_DIRECTORY_STRUCTURE}/applications/zed.app/bin/zed --new %U
Name=Open a new workspace
EOF

fi
