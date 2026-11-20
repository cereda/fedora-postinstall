#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Terra installation"

description "The Terra repository is a centralized collection of software \
packages and resources that supports the Fedora Linux distribution. It \
enables developers and users to access and manage packages, ensuring the \
environment remains current and functional while providing essential tools \
and applications for the community."

echo

question "Do you want to install the Terra repository?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    info "Configuring the repository."
    sudo dnf install --nogpgcheck --repofrompath "terra,https://repos.fyralabs.com/terra${FEDORA_VERSION}" terra-release
fi
