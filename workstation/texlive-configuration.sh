#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "TeX Live configuration"

description "Configure the system TeX Live path."
echo

if question "Do you want to configure TeX Live?"; then

    info "Creating script for TeX Live."
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

fi
