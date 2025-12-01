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
