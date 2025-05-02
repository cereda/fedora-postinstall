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

section "Rust installation and configuration"

description "Rust is an open-source, systems programming language \
that focuses on performance, safety, and concurrency. It is \
designed to be a safe, concurrent, and practical language, \
suitable for a wide range of applications, from low-level \
system programming to high-level web development and beyond."

echo

question "Do you want to install Rust?"

if [ $? = 0 ]; then

    if [ -z ${ROOT_DIRECTORY_STRUCTURE+x} ]; then
      warning "Custom configuration for the home directory was not set."
      warning "I don't know where to install Rust."
      warning "The script will move to the next section."
      return 0
    fi

    info "Preparing the Rust environment."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/environments/rust"
    
    info "Exporting environment variables."
    export CARGO_HOME="${ROOT_DIRECTORY_STRUCTURE}/environments/rust/cargo"
    export RUSTUP_HOME="${ROOT_DIRECTORY_STRUCTURE}/applications/rustup"

    info "Installing binaries."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

    info "Writing helper script."
    tee "${ROOT_DIRECTORY_STRUCTURE}/scripts/rust.sh" <<EOF
#!/bin/bash
export CARGO_HOME="${ROOT_DIRECTORY_STRUCTURE}/environments/rust/cargo"
export RUSTUP_HOME="${ROOT_DIRECTORY_STRUCTURE}/applications/rustup"

pathmunge () {
    if ! echo \$PATH | /bin/grep -E -q "(^|:)\$1($|:)" ; then
        if [ "\$2" = "after" ] ; then
            PATH=\$PATH:\$1
        else
            PATH=\$1:\$PATH
        fi
    fi
}
pathmunge \${CARGO_HOME}/bin after
unset pathmunge
EOF

fi
