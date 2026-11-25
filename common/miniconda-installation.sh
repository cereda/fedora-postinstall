#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Miniconda installation"

ui_description "Install and configure Miniconda."

if ui_confirm "Install Miniconda?" "Install" "Skip"; then

    MINICONDA_INSTALLATION_DIRECTORY="${ROOT_DIRECTORY_STRUCTURE}/applications/miniconda/3"

    mkdir -p "${MINICONDA_INSTALLATION_DIRECTORY}"

    ui_step "Downloading Miniconda."
    case "$(runtime_selected_architecture)" in
    x86_64) MINICONDA_ARCHITECTURE="x86_64" ;;
    aarch64) MINICONDA_ARCHITECTURE="aarch64" ;;
    *)
        ui_error "Unsupported architecture for Miniconda: $(runtime_selected_architecture)."
        return 1
        ;;
    esac
    wget -q \
        "https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-${MINICONDA_ARCHITECTURE}.sh" \
        -O miniconda-linux.sh

    # Install in batch mode and update an existing managed installation.
    ui_step "Installing Miniconda."
    bash miniconda-linux.sh -b -u -p "${MINICONDA_INSTALLATION_DIRECTORY}"

    rm -f miniconda-linux.sh
else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "Miniconda was not installed."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
