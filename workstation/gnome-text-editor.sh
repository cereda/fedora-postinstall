#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "GNOME text editor"

description "Configure the GNOME Text Editor."
echo

if question "Do you want to configure the GNOME text editor?"; then

    info "Highlighting current line."
    gsettings set org.gnome.TextEditor highlight-current-line true

    info "Disabling restore session."
    gsettings set org.gnome.TextEditor restore-session false

    info "Showing grid."
    gsettings set org.gnome.TextEditor show-grid true

    info "Showing line numbers."
    gsettings set org.gnome.TextEditor show-line-numbers true

    info "Showing right margin."
    gsettings set org.gnome.TextEditor show-right-margin true

    info "Disabling spellcheck."
    gsettings set org.gnome.TextEditor spellcheck false
fi
