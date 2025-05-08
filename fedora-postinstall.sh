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

SCRIPT_PATH=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

source "common/gum-setup.sh"
source "common/gum-functions.sh"

FEDORA_VERSION=$(rpm -E %fedora)

chapter "Paulo's Fedora ${FEDORA_VERSION} post installation script"

description "Fedora Linux is a free and open-source operating system \
sponsored by Red Hat, focused on innovation, security, and community \
collaboration. It provides a stable, cutting-edge platform for \
developers, enthusiasts, and users seeking a modern, reliable Linux \
distribution."

echo

if [ -z "${CLI_TOOLS_ONLY+x}" ]; then

    question "Did you upgrade your system?" || exit 1

    source "common/flatpaks-to-install.sh"
    source "common/fonts-to-install.sh"

    text "Welcome to my post installation script for Fedora! \
    Please select which flavour of Fedora you are currently running."

    FEDORA_FLAVOUR=$(${GUM} choose "Workstation" "Silverblue")

    text "You are running Fedora ${FEDORA_FLAVOUR} ${FEDORA_VERSION}. Let's go!"

    [[ "${FEDORA_FLAVOUR}" = "Workstation" ]] && source "workstation/post-installation.sh"
    [[ "${FEDORA_FLAVOUR}" = "Silverblue" ]] && source "silverblue/post-installation.sh"
else

text "Welcome to my post installation script for Fedora! It appears you have \
chosen to skip the flavour selection. The script will now proceed directly \
to the installation of additional command line tools."
fi

source "extras/additional-tools.sh"

text "That's all, folks!"
