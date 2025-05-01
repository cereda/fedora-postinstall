#!/usr/bin/env bash

section "GNOME Software"

description "This section configures the GNOME Software application to \
disable the automatic download and notification of software updates."

echo

question "Do you want to disable notifications from GNOME Software?"

if [ $? = 0 ]; then

    info "Disabling download updates."
    gsettings set org.gnome.software download-updates false

    info "Disabling notify updates."
    gsettings set org.gnome.software download-updates-notify false
fi
