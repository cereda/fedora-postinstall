#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Zoxide installation"

ui_description "Install and configure Zoxide."

if ui_confirm "Install Zoxide?" "Install" "Skip"; then

    ui_step "Resolving the latest Zoxide release."
    test -f zoxide.json || wget -q -O zoxide.json https://api.github.com/repos/ajeetdsouza/zoxide/releases/latest

    ui_step "Downloading Zoxide."
    case "$(runtime_selected_architecture)" in
    x86_64) ZOXIDE_ASSET_SUFFIX="x86_64-unknown-linux-musl.tar.gz" ;;
    aarch64) ZOXIDE_ASSET_SUFFIX="aarch64-unknown-linux-musl.tar.gz" ;;
    *)
        ui_error "Unsupported architecture for Zoxide: $(runtime_selected_architecture)."
        return 1
        ;;
    esac
    ZOXIDE_ASSET_URL=$(runtime_select_github_asset_by_suffix \
        zoxide.json "${ZOXIDE_ASSET_SUFFIX}") || return 1
    wget -q "${ZOXIDE_ASSET_URL}" -O zoxide.tar.gz

    ui_step "Extracting Zoxide."
    mkdir -p zoxide-temp
    tar xzf zoxide.tar.gz -C zoxide-temp

    ui_step "Installing Zoxide and preparing its data directory."
    mkdir -p "${HOME}/.local/bin"
    mv zoxide-temp/zoxide "${HOME}/.local/bin/"
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/data/zoxide"

    rm -f zoxide.tar.gz
else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "Zoxide was not installed."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
