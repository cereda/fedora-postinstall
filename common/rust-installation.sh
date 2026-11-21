#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Rust installation and configuration"

description "Install and configure Rust."
echo

warning "Note that Rust requires a C toolchain. Please install a C compiler \
using 'sudo dnf install gcc' (installing the development tools group will \
also work). Alternatively, you can set up the C toolchain inside a toolbox."

echo

if question "Do you want to install Rust?"; then

    info "Preparing the Rust environment."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/environments/rust"

    info "Exporting environment variables."
    export CARGO_HOME="${ROOT_DIRECTORY_STRUCTURE}/environments/rust/cargo"
    export RUSTUP_HOME="${ROOT_DIRECTORY_STRUCTURE}/applications/rustup"

    # Keep rustup and Cargo inside the managed applications directory.
    info "Installing binaries."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- --no-modify-path

    info "Writing helper script."
    # Resolve managed paths now; escaped values remain runtime shell expressions.
    cat >"${ROOT_DIRECTORY_STRUCTURE}/scripts/rust.sh" <<SH
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
SH

fi
