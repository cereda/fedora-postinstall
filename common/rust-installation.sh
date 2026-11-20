#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

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
