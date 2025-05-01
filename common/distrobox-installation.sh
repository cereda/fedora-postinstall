#!/usr/bin/env bash

section "Distrobox installation and configuration"

description "Distrobox is an open-source project that enables users \
to run different Linux distributions as isolated containers within \
their host operating system, providing a flexible and convenient \
way to access a variety of tools and applications across multiple \
Linux environments on a single machine."

echo

question "Do you want to install and configure Distrobox?"

if [ $? = 0 ]; then

    info "Installing and configuring Distrobox from GitHub."
    curl -s https://raw.githubusercontent.com/89luca89/distrobox/main/install | sh -s -- --prefix ~/.local
fi
