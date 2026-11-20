#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "GNOME clock"

description "This section modifies the GNOME clock settings to display \
the weekday in addition to the time."

echo

question "Do you want to configure the GNOME clock?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    info "Showing weekday."
    gsettings set org.gnome.desktop.interface clock-show-weekday true
fi
