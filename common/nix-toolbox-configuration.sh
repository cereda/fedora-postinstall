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

section "Nix Toolbox configuration"

description "Nix Toolbox is a project that enhances the Fedora Toolbox \
container image by integrating the Nix package manager and optionally \
Home Manager. It supports Nix-based development environments and allows \
users to manage their home environment as code."

echo

# ask user input for the toolbox container name
NIX_TOOLBOX_NAME=$(${GUM} input --prompt "Your Nix Toolbox container name: " --value "nix-toolbox-${FEDORA_VERSION}")

info "Creating and configuring Nix Toolbox."
toolbox create --image ghcr.io/thrix/nix-toolbox:${FEDORA_VERSION} ${NIX_TOOLBOX_NAME}
