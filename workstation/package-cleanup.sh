#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Package cleanup"

ui_text "Fedora Workstation includes applications you may want to remove."
ui_warning "Removing components may also remove software that depends on them."

runtime_capture_output PACKAGES_REMOVAL_SELECTION \
    ui_choose_many "Select components to remove" "" "${EXISTING_PACKAGES[@]}" || return $?
readarray -t PACKAGES_TO_REMOVE <<<"${PACKAGES_REMOVAL_SELECTION}"

if [ -z "${PACKAGES_TO_REMOVE}" ]; then

    ui_skip "No components selected for removal."
else

    PACKAGE_REMOVAL_LIST=$(printf " %s" "${PACKAGES_TO_REMOVE[@]}")
    PACKAGE_REMOVAL_LIST="${PACKAGE_REMOVAL_LIST:1}"

    ui_step "Removing the selected components."
    sudo dnf remove ${PACKAGE_REMOVAL_LIST} -y

    ui_step "Removing orphaned dependencies."
    sudo dnf autoremove -y

    ui_success "Selected components and orphaned dependencies removed."
fi
