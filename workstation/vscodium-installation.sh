#!/usr/bin/env bash

# MIT License
# 
# Copyright (c) 2025, Paulo Cereda
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

section "VSCodium installation and configuration"

description "VSCodium is an open-source, binary distribution of Microsoft's \
Visual Studio Code (VS Code) editor, without the telemetry and proprietary \
features. It provides the same core functionality as VS Code, but with a \
focus on privacy and transparency by removing the Microsoft-specific branding \
and tracking components."

echo

question "Do you want to install and configure VSCodium?"

if [ $? = 0 ]; then

    info "Adding the corresponding RPM repository (provided by Pavlo Rudyi)."
    sudo tee "/etc/yum.repos.d/vscodium.repo" <<EOF
[paulcarroty-vscodium-repo]
name=Pavlo Rudyi's VSCodium repo
baseurl=https://paulcarroty.gitlab.io/vscodium-deb-rpm-repo/rpms/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg
metadata_expire=1h
EOF

    info "Installing the VSCodium application as an RPM package."
    sudo dnf install codium -y

    info "Preparing the configuration directory."
    mkdir -p "${HOME}/.config/VSCodium/User"

    text "Which configuration do you want to apply?"
    VSCODIUM_FLAVOUR=$(${GUM} choose "Simple" "Fancy")

    if [ -z "${VSCODIUM_FLAVOUR}" ]; then
        VSCODIUM_FLAVOUR="Simple
    fi

    if [ "${VSCODIUM_FLAVOUR}" = "Simple" ]; then

        info "Writing the configuration file (simple)."
        tee "${HOME}/.config/VSCodium/User/settings.json" <<EOF
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
        tee "${HOME}/.config/VSCodium/User/settings.json" <<EOF
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
