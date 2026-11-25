#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Zed installation and configuration"

ui_description "Install and configure the Zed editor."

if ui_confirm "Install and configure Zed?" "Install" "Skip"; then

    ui_step "Resolving the latest Zed release."
    test -f zed-editor.json || wget -q -O zed-editor.json https://api.github.com/repos/zed-industries/zed/releases/latest

    ui_step "Downloading Zed."
    case "$(runtime_selected_architecture)" in
    x86_64) ZED_ASSET_SUFFIX="zed-linux-x86_64.tar.gz" ;;
    aarch64) ZED_ASSET_SUFFIX="zed-linux-aarch64.tar.gz" ;;
    *)
        ui_error "Unsupported architecture for Zed: $(runtime_selected_architecture)."
        return 1
        ;;
    esac
    ZED_ASSET_URL=$(runtime_select_github_asset_by_suffix \
        zed-editor.json "${ZED_ASSET_SUFFIX}") || return 1
    wget -q "${ZED_ASSET_URL}" -O zed.tar.gz

    ui_step "Extracting Zed."
    tar xzf zed.tar.gz

    ui_step "Installing Zed."
    mv zed.app "${ROOT_DIRECTORY_STRUCTURE}/applications/"

    ui_step "Configuring Zed."
    mkdir -p "${HOME}/.config/zed"
    cat >"${HOME}/.config/zed/settings.json" <<'JSON'
{
    "telemetry": {
        "metrics": false,
        "diagnostics": false
    },
    "ui_font_size": 16,
    "buffer_font_size": 17,
    "theme": {
        "mode": "system",
        "light": "One Light",
        "dark": "One Dark"
    },
    "autosave": "off",
    "restore_on_startup": "none",
    "buffer_font_family": "Cascadia Code",
    "buffer_font_features": {
        "calt": true
    },
    "confirm_quit": false,
    "indent_guides": {
        "enabled": true
    },
    "show_whitespaces": "selection",
    "soft_wrap": "none"
}
JSON

    ui_step "Creating a desktop shortcut for Zed."
    mkdir -p "${HOME}/.local/share/applications"
    # Resolve the installed application path in the desktop entry.
    cat >"${HOME}/.local/share/applications/zed.desktop" <<DESKTOP
[Desktop Entry]
Version=1.0
Type=Application
Name=Zed
GenericName=Text Editor
Comment=A high-performance, multiplayer code editor.
TryExec=${ROOT_DIRECTORY_STRUCTURE}/applications/zed.app/bin/zed
StartupNotify=true
Exec=${ROOT_DIRECTORY_STRUCTURE}/applications/zed.app/bin/zed %U
Icon=${ROOT_DIRECTORY_STRUCTURE}/applications/zed.app/share/icons/hicolor/512x512/apps/zed.png
Categories=Utility;TextEditor;Development;IDE;
Keywords=zed;
MimeType=text/plain;application/x-zerosize;x-scheme-handler/zed;
Actions=NewWorkspace;

[Desktop Action NewWorkspace]
Exec=${ROOT_DIRECTORY_STRUCTURE}/applications/zed.app/bin/zed --new %U
Name=Open a new workspace
DESKTOP

    rm -f zed.tar.gz zed-linux-x86_64.tar.gz zed-linux-aarch64.tar.gz

else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "Zed was not installed."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
