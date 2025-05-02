#!/usr/bin/env bash

# MIT License
# 
# Copyright (c) 2025, Paulo Cereda
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

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
