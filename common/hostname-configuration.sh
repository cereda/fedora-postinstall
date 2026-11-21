#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Hostname configuration"

description "Set the system hostname."
echo

MACHINE_NAME=$(prompt_valid_hostname)

info "Configuring hostname."
if ! sudo hostnamectl hostname "${MACHINE_NAME}"; then
    text "Unable to configure the hostname. Aborting before modifying the home directory."
    return 1
fi

echo

text "Your Fedora ${FEDORA_VERSION} system is now named ${MACHINE_NAME}."
