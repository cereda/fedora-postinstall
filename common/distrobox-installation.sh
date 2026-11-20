#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Distrobox installation and configuration"

description "Distrobox is an open source project that enables users \
to run different Linux distributions as isolated containers within \
their host operating system, providing a flexible and convenient \
way to access a variety of tools and applications across multiple \
Linux environments on a single machine."

echo

warning "Consider installing BoxBuddy, a graphical user interface for \
Distrobox. This application makes creating and using containers simple \
and convenient by providing a simple UI for many common tasks."

echo

question "Do you want to install and configure Distrobox?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    # Distrobox has its own installation script, setting the target directory
    # prefix via command line flag (as described in the documentation)
    info "Installing and configuring Distrobox from GitHub."
    curl -s https://raw.githubusercontent.com/89luca89/distrobox/main/install | sh -s -- --prefix ~/.local
fi
