#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "GNOME Display Manager"

description "Remove the Fedora logo from GDM."
echo

if question "Do you want to remove the Fedora logo from GDM?"; then

    info "Removing Fedora logo from GDM."
    sudo -u gdm gsettings set org.gnome.login-screen logo ''
fi
