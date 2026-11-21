#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "forgit installation and configuration"

description "Install and configure forgit."
echo

if question "Do you want to install forgit?"; then

    info "Cloning the repository."
    git clone https://github.com/wfxr/forgit "${ROOT_DIRECTORY_STRUCTURE}/applications/forgit"

    info "Writing helper script."
    # Resolve managed paths now; escaped values remain runtime shell expressions.
    cat >"${ROOT_DIRECTORY_STRUCTURE}/scripts/forgit.sh" <<SH
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
SH

fi
