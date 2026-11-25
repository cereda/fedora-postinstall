#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "GNOME Text Editor configuration"

ui_description "Apply a focused set of GNOME Text Editor preferences."

if ui_confirm "Configure GNOME Text Editor?" "Configure" "Skip"; then

    ui_step "Applying GNOME Text Editor preferences."
    gsettings set org.gnome.TextEditor highlight-current-line true
    gsettings set org.gnome.TextEditor restore-session false
    gsettings set org.gnome.TextEditor show-grid true
    gsettings set org.gnome.TextEditor show-line-numbers true
    gsettings set org.gnome.TextEditor show-right-margin true
    gsettings set org.gnome.TextEditor spellcheck false

    ui_success "GNOME Text Editor preferences updated."
else
    ui_skip "GNOME Text Editor was not configured."
fi
