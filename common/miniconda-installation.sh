#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Miniconda installation"

description "Install and configure Miniconda."
echo

if question "Do you want to install Miniconda?"; then

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

    # Install in batch mode and update an existing managed installation.
    info "Installing Miniconda."
    bash miniconda-linux.sh -b -u -p "${MINICONDA_INSTALLATION_DIRECTORY}"

    info "Removing installer file."
    rm -f miniconda-linux.sh
fi
