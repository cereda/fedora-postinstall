#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

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
