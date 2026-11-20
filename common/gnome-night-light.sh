#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "GNOME night light"

description "This section enables the GNOME night light feature, which \
adjusts the screen's color temperature to reduce blue light exposure \
during the evening hours."

echo

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
question "Do you want to enable night light?"

if [ $? = 0 ]; then

    info "Enabling night light."
    gsettings set org.gnome.settings-daemon.plugins.color night-light-enabled true
fi
