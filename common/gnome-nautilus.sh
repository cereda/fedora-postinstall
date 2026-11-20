#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "GNOME Nautilus"

description "This section configures the GNOME Nautilus file manager to \
set the default folder viewer to icon view and disable the display of \
image thumbnails."

echo

question "Do you want to configure Nautilus?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    info "Setting default folder viewer."
    gsettings set org.gnome.nautilus.preferences default-folder-viewer icon-view

    info "Disabling image thumbnails."
    gsettings set org.gnome.nautilus.preferences show-image-thumbnails never
fi
