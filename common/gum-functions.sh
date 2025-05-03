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

GUM_TEXT_WIDTH=75

function chapter {
    ${GUM} style --border double \
        --align center \
        --width ${GUM_TEXT_WIDTH} \
        --padding "1 0" \
        --foreground 10 \
        --border-foreground 10 \
        "$1"
}

function section {
    ${GUM} style --width ${GUM_TEXT_WIDTH} \
        --border rounded \
        --align center \
        --foreground 12 \
        --border-foreground 12 \
        "$1"
}

function question {
    ${GUM} confirm \
        --prompt.foreground=6 \
        --selected.background=6 \
        "$1"
}

function text {
    ${GUM} style --width ${GUM_TEXT_WIDTH} \
    "$1"    
}

function description {
    ${GUM} style --width ${GUM_TEXT_WIDTH} \
    --italic \
    "$1"
}

function info {
    ${GUM} style --width ${GUM_TEXT_WIDTH} \
        --foreground 11 \
        "$1"
}

function dirchooser {
    ${GUM} style --width ${GUM_TEXT_WIDTH} \
"Please select a directory. You can navigate between \
directories using the left and right arrow keys, and \
select one with the Enter key."

    local DIRECTORY=null

    while [ ! -d "${DIRECTORY}" ]; do

        DIRECTORY=$(gum file --all --permissions --directory)
    done
    
    echo "$DIRECTORY"
}