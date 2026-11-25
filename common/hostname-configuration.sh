#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Hostname configuration"

ui_description "Set the system hostname."

if MACHINE_NAME=$(prompt_valid_hostname); then
    MACHINE_NAME_STATUS=0
else
    MACHINE_NAME_STATUS="${?}"
fi
if [ "${MACHINE_NAME_STATUS}" -ne 0 ]; then
    return "${MACHINE_NAME_STATUS}"
fi

ui_step "Configuring the system hostname."
if ! sudo hostnamectl hostname "${MACHINE_NAME}"; then
    ui_error "Unable to configure the hostname. The home directory was not modified."
    return 1
fi

ui_success "Your Fedora ${FEDORA_VERSION} system is now named ${MACHINE_NAME}."
