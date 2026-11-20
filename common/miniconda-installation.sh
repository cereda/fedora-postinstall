#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Miniconda installation"

description "Miniconda is a lightweight distribution of the Anaconda Python \
and R data science platform. It includes the Conda package manager and \
Python, allowing users to create and manage virtual environments for \
different projects and dependencies."

echo

question "Do you want to install Miniconda?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    MINICONDA_INSTALLATION_DIRECTORY="${ROOT_DIRECTORY_STRUCTURE}/applications/miniconda/3"

    info "Creating installation directory."
    mkdir -p "${MINICONDA_INSTALLATION_DIRECTORY}"

    info "Downloading Miniconda."
    case "$(runtime_selected_architecture)" in
    x86_64) MINICONDA_ARCHITECTURE="x86_64" ;;
    aarch64) MINICONDA_ARCHITECTURE="aarch64" ;;
    *)
        text "Unsupported architecture for Miniconda: $(runtime_selected_architecture)."
        return 1
        ;;
    esac
    wget -q \
        "https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-${MINICONDA_ARCHITECTURE}.sh" \
        -O miniconda-linux.sh

    # Miniconda has its own installation script, run it with the
    # following flags (as described in the documentation):
    #
    # -b: run install in batch mode
    # -u: update an existing installation
    # -p: install prefix
    info "Installing Miniconda."
    bash miniconda-linux.sh -b -u -p "${MINICONDA_INSTALLATION_DIRECTORY}"

    info "Removing installer file."
    rm -f miniconda-linux.sh
fi
