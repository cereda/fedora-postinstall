#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "VSCodium installation and configuration"

description "Install VSCodium from RPM and configure it."
echo

if question "Do you want to install and configure VSCodium?"; then

    # VSCodium is available as a third-party repository

    info "Adding the corresponding RPM repository (provided by Pavlo Rudyi)."
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

    info "Installing the VSCodium application as an RPM package."
    sudo dnf install codium -y

    info "Preparing the configuration directory."
    mkdir -p "${HOME}/.config/VSCodium/User"

    text "Which configuration do you want to apply?"

    echo

    VSCODIUM_FLAVOUR=$("${GUM}" choose "Simple" "Fancy")

    if [ -z "${VSCODIUM_FLAVOUR}" ]; then
        VSCODIUM_FLAVOUR="Simple"
    fi

    if [ "${VSCODIUM_FLAVOUR}" = "Simple" ]; then

        info "Writing the configuration file (simple)."
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

        info "Writing the configuration file (fancy)."
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
fi
