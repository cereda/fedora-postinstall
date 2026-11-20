#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "yazi installation"

description "yazi is a blazing fast terminal file manager written in Rust,\
based on async I/O. It can be optionally extended with other command line\
tools to enable additional features."

echo

warning "yazi is also available as a standalone binary in the additional \
command line tools section. If you want a minimal footprint (no optional \
dependencies), reply "No" to this prompt and install yazi later."

echo

question "Do you want to install yazi?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    info "Enabling the yazi COPR."
    sudo dnf copr enable lihaohong/yazi

    info "Installing yazi as an RPM package."
    sudo dnf install yazi

fi
