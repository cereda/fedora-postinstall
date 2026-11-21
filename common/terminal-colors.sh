#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Color configuration for the terminal"

description "Configure terminal colors."
echo

if question "Would you like to apply a color theme to the terminal?"; then

    text "Select the color theme to use for the terminal:"

    echo

    # Generate the available themes with: vivid themes
    runtime_capture_output COLOR_THEME "${GUM}" choose --height 15 --selected='dracula' "${COLOR_THEMES[@]}" || return 1

    if [ -z "${COLOR_THEME}" ]; then
        COLOR_THEME="dracula"
    fi

    info "Generating custom colors file."
    # Resolve the selected theme when the script is generated.
    cat >"${ROOT_DIRECTORY_STRUCTURE}/scripts/colors.sh" <<SH
if [ -x "\$(command -v vivid)" ]; then
    export LS_COLORS="\$(vivid generate ${COLOR_THEME})"
fi
SH

fi
