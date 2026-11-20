#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "FlatPark installation and configuration"

description "FlatPark is a community Flatpak hub for apps that ship as a \
definitive download — an official installer or prebuilt archive at a \
stable, public release URL."

echo

question "Do you want to install and configure FlatPark?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    # registers the signed FlatPark repository (per user, no admin needed)
    info "Installing and configuring FlatPark."
    flatpak --user remote-add --if-not-exists flatpark https://dl.flatpark.org/flatpark.flatpakrepo
fi
