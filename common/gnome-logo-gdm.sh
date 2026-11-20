#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "GNOME Display Manager"

description "This section removes the Fedora logo from the GNOME Display \
Manager (GDM), the login screen for the GNOME desktop environment."

echo

question "Do you want to remove the Fedora logo from GDM?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    info "Removing Fedora logo from GDM."
    sudo -u gdm gsettings set org.gnome.login-screen logo ''
fi
