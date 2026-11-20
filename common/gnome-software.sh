#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "GNOME Software"

description "This section configures the GNOME Software application to \
disable the automatic download and notification of software updates."

echo

question "Do you want to disable notifications from GNOME Software?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    info "Disabling download updates."
    gsettings set org.gnome.software download-updates false

    info "Disabling notify updates."
    gsettings set org.gnome.software download-updates-notify false
fi
