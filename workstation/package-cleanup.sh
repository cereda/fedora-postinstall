#!/usr/bin/env bash

section "Package cleanup"

text "Fedora Workstation comes with several applications that could be \
removed. Would you like to remove some of them?"

readarray -t PACKAGES_TO_REMOVE <<< $(${GUM} choose --no-limit --height 15 "${EXISTING_PACKAGES[@]}")

if [ -z "${PACKAGES_TO_REMOVE}" ]; then

    text "You haven't selected any items from the list. Moving on."
else
    text "You've selected ${#PACKAGES_TO_REMOVE[@]} package(s) to remove. Please wait."

    PACKAGE_REMOVAL_LIST=$(printf " %s" "${PACKAGES_TO_REMOVE[@]}")

    info "Removing package(s)."
    sudo dnf remove ${PACKAGE_REMOVAL_LIST:1} -y

    info "Cleaning up orphan packages."
    sudo dnf autoremove -y
fi
