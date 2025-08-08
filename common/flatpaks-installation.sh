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

echo

# display a list of suggested Flatpaks from the SUGGESTED_FLATPAKS environment
# variable set previously (see [common/flatpaks-to-install.sh] for reference)
# and collect the selected entries into a new array
readarray -t FLATPAKS_TO_INSTALL <<< $(${GUM} choose --no-limit --height 15 "${SUGGESTED_FLATPAKS[@]}")

# no items were selected in the list based on the -z check -- a test operator
# that checks if a string is null
if [ -z "${FLATPAKS_TO_INSTALL}" ]; then

    # display a message to the user and set the FLATPAKS_KEEP_CACHE_LIST
    # variable to be empty (i.e, no flatpaks will have their cache kept
    # during a system cleanup)

    text "You haven't selected any items from the list. Moving on."
    FLATPAKS_KEEP_CACHE_LIST=""
else

    # at least one item was selected in the list (variable is not null),
    # so the script can install the chosen flatpak(s)

    text "You've selected ${#FLATPAKS_TO_INSTALL[@]} flatpak(s) to install. Please wait."

    # iterate through all the items in the list, display a message and install
    # each flatpak with flathub as the repository; in the unlikely case that the
    # flatpak is also available in the fedora repository, make sure to always
    # select flathub

    for FLATPAK_TO_INSTALL in "${FLATPAKS_TO_INSTALL[@]}"; do

        # display message and install flatpak
        info "Installing ${FLATPAK_TO_INSTALL}."
        flatpak install flathub ${FLATPAK_TO_INSTALL} -y
    done

    echo

    text "Which Flatpak applications do you want to keep from cache cleaning?"

    echo

    # display a list of all installed flatpaks in the previous step and ask
    # which ones should keep cache during a system cleanup, collecting the
    # selected entries in a new array
    readarray -t FLATPAKS_TO_KEEP_CACHE <<< $(${GUM} choose --no-limit --selected="com.github.tchx84.Flatseal" --height 15 "${FLATPAKS_TO_INSTALL[@]}")

    # no items were selected in the list (-z check, null string)
    if [ -z "${FLATPAKS_TO_KEEP_CACHE}" ]; then

        # empty string
        FLATPAKS_KEEP_CACHE_LIST=""
    else

        # build a string in the format '-not -name <qualified flatpak ID>' for
        # each entry in the list; this variable will be used later on in the
        # system cleanup script
        FLATPAKS_KEEP_CACHE_LIST=$(printf " -not -name %s" "${FLATPAKS_TO_KEEP_CACHE[@]}")
    fi
fi
