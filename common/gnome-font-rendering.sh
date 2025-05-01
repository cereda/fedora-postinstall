#!/usr/bin/env bash

section "GNOME font rendering"

description "This section applies font antialiasing and hinting settings to \
improve the rendering and appearance of fonts in the GNOME desktop environment."

echo

question "Do you want to improve font rendering?"

if [ $? = 0 ]; then

    info "Applying font antialiasing."
    gsettings set org.gnome.desktop.interface font-antialiasing rgba

    info "Applying font hinting."
    gsettings set org.gnome.desktop.interface font-hinting slight
fi
