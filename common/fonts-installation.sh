#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Nerd Fonts installation"

ui_description "Install Nerd Fonts for terminals and editors."

if ui_confirm "Install Nerd Fonts?" "Install" "Skip"; then

    ui_step "Resolving the latest Nerd Fonts release."
    test -f nerd-fonts.json || wget -q -O nerd-fonts.json https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest
    NERD_FONTS_VERSION="$(jq -r '.tag_name' nerd-fonts.json)"

    ui_step "Installing Nerd Fonts."
    mkdir -p "${HOME}/.local/share/fonts"

    # for each font, download it from GitHub and extract it to a dedicated
    # directory so cleanup never affects unrelated user fonts
    for NERD_FONT in "${!NERD_FONTS[@]}"; do

        FONT_ARCHIVE="${NERD_FONTS[${NERD_FONT}]}.zip"
        FONT_TARGET="${HOME}/.local/share/fonts/${NERD_FONT}"

        ui_step "Downloading ${NERD_FONT}."
        wget -q -O "${FONT_ARCHIVE}" "https://github.com/ryanoasis/nerd-fonts/releases/download/${NERD_FONTS_VERSION}/${FONT_ARCHIVE}"

        ui_step "Extracting ${NERD_FONT}."
        mkdir -p "${FONT_TARGET}"
        unzip -qo "${FONT_ARCHIVE}" -d "${FONT_TARGET}"

        find "${FONT_TARGET}" -type f -not -name "*.ttf" -not -name "*.otf" -delete

        rm -f "${FONT_ARCHIVE}"
    done

    ui_step "Generating the Nerd Fonts font cache."
    fc-cache -fv "${HOME}/.local/share/fonts"
else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "Nerd Fonts were not installed."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
