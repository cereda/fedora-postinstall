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

section "Distrobox installation and configuration"

description "Distrobox is an open source project that enables users \
to run different Linux distributions as isolated containers within \
their host operating system, providing a flexible and convenient \
way to access a variety of tools and applications across multiple \
Linux environments on a single machine."

echo

warning "Consider installing BoxBuddy, a graphical user interface for \
Distrobox. This application makes creating and using containers simple \
and convenient by providing a simple UI for many common tasks."

echo

question "Do you want to install and configure Distrobox?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    # Distrobox has its own installation script, setting the target directory
    # prefix via command line flag (as described in the documentation)
    info "Installing and configuring Distrobox from GitHub."
    curl -s https://raw.githubusercontent.com/89luca89/distrobox/main/install | sh -s -- --prefix ~/.local
fi
