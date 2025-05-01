#!/usr/bin/env bash

section "direnv installation and configuration"

description "direnv is an open-source environment variable management tool \
that automatically loads and unloads environment variables based on the \
current directory. It helps developers manage project-specific configurations \
and dependencies, making it easier to switch between different development \
environments."

echo

question "Do you want to install and configure direnv?"

if [ $? = 0 ]; then

    info "Installing and configuring direnv."
    export bin_path="${HOME}/.local/bin" && \
    curl -sfL https://direnv.net/install.sh | bash
fi