#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Useful packages"

ui_description "Install selected system packages."

if ui_confirm "Select system packages to install?" "Select packages" "Skip"; then

    runtime_capture_output PACKAGES_SELECTION \
        ui_choose_many "Select packages to install" "" "${PACKAGES_TO_INSTALL[@]}" || return $?
    readarray -t SELECTED_PACKAGES <<<"${PACKAGES_SELECTION}"

    if [ "${#SELECTED_PACKAGES[@]}" -eq 0 ] ||
        [ -z "${SELECTED_PACKAGES[0]:-}" ]; then
        ui_skip "No packages selected for installation."
        return 0
    fi

    ui_text "Selected packages: ${SELECTED_PACKAGES[*]}"
    ui_step "Installing the selected packages."
    sudo dnf install "${SELECTED_PACKAGES[@]}" -y || return $?
    ui_success "Selected packages installed."
else
    ui_skip "No packages were installed."
fi

return 0
