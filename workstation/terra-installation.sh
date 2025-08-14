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

section "Terra installation"

description "The Terra repository is a centralized collection of software \
packages and resources that supports the Fedora Linux distribution. It \
enables developers and users to access and manage packages, ensuring the \
environment remains current and functional while providing essential tools \
and applications for the community."

echo

question "Do you want to install the Terra repository?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    info "Configuring the repository."
    sudo dnf install --nogpgcheck --repofrompath "terra,https://repos.fyralabs.com/terra${FEDORA_VERSION}" terra-release
fi
