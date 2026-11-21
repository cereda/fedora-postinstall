#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Profile photo"

description "Install a generated desktop profile photo."
echo

if question "Do you want to generate and copy the profile photo?"; then

    info "Generating profile photo."
    bash common/generate-cat.sh

    info "Copying profile photo."
    cp cat.png "${ROOT_DIRECTORY_STRUCTURE}/profile/cat.png"
fi
