#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Flatpak cleanup"

ui_description "Select Fedora Silverblue applications to remove."
ui_warning "Removing applications also removes Flatpak runtimes that are no longer needed."

runtime_capture_output INSTALLED_FLATPAKS_OUTPUT \
    flatpak list --app --columns=application || return $?
INSTALLED_FLATPAKS=()
if [ -n "${INSTALLED_FLATPAKS_OUTPUT}" ]; then
    mapfile -t INSTALLED_FLATPAKS <<<"${INSTALLED_FLATPAKS_OUTPUT}"
fi

FLATPAKS_TO_REMOVE=()
if [ "${#INSTALLED_FLATPAKS[@]}" -gt 0 ]; then
    runtime_capture_output FLATPAKS_TO_REMOVE_SELECTION \
        ui_choose_many "Select applications to remove" "" \
        "${INSTALLED_FLATPAKS[@]}" || return $?
    if [ -n "${FLATPAKS_TO_REMOVE_SELECTION}" ]; then
        mapfile -t FLATPAKS_TO_REMOVE <<<"${FLATPAKS_TO_REMOVE_SELECTION}"
    fi
fi

if [ "${#FLATPAKS_TO_REMOVE[@]}" -eq 0 ]; then

    ui_skip "No applications selected for removal."
else

    ui_step "Removing the selected applications."
    for FLATPAK_TO_REMOVE in "${FLATPAKS_TO_REMOVE[@]}"; do
        flatpak uninstall "${FLATPAK_TO_REMOVE}" -y
    done

    # Remove runtimes that are no longer referenced by installed applications.
    ui_step "Removing unused Flatpak runtimes."
    flatpak uninstall --unused -y

    ui_success "Selected applications and unused runtimes removed."
fi
