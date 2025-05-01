#!/usr/bin/env bash

section "GNOME touchpad configuration"

description "This section modifies the GNOME touchpad configuration to \
enable tap-to-click functionality and two-finger scrolling, providing a \
more intuitive and responsive touchpad experience."

echo

question "Do you want to configure your laptop touchpad?"

if [ $? = 0 ]; then

    info "Enabling tap to click."
    gsettings set org.gnome.desktop.peripherals.touchpad tap-to-click true

    info "Enabling two finger scrolling."
    gsettings set org.gnome.desktop.peripherals.touchpad two-finger-scrolling-enabled true
fi
