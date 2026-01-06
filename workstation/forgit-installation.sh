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

section "forgit installation and configuration"

description "forgit is a command line tool that combines the functionalities \
of git and fzf to enhance the Git workflow. It allows users to navigate and \
manage git repositories more efficiently by providing a fuzzy search \
capability for branches, commits, and other elements, streamlining the \
process of finding and interacting with various git objects."

echo

question "Do you want to install forgit?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    info "Cloning the repository."
    git clone https://github.com/wfxr/forgit "${ROOT_DIRECTORY_STRUCTURE}/applications/forgit"
    
    info "Writing helper script."
    tee "${ROOT_DIRECTORY_STRUCTURE}/scripts/forgit.sh" <<EOF
#!/bin/bash
export FORGIT_HOME="${ROOT_DIRECTORY_STRUCTURE}/applications/forgit"
export FORGIT_NO_ALIASES="true"

pathmunge () {
    if ! echo \$PATH | /bin/grep -E -q "(^|:)\$1($|:)" ; then
        if [ "\$2" = "after" ] ; then
            PATH=\$PATH:\$1
        else
            PATH=\$1:\$PATH
        fi
    fi
}

pathmunge \${FORGIT_HOME}/bin after
unset pathmunge

source "${ROOT_DIRECTORY_STRUCTURE}/applications/forgit/forgit.plugin.sh"
EOF

fi
