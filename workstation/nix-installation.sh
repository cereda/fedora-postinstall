#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Nix installation and configuration"

description "Nix is a powerful, open source, functional package manager and \
build system that provides a declarative and reproducible approach to \
software deployment and configuration management. It aims to simplify the \
installation, management, and sharing of software packages across different \
systems and environments."

echo

question "Do you want to install and configure Nix?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    info "Installing Nix using the Linux planner."
    curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install linux --no-confirm
fi
