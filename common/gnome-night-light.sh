#!/usr/bin/env bash

section "GNOME night light"

description "This section enables the GNOME night light feature, which \
adjusts the screen's color temperature to reduce blue light exposure \
during the evening hours."

echo

question "Do you want to enable night light?"

if [ $? = 0 ]; then

    info "Enabling night light."
    gsettings set org.gnome.settings-daemon.plugins.color night-light-enabled true
fi
