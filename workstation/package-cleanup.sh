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

section "Package cleanup"

text "Fedora Workstation comes with several packages that could be removed. \
Would you like to remove some of them?"

echo

# display a list of packages from the EXISTING_PACKAGES environment variable
# set previously (see [common/packages-to-remove.sh] for reference) and
# collect the selected entries into a new array
readarray -t PACKAGES_TO_REMOVE <<< $(${GUM} choose --no-limit --height 15 "${EXISTING_PACKAGES[@]}")

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
