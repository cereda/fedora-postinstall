#!/usr/bin/env bash

section "GNOME clock"

description "This section modifies the GNOME clock settings to display \
the weekday in addition to the time."

echo

question "Do you want to configure the GNOME clock?"

if [ $? = 0 ]; then

    info "Showing weekday."
    gsettings set org.gnome.desktop.interface clock-show-weekday true
fi
