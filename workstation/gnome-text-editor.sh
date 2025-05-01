#!/usr/bin/env bash

section "GNOME text editor"

description "This section applies a set of tweaks to the GNOME text editor, \
including highlighting the current line, disabling session restoration, \
showing the grid, line numbers, and right margin, as well as disabling \
spellcheck, to customize the text editing experience."

echo

question "Do you want to configure the GNOME text editor?"

if [ $? = 0 ]; then

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
