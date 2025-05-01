#!/usr/bin/env bash

section "Hostname configuration"

description "Having a custom hostname for a Linux machine provides \
convenience by allowing you to easily identify and remember the \
machine. This can be especially useful in a network with multiple \
machines, as it makes it simpler to refer to and access a specific \
system. A custom hostname can also help organize and manage your \
infrastructure more effectively."

echo

MACHINE_NAME=$(${GUM} input --prompt "Your machine name: ")

info "Configuring hostname."
sudo hostnamectl hostname "${MACHINE_NAME}"

text "Your Fedora ${FEDORA_VERSION} system is now named ${MACHINE_NAME}."