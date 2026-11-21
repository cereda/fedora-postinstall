#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "SDKman installation and configuration"

description "Install and configure SDKMAN."
echo

if question "Do you want to install and configure SDKman?"; then

    # Prevent SDKman from modifying shell startup files.
    info "Installing the SDKman binary."
    export SDKMAN_DIR="${ROOT_DIRECTORY_STRUCTURE}/applications/sdkman" && curl -s "https://get.sdkman.io?rcupdate=false" | bash

    info "Creating wrapper script."
    # Resolve managed paths now; escaped values remain runtime shell expressions.
    cat >"${ROOT_DIRECTORY_STRUCTURE}/scripts/sdk.sh" <<SH
# moving these lines to a single file to source it on demand
export SDKMAN_DIR="${ROOT_DIRECTORY_STRUCTURE}/applications/sdkman"
[[ -s "${ROOT_DIRECTORY_STRUCTURE}/applications/sdkman/bin/sdkman-init.sh" ]] && source "${ROOT_DIRECTORY_STRUCTURE}/applications/sdkman/bin/sdkman-init.sh"
SH

fi
