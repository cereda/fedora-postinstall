#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "FlatPark installation and configuration"

description "Configure the FlatPark Flatpak repository."
echo

if question "Do you want to install and configure FlatPark?"; then

    # registers the signed FlatPark repository (per user, no admin needed)
    info "Installing and configuring FlatPark."
    flatpak --user remote-add --if-not-exists flatpark https://dl.flatpark.org/flatpark.flatpakrepo
fi
