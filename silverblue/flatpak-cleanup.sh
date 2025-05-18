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

section "Flatpak cleanup"

text "Fedora Silverblue comes with several applications installed \
as flatpaks. Would you like to remove some of them?"

echo

# collect all installed flatpaks into a a new array
mapfile -t INSTALLED_FLATPAKS < <(flatpak list --app --columns=application)

# display a list of installed flatpaks and collect the selected entries
# into a new array
readarray -t FLATPAKS_TO_REMOVE <<< $(${GUM} choose --no-limit --height 15 "${INSTALLED_FLATPAKS[@]}")

# no items were selected in the list based on the -z check -- a test operator
# that checks if a string is null
if [ -z "${FLATPAKS_TO_REMOVE}" ]; then

    # display a message to the user
    text "You haven't selected any items from the list. Moving on."
else

    # at least one item was selected in the list (variable is not null),
    # so the script can remove the chosen package(s)

    text "You've selected ${#FLATPAKS_TO_REMOVE[@]} flatpak(s) to remove. Please wait."

    # iterate through all the items in the list, display a message and remove
    # each flatpak

    for FLATPAK_TO_REMOVE in "${FLATPAKS_TO_REMOVE[@]}"; do

        # display message and remove flatpak
        info "Removing ${FLATPAK_TO_REMOVE}."
        flatpak uninstall "${FLATPAK_TO_REMOVE}" -y
    done

    # cleanup unused frameworks

    info "Removing unused framework(s)."
    flatpak uninstall --unused -y
fi
