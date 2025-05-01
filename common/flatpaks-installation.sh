#!/usr/bin/env bash

section "Flatpak applications"

description "Flatpak is a package management system for Linux that allows \
applications to be packaged with their dependencies, enabling consistent \
and isolated software deployment across different Linux distributions."

echo

text "Do you want to install any of these Flatpak applications?"

readarray -t FLATPAKS_TO_INSTALL <<< $(${GUM} choose --no-limit --height 15 "${SUGGESTED_FLATPAKS[@]}")

if [ -z "${FLATPAKS_TO_INSTALL}" ]; then
    text "You haven't selected any items from the list. Moving on."
    FLATPAKS_KEEP_CACHE_LIST=""
else
    text "You've selected ${#FLATPAKS_TO_INSTALL[@]} flatpak(s) to install. Please wait."

    for FLATPAK_TO_INSTALL in "${FLATPAKS_TO_INSTALL[@]}"; do
        info "Installing ${FLATPAK_TO_INSTALL}."
        flatpak install flathub ${FLATPAK_TO_INSTALL} -y
    done

    text "Which Flatpak applications do you want to keep from cache cleaning?"

    readarray -t FLATPAKS_TO_KEEP_CACHE <<< $(${GUM} choose --no-limit --selected="com.github.tchx84.Flatseal" --height 15 "${FLATPAKS_TO_INSTALL[@]}")
    FLATPAKS_KEEP_CACHE_LIST=$(printf " -not -name %s" "${FLATPAKS_TO_KEEP_CACHE[@]}")    
fi
