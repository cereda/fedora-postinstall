#!/usr/bin/env bash

section "nvm installation and configuration"

description "nvm (Node Version Manager) is an open-source tool that \
allows developers to easily install, manage, and switch between \
different versions of the Node.js runtime on their local machines. \
It provides a convenient way to work with multiple Node.js \
versions, enabling developers to test their applications against \
different environments and ensure compatibility."

echo

question "Do you want to install nvm?"

if [ $? = 0 ]; then

    info "Installing nvm from GitHub."
    NVM_DIR="${ROOT_DIRECTORY_STRUCTURE}/applications/nvm"
    (git clone https://github.com/nvm-sh/nvm.git "${NVM_DIR}" && cd "${NVM_DIR}" && git checkout `git describe --abbrev=0 --tags --match "v[0-9]*" $(git rev-list --tags --max-count=1)`)

    info "Creating configuration script."
    tee "${ROOT_DIRECTORY_STRUCTURE}/scripts/node.sh" <<EOF
export NVM_DIR="${ROOT_DIRECTORY_STRUCTURE}/applications/nvm"
[ -s "\${NVM_DIR}/nvm.sh" ] && \. "\${NVM_DIR}/nvm.sh"
[ -s "\${NVM_DIR}/bash_completion" ] && \. "\${NVM_DIR}/bash_completion"
EOF

fi
