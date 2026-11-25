#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "SDKMAN installation and configuration"

ui_description "Install and configure SDKMAN."

if ui_confirm "Install and configure SDKMAN?" "Install" "Skip"; then

    # Prevent SDKMAN from modifying shell startup files.
    ui_step "Installing SDKMAN."
    export SDKMAN_DIR="${ROOT_DIRECTORY_STRUCTURE}/applications/sdkman" && curl -s "https://get.sdkman.io?rcupdate=false" | bash

    ui_step "Creating the SDKMAN helper script."
    # Resolve managed paths now; escaped values remain runtime shell expressions.
    cat >"${ROOT_DIRECTORY_STRUCTURE}/scripts/sdk.sh" <<SH
# moving these lines to a single file to source it on demand
export SDKMAN_DIR="${ROOT_DIRECTORY_STRUCTURE}/applications/sdkman"
[[ -s "${ROOT_DIRECTORY_STRUCTURE}/applications/sdkman/bin/sdkman-init.sh" ]] && source "${ROOT_DIRECTORY_STRUCTURE}/applications/sdkman/bin/sdkman-init.sh"
SH

else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "SDKMAN was not installed."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
