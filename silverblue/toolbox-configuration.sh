#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Toolbox configuration"

ui_description "Create the Fedora toolbox container."

if TOOLBOX_NAME=$(prompt_valid_container_name "Your toolbox container name: " "f${FEDORA_VERSION}-dev"); then
    TOOLBOX_NAME_STATUS=0
else
    TOOLBOX_NAME_STATUS="${?}"
fi
if [ "${TOOLBOX_NAME_STATUS}" -ne 0 ]; then
    return "${TOOLBOX_NAME_STATUS}"
fi

ui_step "Creating the ${TOOLBOX_NAME} toolbox."
toolbox create "${TOOLBOX_NAME}"

ui_success "The ${TOOLBOX_NAME} toolbox is ready."
