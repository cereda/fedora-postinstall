#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "direnv installation and configuration"

description "direnv is an open source environment variable management tool \
that automatically loads and unloads environment variables based on the \
current directory. It helps developers manage project-specific configurations \
and dependencies, making it easier to switch between different development \
environments."

echo

question "Do you want to install and configure direnv?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    # direnv has its own installation script, setting the target directory
    # via environment variable (as described in the documentation)
    info "Installing and configuring direnv."
    export bin_path="${HOME}/.local/bin" && curl -sfL https://direnv.net/install.sh | bash
fi
