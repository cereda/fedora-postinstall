#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "nvm installation and configuration"

description "Install and configure nvm."
echo

if question "Do you want to install nvm?"; then

    # Install the latest release tag rather than the repository's default branch.
    info "Installing nvm from GitHub."
    NVM_DIR="${ROOT_DIRECTORY_STRUCTURE}/applications/nvm"
    (git clone https://github.com/nvm-sh/nvm.git "${NVM_DIR}" && cd "${NVM_DIR}" && git checkout $(git describe --abbrev=0 --tags --match "v[0-9]*" $(git rev-list --tags --max-count=1)))

    info "Creating configuration script."
    # Resolve managed paths now; escaped values remain runtime shell expressions.
    cat >"${ROOT_DIRECTORY_STRUCTURE}/scripts/node.sh" <<SH
export NVM_DIR="${ROOT_DIRECTORY_STRUCTURE}/applications/nvm"
[ -s "\${NVM_DIR}/nvm.sh" ] && \. "\${NVM_DIR}/nvm.sh"
[ -s "\${NVM_DIR}/bash_completion" ] && \. "\${NVM_DIR}/bash_completion"
SH

fi
