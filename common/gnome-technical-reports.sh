#!/usr/bin/env bash

section "GNOME technical reports"

description "This section disables the GNOME technical problem reporting \
feature, preventing the automatic submission of diagnostic information to \
the developers."

echo

question "Do you want to disable technical reports?"

if [ $? = 0 ]; then

    info "Disabling technical problem reporting."
    gsettings set org.gnome.desktop.privacy report-technical-problems false
fi
