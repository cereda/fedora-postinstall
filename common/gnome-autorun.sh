#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Autorun settings for removable media"

description "This section tweaks the GNOME settings to disable the autorun \
feature for removable media, preventing automatic execution of programs or \
scripts when a removable device is inserted."

echo

question "Do you want to disable autorun for removable media?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    info "Disabling autorun for removable media."
    gsettings set org.gnome.desktop.media-handling autorun-never true
fi
