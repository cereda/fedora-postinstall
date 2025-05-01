#!/usr/bin/env bash

section "Rust installation and configuration"

description "Rust is an open-source, systems programming language \
that focuses on performance, safety, and concurrency. It is \
designed to be a safe, concurrent, and practical language, \
suitable for a wide range of applications, from low-level \
system programming to high-level web development and beyond."

echo

question "Do you want to install Rust?"

if [ $? = 0 ]; then

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
