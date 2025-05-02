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

text "Fedora Workstation comes with several applications that could be \
removed. Would you like to remove some of them?"

readarray -t PACKAGES_TO_REMOVE <<< $(${GUM} choose --no-limit --height 15 "${EXISTING_PACKAGES[@]}")

if [ -z "${PACKAGES_TO_REMOVE}" ]; then

    text "You haven't selected any items from the list. Moving on."
else
    text "You've selected ${#PACKAGES_TO_REMOVE[@]} package(s) to remove. Please wait."

    PACKAGE_REMOVAL_LIST=$(printf " %s" "${PACKAGES_TO_REMOVE[@]}")

    info "Removing package(s)."
    sudo dnf remove ${PACKAGE_REMOVAL_LIST:1} -y

    info "Cleaning up orphan packages."
    sudo dnf autoremove -y
fi
