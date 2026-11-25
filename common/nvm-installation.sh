#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "nvm installation and configuration"

ui_description "Install and configure nvm."

if ui_confirm "Install and configure nvm?" "Install" "Skip"; then

    # Install the latest release tag rather than the repository's default branch.
    ui_step "Installing nvm from GitHub."
    NVM_DIR="${ROOT_DIRECTORY_STRUCTURE}/applications/nvm"
    (git clone https://github.com/nvm-sh/nvm.git "${NVM_DIR}" && cd "${NVM_DIR}" && git checkout $(git describe --abbrev=0 --tags --match "v[0-9]*" $(git rev-list --tags --max-count=1)))

    ui_step "Creating the nvm configuration script."
    # Resolve managed paths now; escaped values remain runtime shell expressions.
    cat >"${ROOT_DIRECTORY_STRUCTURE}/scripts/node.sh" <<SH
export NVM_DIR="${ROOT_DIRECTORY_STRUCTURE}/applications/nvm"
[ -s "\${NVM_DIR}/nvm.sh" ] && \. "\${NVM_DIR}/nvm.sh"
[ -s "\${NVM_DIR}/bash_completion" ] && \. "\${NVM_DIR}/bash_completion"
SH

else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "nvm was not installed."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
