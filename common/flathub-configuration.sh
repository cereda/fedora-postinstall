#!/usr/bin/env bash

section "Flathub installation and configuration"

description "Flathub is a centralized app store for Linux distributions \
that use the Flatpak packaging format, providing a convenient way for \
users to discover and install applications."

echo

question "Do you want to install and configure Flathub?"

if [ $? = 0 ]; then

    info "Installing and configuring Flathub."
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

    info "Enabling Flathub."
    flatpak remote-modify --enable flathub  
fi
