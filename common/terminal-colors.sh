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

section "Color configuration for the terminal"

description "vivid is a generator for the LS_COLORS environment \
variable that controls the colorized output of ls, tree, fd, \
bfs, dust and many other tools."

echo

question "Would you like to apply a color theme to the terminal?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    text "Select the color theme to use for the terminal:"

    echo

    # display a list of color themes; the theme list is generated via:
    #
    # $ vivid themes
    COLOR_THEME=$(${GUM} choose --height 15 --selected='dracula' "${COLOR_THEMES[@]}")

    # fallback in case the user does not select a color theme, based on the
    # -z check -- a test operator that checks if a string is null
    if [ -z "${COLOR_THEME}" ]; then
        COLOR_THEME="dracula"
    fi

    info "Generating custom colors file."
    tee "${ROOT_DIRECTORY_STRUCTURE}/scripts/colors.sh" <<EOF
if [ -x "\$(command -v vivid)" ]; then
    export LS_COLORS="\$(vivid generate ${COLOR_THEME})"
fi
EOF

fi
