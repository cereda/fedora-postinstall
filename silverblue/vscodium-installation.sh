#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "VSCodium installation and configuration"

description "Install and configure VSCodium as a Flatpak."
echo

if question "Do you want to install and configure VSCodium?"; then

    info "Installing the VSCodium application as Flatpak."
    flatpak install flathub com.vscodium.codium

    info "Preparing the configuration directory."
    mkdir -p "${HOME}/.var/app/com.vscodium.codium/config/VSCodium/User"

    text "Which configuration do you want to apply?"

    echo

    VSCODIUM_FLAVOUR=$("${GUM}" choose "Simple" "Fancy")

    if [ -z "${VSCODIUM_FLAVOUR}" ]; then
        VSCODIUM_FLAVOUR="Simple"
    fi

    if [ "${VSCODIUM_FLAVOUR}" = "Simple" ]; then

        info "Writing the configuration file (simple)."
        cat >"${HOME}/.var/app/com.vscodium.codium/config/VSCodium/User/settings.json" <<'JSON'
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

        info "Writing the configuration file (fancy)."
        cat >"${HOME}/.var/app/com.vscodium.codium/config/VSCodium/User/settings.json" <<'JSON'
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
fi
