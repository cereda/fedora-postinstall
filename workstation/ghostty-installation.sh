#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Ghostty installation"

description "Ghostty is a fast, feature-rich, and cross-platform terminal \
emulator that uses platform-native UI and GPU acceleration."

echo

question "Do you want to install Ghostty?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    info "Enabling the Ghostty COPR."
    sudo dnf copr enable scottames/ghostty

    info "Installing Ghostty as an RPM package."
    sudo dnf install ghostty

fi
