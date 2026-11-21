#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "carapace-bin installation"

description "Generate shell completions for command-line tools."
echo

if question "Do you want to install carapace-bin?"; then

    info "Getting latest version of carapace-bin from GitHub."
    test -f carapace.json || wget -q -O carapace.json https://api.github.com/repos/carapace-sh/carapace-bin/releases/latest

    info "Downloading carapace-bin from GitHub."
    case "$(runtime_selected_architecture)" in
    x86_64) CARAPACE_ASSET_SUFFIX="linux_amd64.tar.gz" ;;
    aarch64) CARAPACE_ASSET_SUFFIX="linux_arm64.tar.gz" ;;
    *)
        text "Unsupported architecture for carapace-bin: $(runtime_selected_architecture)."
        return 1
        ;;
    esac
    CARAPACE_ASSET_URL=$(runtime_select_github_asset_by_suffix \
        carapace.json "${CARAPACE_ASSET_SUFFIX}") || return 1
    wget -q "${CARAPACE_ASSET_URL}" -O carapace-bin.tar.gz

    info "Extracting carapace-bin."
    tar xzf carapace-bin.tar.gz

    info "Preparing the installation directory."
    mkdir -p "${HOME}/.local/bin"

    info "Moving binary to the installation directory."
    mv carapace "${HOME}/.local/bin/"

    info "Removing archive file."
    rm -f carapace-bin.tar.gz
fi
