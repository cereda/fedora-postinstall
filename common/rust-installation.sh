#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Rust installation and configuration"

ui_description "Install and configure Rust."
ui_warning "Rust requires a C toolchain. Install a C compiler with 'sudo dnf install gcc', install the development tools group, or configure the toolchain inside a toolbox."

if ui_confirm "Install Rust?" "Install" "Skip"; then

    ui_step "Installing Rust."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/environments/rust"
    export CARGO_HOME="${ROOT_DIRECTORY_STRUCTURE}/environments/rust/cargo"
    export RUSTUP_HOME="${ROOT_DIRECTORY_STRUCTURE}/applications/rustup"

    # Keep rustup and Cargo inside the managed applications directory.
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- --no-modify-path

    ui_step "Creating the Rust environment helper."
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

else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "Rust was not installed."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
