#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Package cleanup"

text "Fedora Workstation comes with several packages that could be removed. \
Would you like to remove some of them?"

echo

# display a list of packages from the EXISTING_PACKAGES environment variable
# set previously (see [common/packages-to-remove.sh] for reference) and
# collect the selected entries into a new array
runtime_capture_output PACKAGES_REMOVAL_SELECTION "${GUM}" choose --no-limit --height 15 "${EXISTING_PACKAGES[@]}" || return 1
readarray -t PACKAGES_TO_REMOVE <<<"${PACKAGES_REMOVAL_SELECTION}"

# no items were selected in the list based on the -z check -- a test operator
# that checks if a string is null
if [ -z "${PACKAGES_TO_REMOVE}" ]; then

    # display a message to the user
    text "You haven't selected any items from the list. Moving on."
else

    # at least one item was selected in the list (variable is not null),
    # so the script can remove the chosen package(s)

    text "You've selected ${#PACKAGES_TO_REMOVE[@]} package(s) to remove. Please wait."

    # join all items into a string using space as separator
    PACKAGE_REMOVAL_LIST=$(printf " %s" "${PACKAGES_TO_REMOVE[@]}")
    PACKAGE_REMOVAL_LIST="${PACKAGE_REMOVAL_LIST:1}"

    # remove packages + clean up orphans

    info "Removing package(s)."
    sudo dnf remove ${PACKAGE_REMOVAL_LIST} -y

    info "Cleaning up orphan packages."
    sudo dnf autoremove -y
fi
