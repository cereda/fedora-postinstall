#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

PACKAGE_INSTALL_LIST="No packages provided. This is a clean toolbox."

section "Useful packages"

description "Install selected packages inside the toolbox."
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

        echo

        if question "Should I install them now? It's advisable to do this later."; then

            info "Installing packages inside the ${TOOLBOX_NAME} toolbox."
            toolbox --container "${TOOLBOX_NAME}" run sudo dnf install ${PACKAGE_INSTALL_LIST}
        fi
    fi
fi

info "Adding package list to helper function (for reproducibility)."
sed -i "s/TOOLBOX_INSTALLATION_LIST/${PACKAGE_INSTALL_LIST}/" "${ROOT_DIRECTORY_STRUCTURE}/scripts/aliases.sh"
