#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "carapace installation"

ui_description "Generate shell completions for command-line tools."

if ui_confirm "Install carapace?" "Install" "Skip"; then

    ui_step "Resolving the latest carapace release."
    test -f carapace.json || wget -q -O carapace.json https://api.github.com/repos/carapace-sh/carapace-bin/releases/latest

    ui_step "Downloading carapace."
    case "$(runtime_selected_architecture)" in
    x86_64) CARAPACE_ASSET_SUFFIX="linux_amd64.tar.gz" ;;
    aarch64) CARAPACE_ASSET_SUFFIX="linux_arm64.tar.gz" ;;
    *)
        ui_error "Unsupported architecture for carapace: $(runtime_selected_architecture)."
        return 1
        ;;
    esac
    CARAPACE_ASSET_URL=$(runtime_select_github_asset_by_suffix \
        carapace.json "${CARAPACE_ASSET_SUFFIX}") || return 1
    wget -q "${CARAPACE_ASSET_URL}" -O carapace-bin.tar.gz

    ui_step "Extracting carapace."
    tar xzf carapace-bin.tar.gz

    ui_step "Installing carapace."
    mkdir -p "${HOME}/.local/bin"
    mv carapace "${HOME}/.local/bin/"

    rm -f carapace-bin.tar.gz
else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "carapace was not installed."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
