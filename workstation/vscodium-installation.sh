#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "VSCodium installation and configuration"

ui_description "Install VSCodium from RPM and apply a managed configuration."

if ui_confirm "Install and configure VSCodium?" "Install" "Skip"; then

    # VSCodium is available as a third-party repository

    ui_step "Adding Pavlo Rudyi's VSCodium RPM repository and installing VSCodium."
    sudo tee "/etc/yum.repos.d/vscodium.repo" <<'REPO'
[paulcarroty-vscodium-repo]
name=Pavlo Rudyi's VSCodium repo
baseurl=https://paulcarroty.gitlab.io/vscodium-deb-rpm-repo/rpms/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg
metadata_expire=1h
REPO

    sudo dnf install codium -y

    ui_step "Preparing the VSCodium configuration."
    mkdir -p "${HOME}/.config/VSCodium/User"

    if VSCODIUM_FLAVOR="$(ui_choose_one "Select a VSCodium configuration" "Simple" "Fancy")"; then
        VSCODIUM_FLAVOR_STATUS=0
    else
        VSCODIUM_FLAVOR_STATUS="${?}"
    fi
    if [ "${VSCODIUM_FLAVOR_STATUS}" -ne 0 ]; then
        return "${VSCODIUM_FLAVOR_STATUS}"
    fi

    if [ -z "${VSCODIUM_FLAVOR}" ]; then
        VSCODIUM_FLAVOR="Simple"
    fi

    if [ "${VSCODIUM_FLAVOR}" = "Simple" ]; then

        cat >"${HOME}/.config/VSCodium/User/settings.json" <<'JSON'
{
    "workbench.startupEditor": "none",
    "editor.fontFamily": "'JetBrainsMono Nerd Font', 'Droid Sans Mono', 'monospace', monospace",
    "editor.fontLigatures": true,
    "security.workspace.trust.untrustedFiles": "open",
    "security.workspace.trust.startupPrompt": "never",
    "security.workspace.trust.enabled": false,
    "window.restoreWindows": "none",
    "workbench.colorTheme": "Default Light Modern"
}
JSON

    else

        cat >"${HOME}/.config/VSCodium/User/settings.json" <<'JSON'
{
    "workbench.startupEditor": "none",
    "editor.fontFamily": "'Cascadia Code', 'JetBrainsMono Nerd Font', 'Droid Sans Mono', 'monospace', monospace",
    // ****************************************************
    // Uncomment for enabling ligatures for fonts other
    // than Cascadia Code
    // ****************************************************
    // "editor.fontLigatures": true,
    // ****************************************************
    // Specific configuration for enabling cursive italic
    // for Cascadia Code
    // ****************************************************
    "editor.fontLigatures": "'ss01', 'ss02', 'ss03', 'ss04', 'ss05', 'ss06', 'zero', 'onum'",
	"editor.tokenColorCustomizations": {
		"textMateRules": [
			{
				"scope": [
					"comment",
					// "constant",
					// "emphasis",
					// "entity",
					// "invalid",
					// "keyword",
					// "markup",
					// "meta",
					// "storage",
					// "string",
					// "strong",
					// "support",
					// "variable"
				],
				"settings": {
					"fontStyle": "italic"
				}
			}
		]
	},
    // ****************************************************
    "security.workspace.trust.untrustedFiles": "open",
    "security.workspace.trust.startupPrompt": "never",
    "security.workspace.trust.enabled": false,
    "window.restoreWindows": "none",
	"workbench.colorTheme": "Default Light Modern",
	"workbench.iconTheme": "vscode-icons",
	"editor.wordWrap": "on",
	"editor.cursorSmoothCaretAnimation": "on",
	"editor.lightbulb.enabled": "onCode",
	"editor.semanticHighlighting.enabled": true,
	"breadcrumbs.enabled": true,
	"editor.cursorBlinking": "phase",
	"files.insertFinalNewline": true,
	"files.trimTrailingWhitespace": true
    // ****************************************************
    // If you don't want to see the new version message every
    // time the vscode-icons extension updates, then set this
    // configuration setting:
    // ****************************************************
	// "vsicons.dontShowNewVersionMessage": true
    // ****************************************************
}
JSON

    fi

    ui_success "VSCodium and its configuration are ready."
else
    ui_skip "VSCodium was not installed."
fi
