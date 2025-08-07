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

description "Rust is an open source, systems programming language \
that focuses on performance, safety, and concurrency. It is \
designed to be a safe, concurrent, and practical language, \
suitable for a wide range of applications, from low-level \
system programming to high level web development and beyond."

echo

warning "Note that Rust requires a C toolchain. Please install a C compiler \
using 'sudo dnf install gcc' (installing the development tools group will \
also work). Alternatively, you can set up the C toolchain inside a toolbox."

echo

question "Do you want to install Rust?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    info "Preparing the Rust environment."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/environments/rust"
    
    info "Exporting environment variables."
    export CARGO_HOME="${ROOT_DIRECTORY_STRUCTURE}/environments/rust/cargo"
    export RUSTUP_HOME="${ROOT_DIRECTORY_STRUCTURE}/applications/rustup"

    # rustup has its own installation script, setting both the rustup and
    # the cargo directories via environment variables (as described in the 
    # documentation); to avoid path modification, a command line flag is
    # also applied to the installation script
    info "Installing binaries."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- --no-modify-path

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
