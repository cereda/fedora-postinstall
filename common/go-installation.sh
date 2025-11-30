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

section "Go installation and configuration"

description "Go is a programming language developed by Google. It's designed \
for simplicity, efficiency, and strong support for concurrent programming, \
making it ideal for building scalable and high performance applications. \
Go features a statically typed syntax, garbage collection, and a rich \
standard library, which together facilitate rapid development and ease of \
maintenance."

echo

question "Do you want to install Go?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    # get the latest version
    info "Getting the latest version of Go."
    GO_LATEST_VERSION="$(wget -q -O - https://go.dev/dl/ | grep -oP 'dl/[^"]*linux-amd64\.tar\.gz' | head -n 1)"

    info "Downloading Go."
    wget -q "https://go.dev/${GO_LATEST_VERSION}"

    info "Extracting Go."
    tar xzf go*.tar.gz

    info "Moving Go to the local applications directory."
    mv go "${ROOT_DIRECTORY_STRUCTURE}/applications/"

    info "Creating environment."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/environments/go"

    tee "${ROOT_DIRECTORY_STRUCTURE}/scripts/go.sh" <<EOF
#!/bin/bash

# this is my personal variable and not related to GOROOT or any other
# environment variable used by Go (also, setting GOROOT is discouraged
# according to the documentation)
export GO_HOME="${ROOT_DIRECTORY_STRUCTURE}/applications/go"

# while the use of GOPATH is not mandatory since the introduction of Go
# modules, it's still relevant in certain contexts and can be useful for
# specific workflows
export GOPATH="${ROOT_DIRECTORY_STRUCTURE}/environments/go"

pathmunge () {
    if ! echo \$PATH | /bin/grep -E -q "(^|:)\$1($|:)" ; then
        if [ "\$2" = "after" ] ; then
            PATH=\$PATH:\$1
        else
            PATH=\$1:\$PATH
        fi
    fi
}
pathmunge \${GO_HOME}/bin after
unset pathmunge
EOF

    info "Removing archive file."
    rm -f go*.tar.gz

fi
