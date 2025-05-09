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

section "Homebrew installation and configuration"

description "Homebrew is a free and open-source package manager for macOS \
and Linux. It simplifies the installation and management of software on \
these operating systems by automating the process of downloading, compiling, \
and installing various applications and libraries."

echo

question "Do you want to install Homebrew?"

if [ $? = 0 ]; then

    info "Installing Homebrew."
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    TOOLBOX_HOMEBREW_NAME=$(${GUM} input --prompt "Your Homebrew container name: " --value "f${FEDORA_VERSION}-homebrew")

    info "Creating and configuring the Homebrew container."
    toolbox create ${TOOLBOX_HOMEBREW_NAME}

    question "Homebrew requires the development tools group. Do you want to install them now?"

    if [ $? = 0 ]; then

        info "Installing the development tools group."
        toolbox --container ${TOOLBOX_HOMEBREW_NAME} run sudo dnf group install development-tools
    else

        text "Please run 'sudo dnf group install development-tools' inside the Homebrew container."
    fi

    question "Should Homebrew be available outside a toolbox environment?"

    if [ $? = 0 ]; then

        info "Creating Homebrew configuration file (global availability)."
        tee "${ROOT_DIRECTORY_STRUCTURE}/scripts/homebrew.sh" <<EOF
# check if inside a toolbox container
if [[ -f /run/.containerenv && -f /run/.toolboxenv ]]; then

    # reference to the Homebrew installation
    # directory does not exist
    if [[ ! -d /home/linuxbrew ]]; then

        # create directory
		sudo mkdir -p /home/linuxbrew
	fi

    # mount point for Homebrew does not exist
    if [[ ! \$(mount | grep linuxbrew) ]]; then

        # mount point binding to the existing Homebrew
        # directory in the host system
		sudo mount --bind /run/host/var/home/linuxbrew /home/linuxbrew
	fi
fi

# disable environment hints
export HOMEBREW_NO_ENV_HINTS=1

# source the Homebrew configuration
eval "\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
EOF

    else

        info "Creating Homebrew configuration file (local availability)."
        tee "${ROOT_DIRECTORY_STRUCTURE}/scripts/homebrew.sh" <<EOF
# check if inside a toolbox container
if [[ -f /run/.containerenv && -f /run/.toolboxenv ]]; then

    # reference to the Homebrew installation
    # directory does not exist
    if [[ ! -d /home/linuxbrew ]]; then

        # create directory
		sudo mkdir -p /home/linuxbrew
	fi

    # mount point for Homebrew does not exist
    if [[ ! \$(mount | grep linuxbrew) ]]; then

        # mount point binding to the existing Homebrew
        # directory in the host system
		sudo mount --bind /run/host/var/home/linuxbrew /home/linuxbrew
	fi

    # disable environment hints
    export HOMEBREW_NO_ENV_HINTS=1

    # source the Homebrew configuration
    eval "\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi
EOF

    fi
fi
