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

section "mise installation"

description "mise is a command line tool designed for setting up and managing \
development environments. It simplifies the installation of development tools \
and runtimes, manages environment variables, and can act as a task runner. By \
streamlining these processes, mise helps developers create consistent and \
efficient workflows, allowing them to focus more on coding and less on \
configuration."

echo

question "Do you want to install mise?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    # Note: GitHub may apply rate limits to the API endpoint, which could
    # cause this section to fail (been there, done that)

    info "Getting latest version of mise from GitHub."
    test -f mise.json || wget -q -O mise.json https://api.github.com/repos/jdx/mise/releases/latest

    info "Downloading mise from GitHub."
    wget -q $(jq -r '.assets[] | select(.name | contains("linux") and contains("x64") and (contains("musl")|not) and endswith("tar.gz")).browser_download_url' mise.json)

    info "Extracting mise."
    tar xzf mise*.tar.gz

    info "Preparing the installation directory."
    mkdir -p "${HOME}/.local/bin"

    info "Moving binary to the installation directory."
    mv mise/bin/mise "${HOME}/.local/bin/"

    info "Creating data directory."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/data/mise"

    info "Creating configuration directory."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/config/mise"
fi
