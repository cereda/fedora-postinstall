#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

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
    runtime_capture_output COLOR_THEME "${GUM}" choose --height 15 --selected='dracula' "${COLOR_THEMES[@]}" || return 1

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
