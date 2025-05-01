#!/usr/bin/env bash

section "VSCodium installation and configuration"

description "VSCodium is an open-source, binary distribution of Microsoft's \
Visual Studio Code (VS Code) editor, without the telemetry and proprietary \
features. It provides the same core functionality as VS Code, but with a \
focus on privacy and transparency by removing the Microsoft-specific branding \
and tracking components."

echo

question "Do you want to install and configure VSCodium?"

if [ $? = 0 ]; then

    info "Installing the VSCodium application as Flatpak."
    flatpak install flathub com.vscodium.codium

    info "Preparing the configuration directory."
    mkdir -p "${HOME}/.var/app/com.vscodium.codium/config/VSCodium/User"

    text "Which configuration do you want to apply?"
    VSCODIUM_FLAVOUR=$(${GUM} choose "Simple" "Fancy")

    if [ "${VSCODIUM_FLAVOUR}" = "Simple" ]; then

        info "Writing the configuration file (simple)."
        tee "${HOME}/.var/app/com.vscodium.codium/config/VSCodium/User/settings.json" <<EOF
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
EOF

    else

        info "Writing the configuration file (fancy)."
        tee "${HOME}/.var/app/com.vscodium.codium/config/VSCodium/User/settings.json" <<EOF
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
EOF

    fi
fi
