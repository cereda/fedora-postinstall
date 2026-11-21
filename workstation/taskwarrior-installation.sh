#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Taskwarrior installation and configuration"

description "Install and configure Taskwarrior."
echo

if question "Do you want to install and configure Taskwarrior?"; then

    info "Installing Taskwarrior as an RPM package."
    sudo dnf install task -y

    info "Creating main configuration file."
    # Resolve managed paths now; escaped values remain runtime shell expressions.
    cat >"${ROOT_DIRECTORY_STRUCTURE}/scripts/taskwarrior.sh" <<SH
#!/bin/bash
export TASKRC="${ROOT_DIRECTORY_STRUCTURE}/config/taskwarrior/taskrc"
export TASKDATA="${ROOT_DIRECTORY_STRUCTURE}/data/taskwarrior"
SH

    info "Creating settings file."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/config/taskwarrior"
    cat >"${ROOT_DIRECTORY_STRUCTURE}/config/taskwarrior/taskrc" <<'TASKRC'
verbose=affected,blank,context,edit,footnote,label,project,special,sync,override,recur
TASKRC

    info "Creating data directory."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/data/taskwarrior"

fi
