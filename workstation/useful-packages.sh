#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Useful packages"

ui_description "Install selected system packages."

if ui_confirm "Select system packages to install?" "Select packages" "Skip"; then

    runtime_capture_output PACKAGES_SELECTION \
        ui_choose_many "Select packages to install" "" "${PACKAGES_TO_INSTALL[@]}" || return $?
    readarray -t SELECTED_PACKAGES <<<"${PACKAGES_SELECTION}"

    if [ -z "${SELECTED_PACKAGES}" ]; then

        ui_skip "No packages selected for installation."
    else

        PACKAGE_INSTALL_LIST=$(printf " %s" "${SELECTED_PACKAGES[@]}")
        PACKAGE_INSTALL_LIST="${PACKAGE_INSTALL_LIST:1}"

        ui_step "Installing the selected packages."
        sudo dnf install ${PACKAGE_INSTALL_LIST} -y

        ui_success "Selected packages installed."
    fi
else
    ui_skip "No packages were installed."
fi
