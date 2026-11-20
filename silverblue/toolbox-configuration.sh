#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Toolbox configuration"

description "Toolbox is a command line tool that provides a convenient way \
to create and manage isolated development environments within Fedora \
Linux. It allows users to install and run applications in a self \
contained, reproducible container, without affecting the host system."

echo

# ask user input for the toolbox container name
TOOLBOX_NAME=$(prompt_valid_container_name "Your toolbox container name: " "f${FEDORA_VERSION}-dev")

info "Creating and configuring toolbox."
toolbox create "${TOOLBOX_NAME}"
