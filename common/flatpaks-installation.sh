#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Flatpak applications"

description "Install and manage Flatpak applications."
echo

text "Do you want to install any of these Flatpak applications?"

echo

runtime_capture_output FLATPAKS_SELECTION "${GUM}" choose --no-limit --height 15 "${SUGGESTED_FLATPAKS[@]}" || return 1
readarray -t FLATPAKS_TO_INSTALL <<<"${FLATPAKS_SELECTION}"

if [ -z "${FLATPAKS_TO_INSTALL}" ]; then

    text "You haven't selected any items from the list. Moving on."
    FLATPAKS_KEEP_CACHE_LIST=""
else

    text "You've selected ${#FLATPAKS_TO_INSTALL[@]} flatpak(s) to install. Please wait."

    # Install the selected applications from Flathub.
    for FLATPAK_TO_INSTALL in "${FLATPAKS_TO_INSTALL[@]}"; do

        info "Installing ${FLATPAK_TO_INSTALL}."
        flatpak install flathub ${FLATPAK_TO_INSTALL} -y
    done

    echo

    text "Which Flatpak applications do you want to keep from cache cleaning?"

    echo

    runtime_capture_output FLATPAKS_CACHE_SELECTION "${GUM}" choose --no-limit --selected="com.github.tchx84.Flatseal" --height 15 "${FLATPAKS_TO_INSTALL[@]}" || return 1
    readarray -t FLATPAKS_TO_KEEP_CACHE <<<"${FLATPAKS_CACHE_SELECTION}"

    if [ -z "${FLATPAKS_TO_KEEP_CACHE}" ]; then

        FLATPAKS_KEEP_CACHE_LIST=""
    else

        # The cleanup module consumes this list as Flatpak exclusion filters.
        FLATPAKS_KEEP_CACHE_LIST=$(printf " -not -name %s" "${FLATPAKS_TO_KEEP_CACHE[@]}")
    fi
fi
