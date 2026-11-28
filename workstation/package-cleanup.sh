#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Package cleanup"

ui_text "Fedora Workstation includes applications you may want to remove."
ui_warning "Removing components may also remove software that depends on them."

runtime_capture_output PACKAGES_REMOVAL_SELECTION \
    ui_choose_many "Select components to remove" "" "${EXISTING_PACKAGES[@]}" || return $?
readarray -t PACKAGES_TO_REMOVE <<<"${PACKAGES_REMOVAL_SELECTION}"

if [ "${#PACKAGES_TO_REMOVE[@]}" -eq 0 ] ||
    [ -z "${PACKAGES_TO_REMOVE[0]:-}" ]; then
    ui_skip "No components selected for removal."
    return 0
fi

ui_text "Selected components: ${PACKAGES_TO_REMOVE[*]}"

ui_step "Removing the selected components."
sudo dnf remove "${PACKAGES_TO_REMOVE[@]}" -y || return $?

ui_step "Removing orphaned dependencies."
sudo dnf autoremove -y || return $?

ui_success "Selected components and orphaned dependencies removed."
return 0
