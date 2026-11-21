#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Useful packages"

description "Install selected system packages."
echo

if question "Do you want to install some useful packages?"; then

    text "Select which packages you want to install."

    echo

    runtime_capture_output PACKAGES_SELECTION "${GUM}" choose --no-limit --height 15 "${PACKAGES_TO_INSTALL[@]}" || return 1
    readarray -t SELECTED_PACKAGES <<<"${PACKAGES_SELECTION}"

    if [ -z "${SELECTED_PACKAGES}" ]; then

        text "You haven't selected any items from the list. Moving on."
    else

        text "You've selected ${#SELECTED_PACKAGES[@]} package(s) to install. Please wait."

        PACKAGE_INSTALL_LIST=$(printf " %s" "${SELECTED_PACKAGES[@]}")
        PACKAGE_INSTALL_LIST="${PACKAGE_INSTALL_LIST:1}"

        info "Installing packages."
        sudo dnf install ${PACKAGE_INSTALL_LIST} -y
    fi
fi
