#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Helix installation and configuration"

ui_description "Install and configure the Helix editor."

if ui_confirm "Install and configure Helix?" "Install" "Skip"; then

    ui_step "Resolving the latest Helix release."
    test -f helix-editor.json || wget -q -O helix-editor.json https://api.github.com/repos/helix-editor/helix/releases/latest

    ui_step "Downloading Helix."
    case "$(runtime_selected_architecture)" in
    x86_64) HELIX_ASSET_SUFFIX="x86_64-linux.tar.xz" ;;
    aarch64) HELIX_ASSET_SUFFIX="aarch64-linux.tar.xz" ;;
    *)
        ui_error "Unsupported architecture for Helix: $(runtime_selected_architecture)."
        return 1
        ;;
    esac
    HELIX_ASSET_URL=$(runtime_select_github_asset_by_suffix \
        helix-editor.json "${HELIX_ASSET_SUFFIX}") || return 1
    wget -q "${HELIX_ASSET_URL}" -O helix.tar.xz

    ui_step "Extracting Helix."
    rm -rf helix-temp
    mkdir -p helix-temp
    tar xJf helix.tar.xz -C helix-temp
    HELIX_SOURCE_DIRECTORY=$(find helix-temp -mindepth 1 -maxdepth 1 -type d -print -quit)
    if [ -z "${HELIX_SOURCE_DIRECTORY}" ]; then
        ui_error "The Helix archive does not contain an application directory."
        return 1
    fi

    ui_step "Installing Helix."
    rm -rf helix-editor
    mv "${HELIX_SOURCE_DIRECTORY}" helix-editor
    mv "helix-editor" "${ROOT_DIRECTORY_STRUCTURE}/applications/"

    ui_step "Configuring Helix."
    mkdir -p "${HOME}/.config/helix"
    cat >"${HOME}/.config/helix/config.toml" <<'TOML'
theme = "onedark"

[editor]
line-number = "relative"
cursorline = true

[editor.cursor-shape]
insert = "bar"
normal = "block"
select = "underline"

[editor.file-picker]
hidden = false

[editor.indent-guides]
render = true

[keys.normal]
F1 = ":set whitespace.render none"
F2 = ":set whitespace.render all"
F3 = ":w"
F4 = ":wq"
F5 = ":q!"

[editor.soft-wrap]
enable = true
TOML

    ui_step "Adding Helix to the command path."
    mkdir -p "${HOME}/.local/bin"
    ln -s "${ROOT_DIRECTORY_STRUCTURE}/applications/helix-editor/hx" "${HOME}/.local/bin/hx"

    ui_warning "If you do not plan to use Vim or Neovim, consider aliases that point to Helix, such as alias vim='hx'."

    rm -rf helix-temp helix.tar.xz

else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "Helix was not installed."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
