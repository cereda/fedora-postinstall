#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Flathub installation and configuration"

description "Flathub is a centralized app store for Linux distributions \
that use the Flatpak packaging format, providing a convenient way for \
users to discover and install applications."

echo

question "Do you want to install and configure Flathub?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    # the Flathub installation requires two steps: adding the repository as
    # a remote reference and explicitly enabling it (as described in the
    # documentation)

    info "Installing and configuring Flathub."
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

    info "Enabling Flathub."
    flatpak remote-modify --enable flathub
fi
