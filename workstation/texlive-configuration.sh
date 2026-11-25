#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "TeX Live configuration"

ui_description "Add the system TeX Live path."

if ui_confirm "Configure the system TeX Live path?" "Configure" "Skip"; then

    ui_step "Writing the TeX Live system profile."
    sudo tee "/etc/profile.d/texlive.sh" <<'SH'
#!/bin/bash
pathmunge () {
    if ! echo $PATH | /bin/grep -E -q "(^|:)$1($|:)" ; then
        if [ "$2" = "after" ] ; then
            PATH=$PATH:$1
        else
            PATH=$1:$PATH
        fi
    fi
}
pathmunge /opt/texbin
unset pathmunge
SH

    ui_success "System TeX Live path configured."
else
    ui_skip "TeX Live was not configured."
fi
