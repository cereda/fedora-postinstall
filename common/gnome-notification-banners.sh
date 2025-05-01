#!/usr/bin/env bash

section "GNOME notification banners"

description "This script adjusts the GNOME desktop settings by disabling the \
display of notification banners and the appearance of notifications on the \
lock screen."

echo

question "Do you want to disable notification banners?"

if [ $? = 0 ]; then

    info "Disabling notification banners."
    gsettings set org.gnome.desktop.notifications show-banners false

    info "Disabling notifications in lock screen."
    gsettings set org.gnome.desktop.notifications show-in-lock-screen false
fi
