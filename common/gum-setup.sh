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

# fixed version
GUM_VERSION="0.16.1"

# fixed release link
GUM_LINK="https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/gum_${GUM_VERSION}_Linux_x86_64.tar.gz"

# check if gum exists in the path; if it's not, assume it is available
# directly in the script path
GUM=$(command -v gum || printf "${SCRIPT_PATH}/gum")

# gum is not available, so the script will download it from GitHub and extract
# it to the current directory; since the GUM variable is already set to the
# script path + gum, the reference is guaranteed to work after the extraction
if [ ! -x "${GUM}" ]; then

    echo "╭───────────────────────────────────────────────────────────────────╮"
    echo "│ This script relies on 'gum' -- a tool that provides ready-to-use  │"
    echo "│ utilities to help users write useful, interactive scripts. Please │"
    echo "│ wait while the binary is downloaded from GitHub and extracted to  │"
    echo "│ the current directory.                                            │"
    echo "╰───────────────────────────────────────────────────────────────────╯"

    # download it from GitHub and extract the binary file into the current
    # directory (gum should have the execute permission set)
    wget -q "${GUM_LINK}" -O gum.tar.gz
    tar xvzf gum.tar.gz --wildcards --no-anchored '*gum' && mv gum_*/gum . && rm -rf gum_*
fi
