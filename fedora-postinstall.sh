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

SCRIPT_PATH=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd -P)
cd "${SCRIPT_PATH}" || exit 1

# Centralize runtime state, cleanup, logging, and module execution.
source "common/runtime.sh" || exit 1
runtime_initialize || exit 1
source "common/gum-functions.sh" || exit 1
source "common/validation.sh" || exit 1
source "common/dependencies.sh" || exit 1

require_runtime_dependencies || exit 1

# 'gum' is required, so in case it's not available, the script will download
# a fixed version from GitHub
source "common/gum-setup.sh" || exit 1

# get the current version of Fedora by expanding the '%fedora' macro, which
# returns an integer
FEDORA_VERSION=$(rpm -E %fedora)

if ! [[ "${FEDORA_VERSION}" =~ ^[0-9]{1,3}$ ]]; then
    text "Unable to determine a valid Fedora version from RPM (${FEDORA_VERSION})."
    exit 1
fi

chapter "Paulo's Fedora ${FEDORA_VERSION} post installation script"

description "Fedora Linux is a free and open source operating system \
sponsored by Red Hat, focused on innovation, security, and community \
collaboration. It provides a stable, cutting-edge platform for \
developers, enthusiasts, and users seeking a modern, reliable Linux \
distribution."

echo

# check for a special environment variable which will skip the entire post
# installation and move directly to the additional command line tools
if [ -z "${CLI_TOOLS_ONLY+x}" ]; then

    # no special variable found, proceed to the post installation

    # it's important to ugrade your system prior to running this script; 
    # however, Workstation users could get rid of certain packages first
    # in order to save several MB in updates
    question "Did you upgrade your system?" || exit 1

    # load the list of suggested flatpaks and fonts to install -- since
    # these settings are common to both flavours of Fedora, they are
    # loaded at this stage
    runtime_run_module "common/flatpaks-to-install.sh" read-only
    runtime_run_module "common/fonts-to-install.sh" read-only

    text "Welcome to my post installation script for Fedora! \
Please select which flavour of Fedora you are currently running."

    echo

    if ! runtime_capture_output FEDORA_FLAVOUR "${GUM}" choose "Workstation" "Silverblue"; then
        text "Unable to read the Fedora flavour selection. Aborting."
        exit 1
    fi

    # a flavour must be selected explicitly; guessing Workstation could apply
    # the wrong package and system operations on Silverblue
    if [ -z "${FEDORA_FLAVOUR}" ]; then
        text "No Fedora flavour was selected. Aborting to avoid applying the wrong configuration."
        exit 1
    fi

    text "You are running Fedora ${FEDORA_FLAVOUR} ${FEDORA_VERSION}. Let's go!"

    # load the corresponding post installation script based the flavour of
    # Fedora; note to self: in the future, make this check automatic so the
    # script will already know about the underlying operating system
    POSTINSTALL_STATE_NAMESPACE=$(printf '%s' "${FEDORA_FLAVOUR}" | tr '[:upper:]' '[:lower:]')
    case "${FEDORA_FLAVOUR}" in
        Workstation)
            runtime_run_module "workstation/post-installation.sh" orchestrator
            ;;
        Silverblue)
            runtime_run_module "silverblue/post-installation.sh" orchestrator
            ;;
        *)
            text "Invalid Fedora flavour '${FEDORA_FLAVOUR}'. Aborting."
            exit 1
            ;;
    esac
else

    # special environment variable found, so the entire post installation
    # is skipped; print a message to indicate this to the user

    text "Welcome to my post installation script for Fedora! It appears you \
have chosen to skip the flavour selection. The script will now proceed \
directly to the installation of additional command line tools."
fi

# load the script for installing the additional command line tools; it should
# not have any dependencies on the post installation settings
POSTINSTALL_STATE_NAMESPACE="extras"
runtime_run_module "extras/additional-tools.sh"

echo

# end of script, we did it!
text "That's all, folks! Have fun with Fedora!"
