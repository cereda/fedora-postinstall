#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Homebrew installation and configuration"

description "Install Homebrew in a Fedora toolbox."
echo

if question "Do you want to install Homebrew?"; then

    info "Installing Homebrew."
    runtime_capture_output INSTALLER_SCRIPT curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh || return 1
    bash -c "${INSTALLER_SCRIPT}"

    TOOLBOX_HOMEBREW_NAME=$(prompt_valid_container_name "Your Homebrew container name: " "f${FEDORA_VERSION}-homebrew")

    info "Creating and configuring the Homebrew container."
    toolbox create "${TOOLBOX_HOMEBREW_NAME}"

    echo

    if question "Homebrew requires the development tools group. Do you want to install them now?"; then

        info "Installing the development tools group."
        toolbox --container "${TOOLBOX_HOMEBREW_NAME}" run sudo dnf group install development-tools
    else

        text "Please run 'sudo dnf group install development-tools' inside the Homebrew container."
    fi

    echo

    if question "Should Homebrew be available outside a toolbox environment?"; then

        # Expose Homebrew outside toolbox containers. The development toolchain
        # remains scoped to the toolbox unless it is installed on the host.

        info "Creating Homebrew configuration file (global availability)."
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

    else

        # Keep Homebrew and its tools scoped to the toolbox container.

        info "Creating Homebrew configuration file (local availability)."
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

    fi
fi
