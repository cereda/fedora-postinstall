#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Hostname configuration"

description "Having a custom hostname for a Linux machine provides \
convenience by allowing you to easily identify and remember the \
machine. This can be especially useful in a network with multiple \
machines, as it makes it simpler to refer to and access a specific \
system. A custom hostname can also help organize and manage your \
infrastructure more effectively."

echo

MACHINE_NAME=$(prompt_valid_hostname)

info "Configuring hostname."
if ! sudo hostnamectl hostname "${MACHINE_NAME}"; then
    text "Unable to configure the hostname. Aborting before modifying the home directory."
    return 1
fi

echo

text "Your Fedora ${FEDORA_VERSION} system is now named ${MACHINE_NAME}."
