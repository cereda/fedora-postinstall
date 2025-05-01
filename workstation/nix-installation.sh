#!/usr/bin/env bash

section "Nix installation and configuration"

describe "Nix is a powerful, open-source, functional package manager and \
build system that provides a declarative and reproducible approach to \
software deployment and configuration management. It aims to simplify the \
installation, management, and sharing of software packages across different \
systems and environments."

echo

question "Do you want to install and configure Nix?"

if [ $? = 0 ]; then

    info "Installing Nix using the Linux planner."
    curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install linux --no-confirm
fi
