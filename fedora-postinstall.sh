#!/usr/bin/env bash

source "common/gum-setup.sh"
source "common/gum-functions.sh"

source "common/flatpaks-to-install.sh"
source "common/fonts-to-install.sh"

FEDORA_VERSION=$(rpm -E %fedora)

chapter "Paulo's Fedora ${FEDORA_VERSION} post installation script"

description "Fedora Linux is a free and open-source operating system \
sponsored by Red Hat, focused on innovation, security, and community \
collaboration. It provides a stable, cutting-edge platform for \
developers, enthusiasts, and users seeking a modern, reliable Linux \
distribution."

echo

question "Did you upgrade your system?" || exit 1

text "Welcome to my post installation script for Fedora! \
Please select which flavour of Fedora you are currently running."

FEDORA_FLAVOUR=$(${GUM} choose "Workstation" "Silverblue")

text "You are running Fedora ${FEDORA_FLAVOUR} ${FEDORA_VERSION}. Let's go!"

[[ "${FEDORA_FLAVOUR}" = "Workstation" ]] && source "workstation-postinstall.sh"
[[ "${FEDORA_FLAVOUR}" = "Silverblue" ]] && source "silverblue-postinstall.sh"

text "That's all, folks!"
