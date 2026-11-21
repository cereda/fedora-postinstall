#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Package cleanup"

text "Fedora Workstation comes with several packages that could be removed. \
Would you like to remove some of them?"

echo

runtime_capture_output PACKAGES_REMOVAL_SELECTION "${GUM}" choose --no-limit --height 15 "${EXISTING_PACKAGES[@]}" || return 1
readarray -t PACKAGES_TO_REMOVE <<<"${PACKAGES_REMOVAL_SELECTION}"

if [ -z "${PACKAGES_TO_REMOVE}" ]; then

    text "You haven't selected any items from the list. Moving on."
else

    text "You've selected ${#PACKAGES_TO_REMOVE[@]} package(s) to remove. Please wait."

    PACKAGE_REMOVAL_LIST=$(printf " %s" "${PACKAGES_TO_REMOVE[@]}")
    PACKAGE_REMOVAL_LIST="${PACKAGE_REMOVAL_LIST:1}"

    info "Removing package(s)."
    sudo dnf remove ${PACKAGE_REMOVAL_LIST} -y

    info "Cleaning up orphan packages."
    sudo dnf autoremove -y
fi
