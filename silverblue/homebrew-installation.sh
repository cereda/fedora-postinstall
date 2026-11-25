#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Homebrew installation and configuration"

ui_description "Install Homebrew and configure its Fedora toolbox."

if ui_confirm "Install Homebrew?" "Install" "Skip"; then

    ui_step "Installing Homebrew."
    runtime_capture_output INSTALLER_SCRIPT curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh || return $?
    bash -c "${INSTALLER_SCRIPT}"

    if TOOLBOX_HOMEBREW_NAME=$(prompt_valid_container_name "Your Homebrew toolbox container name: " "f${FEDORA_VERSION}-homebrew"); then
        TOOLBOX_HOMEBREW_NAME_STATUS=0
    else
        TOOLBOX_HOMEBREW_NAME_STATUS="${?}"
    fi
    if [ "${TOOLBOX_HOMEBREW_NAME_STATUS}" -ne 0 ]; then
        return "${TOOLBOX_HOMEBREW_NAME_STATUS}"
    fi

    ui_step "Creating the Homebrew toolbox."
    toolbox create "${TOOLBOX_HOMEBREW_NAME}"

    ui_text "Homebrew requires the development tools group."
    if ui_confirm "Install the development tools group in the Homebrew toolbox?" \
        "Install tools" "Skip"; then

        ui_step "Installing the development tools group."
        toolbox --container "${TOOLBOX_HOMEBREW_NAME}" run sudo dnf group install development-tools
        ui_success "The development tools group is installed."
    else

        ui_skip "The development tools group was not installed."
        ui_text "Run 'sudo dnf group install development-tools' inside the Homebrew toolbox."
    fi

    ui_text "Global availability mounts the host's /home/linuxbrew into toolbox containers."
    if ui_confirm "Make Homebrew available outside the toolbox?" \
        "Make global" "Keep scoped"; then

        # Expose Homebrew outside toolbox containers. The development toolchain
        # remains scoped to the toolbox unless it is installed on the host.

        ui_step "Writing the global Homebrew configuration."
        cat >"${ROOT_DIRECTORY_STRUCTURE}/scripts/homebrew.sh" <<'SH'
# check if inside a toolbox container
if [[ -f /run/.containerenv && -f /run/.toolboxenv ]]; then

    # reference to the Homebrew installation
    # directory does not exist
    if [[ ! -d /home/linuxbrew ]]; then

        # create directory
        sudo mkdir -p /home/linuxbrew
    fi

    # mount point for Homebrew does not exist
    if [[ ! $(mount | grep linuxbrew) ]]; then

        # mount point binding to the existing Homebrew
        # directory in the host system
        sudo mount --bind /run/host/var/home/linuxbrew /home/linuxbrew
    fi
fi

# disable environment hints
export HOMEBREW_NO_ENV_HINTS=1

# source the Homebrew configuration
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
SH

        ui_success "Homebrew is available globally."
    else

        # Keep Homebrew and its tools scoped to the toolbox container.

        ui_step "Writing the toolbox-scoped Homebrew configuration."
        cat >"${ROOT_DIRECTORY_STRUCTURE}/scripts/homebrew.sh" <<'SH'
# check if inside a toolbox container
if [[ -f /run/.containerenv && -f /run/.toolboxenv ]]; then

    # reference to the Homebrew installation
    # directory does not exist
    if [[ ! -d /home/linuxbrew ]]; then

        # create directory
        sudo mkdir -p /home/linuxbrew
    fi

    # mount point for Homebrew does not exist
    if [[ ! $(mount | grep linuxbrew) ]]; then

        # mount point binding to the existing Homebrew
        # directory in the host system
        sudo mount --bind /run/host/var/home/linuxbrew /home/linuxbrew
    fi

    # disable environment hints
    export HOMEBREW_NO_ENV_HINTS=1

    # source the Homebrew configuration
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi
SH

        ui_success "Homebrew is scoped to the toolbox."
    fi
else
    ui_skip "Homebrew was not installed."
fi
