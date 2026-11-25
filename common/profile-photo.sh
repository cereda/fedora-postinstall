#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Profile photo"

ui_description "Generate a profile photo and save it in the managed profile directory."

if ui_confirm "Generate and save a profile photo?" "Generate" "Skip"; then

    ui_step "Generating the profile photo."
    bash common/generate-cat.sh

    ui_step "Copying the profile photo."
    cp cat.png "${ROOT_DIRECTORY_STRUCTURE}/profile/cat.png"
else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "A profile photo was not generated or saved."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
