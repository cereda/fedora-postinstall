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

echo

# display a list of command line tools from the the CLI_TOOLS_LIST environment
# variable set previously (see [extras/tools-list.sh] for reference)
# and collect the selected entries into a new array
readarray -t CLI_TOOLS_TO_INSTALL <<< $(${GUM} choose --no-limit --height 15 --selected='*' "${CLI_TOOLS_LIST[@]}")

# no items were selected in the list based on the -z check -- a test operator
# that checks if a string is null
if [ -z "${CLI_TOOLS_TO_INSTALL}" ]; then

    # display a message to the user
    text "You haven't selected any items from the list. Moving on."
else

    # at least one item was selected in the list (variable is not null),
    # so the script can install the chosen command line tool(s)

    text "You've selected ${#CLI_TOOLS_TO_INSTALL[@]} command line tool(s) to install. Please wait."

    # iterate through all the items in the list, display a message and install
    # each command line tool
    for CLI_TOOL_TO_INSTALL in "${CLI_TOOLS_TO_INSTALL[@]}"; do
        
        # source each selected item
        source "extras/${CLI_TOOL_TO_INSTALL}-download.sh"
    done

    # unpack all files
    source "extras/tools-unpacking.sh"

    # iterate through all the items in the list, display a message and
    # source any additional setup for the choosen tool(s), if applicable
    for CLI_TOOL_TO_INSTALL in "${CLI_TOOLS_TO_INSTALL[@]}"; do
        
        # test if the additional setup exists and source it
        test -f "extras/${CLI_TOOL_TO_INSTALL}-setup.sh" && source "extras/${CLI_TOOL_TO_INSTALL}-setup.sh"
    done

    # deploy all executables
    source "extras/tools-deployment.sh"
fi
