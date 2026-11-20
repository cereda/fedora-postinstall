#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Installation and configuration of custom fonts"

description "The Nerd Fonts project provides patched versions of popular \
programming fonts, adding support for a wide range of icons and symbols \
to enhance the visual experience in code editors and terminal emulators."

echo

question "Do you want to install custom fonts?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    # Note: GitHub may apply rate limits to the API endpoint, which could
    # cause this section to fail (been there, done that)

    info "Getting the latest version of Nerd Fonts from GitHub."
    test -f nerd-fonts.json || wget -q -O nerd-fonts.json https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest

    info "Extracting version of Nerd Fonts from the GitHub API response."
    NERD_FONTS_VERSION="$(jq -r '.tag_name' nerd-fonts.json)"

    info "Creating local fonts directory."
    mkdir -p "${HOME}/.local/share/fonts"

    # for each font, download it from GitHub and extract it to a dedicated
    # directory so cleanup never affects unrelated user fonts
    for NERD_FONT in "${!NERD_FONTS[@]}"; do

        FONT_ARCHIVE="${NERD_FONTS[${NERD_FONT}]}.zip"
        FONT_TARGET="${HOME}/.local/share/fonts/${NERD_FONT}"

        info "Downloading ${NERD_FONT} from GitHub."
        wget -q -O "${FONT_ARCHIVE}" "https://github.com/ryanoasis/nerd-fonts/releases/download/${NERD_FONTS_VERSION}/${FONT_ARCHIVE}"

        info "Extracting file into the local fonts directory."
        mkdir -p "${FONT_TARGET}"
        unzip -qo "${FONT_ARCHIVE}" -d "${FONT_TARGET}"

        info "Removing unused files from ${NERD_FONT}."
        find "${FONT_TARGET}" -type f -not -name "*.ttf" -not -name "*.otf" -delete

        rm -f "${FONT_ARCHIVE}"
    done

    info "Generating font cache."
    fc-cache -fv "${HOME}/.local/share/fonts"
fi
