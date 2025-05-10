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

section "Miniconda installation"

description "Miniconda is a lightweight distribution of the Anaconda Python \
and R data science platform. It includes the Conda package manager and \
Python, allowing users to create and manage virtual environments for \
different projects and dependencies."

echo

question "Do you want to install Miniconda?"

if [ $? = 0 ]; then

    MINICONDA_INSTALLATION_DIRECTORY="${ROOT_DIRECTORY_STRUCTURE}/applications/miniconda/3"

    info "Creating installation directory."
    mkdir -p "${MINICONDA_INSTALLATION_DIRECTORY}"

    info "Downloading Miniconda."
    wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O miniconda-linux.sh

    info "Installing Miniconda."
    bash miniconda-linux.sh -b -u -p "${MINICONDA_INSTALLATION_DIRECTORY}"

fi
