#!/usr/bin/env bash

section "Toolbox configuration"

describe "Toolbox is a command-line tool that provides a convenient way \
to create and manage isolated development environments within Fedora \
Linux. It allows users to install and run applications in a self \
contained, reproducible container, without affecting the host system."

echo

TOOLBOX_NAME=$(${GUM} input --prompt "Your toolbox container name: " --value "$f{FEDORA_VERSION}-dev")

info "Creating and configuring toolbox."
toolbox create ${TOOLBOX_NAME}
