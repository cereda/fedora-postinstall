#!/usr/bin/env bash

section "GNOME Display Manager"

description "This section removes the logo from the GNOME Display Manager \
(GDM), the login screen for the GNOME desktop environment."

echo

question "Do you want to remove the logo from GDM?"

if [ $? = 0 ]; then

    info "Removing logo from GDM."
    sudo gsettings set org.gnome.login-screen logo ''
fi
