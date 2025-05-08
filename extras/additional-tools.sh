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

source "extras/tools-list.sh"

section "Additional command line tools"

description "This section presents a collection of command line tools. \
These tools cover a wide range of functionalities, such as terminal based \
video recording, terminal sharing, vulnerability scanning, data processing, \
system monitoring, web development, and much more, providing users with a \
comprehensive set of utilities to enhance their productivity and workflow \
within the terminal environment."

echo

text "Do you want to install any of these command line tools?"

readarray -t CLI_TOOLS_TO_INSTALL <<< $(${GUM} choose --no-limit --height 15 --selected='*' "${CLI_TOOLS_LIST[@]}")

if [ -z "${CLI_TOOLS_TO_INSTALL}" ]; then

    text "You haven't selected any items from the list. Moving on."
else

    text "You've selected ${#CLI_TOOLS_TO_INSTALL[@]} command line tool(s) to install. Please wait."

    for CLI_TOOL_TO_INSTALL in "${CLI_TOOLS_TO_INSTALL[@]}"; do
        
        source "extras/${CLI_TOOL_TO_INSTALL}-download.sh"
    done

    source "extras/tools-unpacking.sh"

    for CLI_TOOL_TO_INSTALL in "${CLI_TOOLS_TO_INSTALL[@]}"; do
        
        test -f "extras/${CLI_TOOL_TO_INSTALL}-setup.sh" && source "extras/${CLI_TOOL_TO_INSTALL}-setup.sh"
    done

    source "extras/tools-deployment.sh"
fi
