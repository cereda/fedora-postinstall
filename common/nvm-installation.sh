#!/usr/bin/env bash

# MIT License
# 
# Copyright (c) 2025, Paulo Cereda
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

section "nvm installation and configuration"

description "nvm (Node Version Manager) is an open source tool that \
allows developers to easily install, manage, and switch between \
different versions of the Node.js runtime on their local machines. \
It provides a convenient way to work with multiple Node.js \
versions, enabling developers to test their applications against \
different environments and ensure compatibility."

echo

question "Do you want to install nvm?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    # according to the documentation, the following method is the manual \
    # install; to upgrade nvm, it's advisable to follow these steps:
    #
    # $ cd "${NVM_DIR}"
    # $ git describe --tags --abbrev=0
    # $ git checkout -f <latest tag>
    #
    # note that this will cause a detached HEAD (i.e, HEAD does not point to
    # a branch, but to a specific commit); note to self: automate this
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
