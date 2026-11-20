#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Taskwarrior installation and configuration"

description "Taskwarrior is a flexible and powerful open source task \
management software that helps users organize, track, and prioritize \
tasks through a command line interface. It allows for customization \
and can integrate with various tools, making it suitable for both \
personal and professional use."

echo

question "Do you want to install and configure Taskwarrior?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    info "Installing Taskwarrior as an RPM package."
    sudo dnf install task -y

    info "Creating main configuration file."
    tee "${ROOT_DIRECTORY_STRUCTURE}/scripts/taskwarrior.sh" <<EOF
#!/bin/bash
export TASKRC="${ROOT_DIRECTORY_STRUCTURE}/config/taskwarrior/taskrc"
export TASKDATA="${ROOT_DIRECTORY_STRUCTURE}/data/taskwarrior"
EOF

    info "Creating settings file."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/config/taskwarrior"
    tee "${ROOT_DIRECTORY_STRUCTURE}/config/taskwarrior/taskrc" <<EOF
verbose=affected,blank,context,edit,footnote,label,project,special,sync,override,recur
EOF

    info "Creating data directory."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/data/taskwarrior"

fi
