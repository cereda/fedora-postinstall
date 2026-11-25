#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Flatpak applications"

ui_description "Install and manage Flatpak applications."

runtime_capture_output FLATPAKS_SELECTION \
    ui_choose_many "Select Flatpak applications to install" "" "${SUGGESTED_FLATPAKS[@]}" || return $?
readarray -t FLATPAKS_TO_INSTALL <<<"${FLATPAKS_SELECTION}"

FLATPAKS_KEEP_CACHE_IDS_JSON="[]"
if [ -z "${FLATPAKS_TO_INSTALL}" ]; then

    ui_skip "No Flatpak applications were selected for installation."
else

    ui_text "Selected ${#FLATPAKS_TO_INSTALL[@]} Flatpak applications for installation."

    # Install the selected applications from Flathub.
    for FLATPAK_TO_INSTALL in "${FLATPAKS_TO_INSTALL[@]}"; do

        ui_step "Installing ${FLATPAK_TO_INSTALL}."
        FLATPAKS_INSTALL_STATUS=0
        flatpak install flathub "${FLATPAK_TO_INSTALL}" -y ||
            FLATPAKS_INSTALL_STATUS="${?}"
        if [ "${FLATPAKS_INSTALL_STATUS}" -ne 0 ]; then
            ui_error "Unable to install Flatpak application ${FLATPAK_TO_INSTALL}."
            return "${FLATPAKS_INSTALL_STATUS}"
        fi
    done

    runtime_capture_output FLATPAKS_CACHE_SELECTION \
        ui_choose_many "Retain application data and cache for the selected Flatpak applications" \
        "com.github.tchx84.Flatseal" "${FLATPAKS_TO_INSTALL[@]}" || return $?
    readarray -t FLATPAKS_TO_KEEP_CACHE <<<"${FLATPAKS_CACHE_SELECTION}"

    if [ -z "${FLATPAKS_TO_KEEP_CACHE}" ]; then

        ui_skip "No Flatpak application data or cache was selected for retention."
    else

        # Store the selected IDs as JSON so both populated and empty selections
        # can be restored safely by the resume machinery.
        FLATPAKS_KEEP_CACHE_IDS_JSON=$(
            flatpaks_keep_cache_state_from_ids "${FLATPAKS_TO_KEEP_CACHE[@]}"
        ) || return $?
    fi
fi

# The cleanup helpers consume this list as Flatpak exclusion filters.
flatpaks_keep_cache_filter_from_state "${FLATPAKS_KEEP_CACHE_IDS_JSON}" || return $?
