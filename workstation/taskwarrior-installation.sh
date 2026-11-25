#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Taskwarrior installation and configuration"

ui_description "Install Taskwarrior and create its managed configuration."

if ui_confirm "Install and configure Taskwarrior?" "Install" "Skip"; then

    ui_step "Installing Taskwarrior."
    sudo dnf install task -y

    ui_step "Creating Taskwarrior configuration and data directories."
    # Resolve managed paths now; escaped values remain runtime shell expressions.
    cat >"${ROOT_DIRECTORY_STRUCTURE}/scripts/taskwarrior.sh" <<SH
#!/bin/bash
export TASKRC="${ROOT_DIRECTORY_STRUCTURE}/config/taskwarrior/taskrc"
export TASKDATA="${ROOT_DIRECTORY_STRUCTURE}/data/taskwarrior"
SH

    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/config/taskwarrior"
    cat >"${ROOT_DIRECTORY_STRUCTURE}/config/taskwarrior/taskrc" <<'TASKRC'
verbose=affected,blank,context,edit,footnote,label,project,special,sync,override,recur
TASKRC

    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/data/taskwarrior"

    ui_success "Taskwarrior and its configuration are ready."
else
    ui_skip "Taskwarrior was not installed."
fi
