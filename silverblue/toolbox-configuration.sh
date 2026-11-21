#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Toolbox configuration"

description "Create and configure the Fedora toolbox container."
echo

TOOLBOX_NAME=$(prompt_valid_container_name "Your toolbox container name: " "f${FEDORA_VERSION}-dev")

info "Creating and configuring toolbox."
toolbox create "${TOOLBOX_NAME}"
