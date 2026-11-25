#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Forgit installation and configuration"

ui_description "Install Forgit and create its helper script."

if ui_confirm "Install Forgit?" "Install" "Skip"; then

    ui_step "Installing Forgit and creating its helper script."
    git clone https://github.com/wfxr/forgit "${ROOT_DIRECTORY_STRUCTURE}/applications/forgit"

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

    ui_success "Forgit and its helper script are ready."
else
    ui_skip "Forgit was not installed."
fi
