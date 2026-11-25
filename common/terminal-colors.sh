#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Color configuration for the terminal"

ui_description "Configure terminal colors."

if ui_confirm "Apply a color theme to the terminal?" "Apply" "Keep"; then

    # Generate the available themes with: vivid themes
    runtime_capture_output COLOR_THEME \
        ui_choose_one "Select a terminal color theme" \
        --height 15 --selected='dracula' "${COLOR_THEMES[@]}" || return $?

    if [ -z "${COLOR_THEME}" ]; then
        COLOR_THEME="dracula"
    fi

    ui_step "Generating the terminal color configuration."
    # Resolve the selected theme when the script is generated.
    cat >"${ROOT_DIRECTORY_STRUCTURE}/scripts/colors.sh" <<SH
if [ -x "\$(command -v vivid)" ]; then
    export LS_COLORS="\$(vivid generate ${COLOR_THEME})"
fi
SH

else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "The terminal color theme was left unchanged."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
