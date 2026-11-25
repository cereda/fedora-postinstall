#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "mise installation"

ui_description "Install and configure mise."

if ui_confirm "Install mise?" "Install" "Skip"; then

    ui_step "Resolving the latest mise release."
    test -f mise.json || wget -q -O mise.json https://api.github.com/repos/jdx/mise/releases/latest

    ui_step "Downloading mise."
    case "$(runtime_selected_architecture)" in
    x86_64) MISE_ASSET_SUFFIX="linux-x64.tar.gz" ;;
    aarch64) MISE_ASSET_SUFFIX="linux-arm64.tar.gz" ;;
    *)
        ui_error "Unsupported architecture for mise: $(runtime_selected_architecture)."
        return 1
        ;;
    esac
    MISE_ASSET_URL=$(runtime_select_github_asset_by_suffix \
        mise.json "${MISE_ASSET_SUFFIX}") || return 1
    wget -q "${MISE_ASSET_URL}" -O mise.tar.gz

    ui_step "Extracting mise."
    tar xzf mise.tar.gz

    ui_step "Installing mise and preparing its data and configuration directories."
    mkdir -p "${HOME}/.local/bin"
    mv mise/bin/mise "${HOME}/.local/bin/"
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/data/mise"
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/config/mise"

    rm -f mise.tar.gz
else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "mise was not installed."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
