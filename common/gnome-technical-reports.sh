#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "GNOME technical reports"

description "This section disables the GNOME technical problem reporting \
feature, preventing the automatic submission of diagnostic information to \
the developers."

echo

question "Do you want to disable technical reports?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    info "Disabling technical problem reporting."
    gsettings set org.gnome.desktop.privacy report-technical-problems false
fi
