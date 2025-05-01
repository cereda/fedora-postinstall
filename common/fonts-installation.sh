#!/usr/bin/env bash

section "Installation and configuration of custom fonts"

description "The Nerd Fonts project provides patched versions of popular \
programming fonts, adding support for a wide range of icons and symbols \
to enhance the visual experience in code editors and terminal emulators."

echo

question "Do you want to install custom fonts?"

if [ $? = 0 ]; then

    FONT_VERSION=$(${GUM} input --prompt "Latest version of Nerd Fonts: " --value "${NERD_FONTS_VERSION}")

    info "Creating local font directory."
    mkdir -p "${HOME}/.local/share/fonts"

    for NERD_FONT in "${!NERD_FONTS[@]}" ; do
        info "Downloading ${NERD_FONT} from GitHub."
        wget "https://github.com/ryanoasis/nerd-fonts/releases/download/v${FONT_VERSION}/${NERD_FONTS[${NERD_FONT}]}.zip"

        info "Extracting file into fonts directory."    
        unzip "${NERD_FONTS[${NERD_FONT}]}.zip" -d "${HOME}/.local/share/fonts/${NERD_FONT}"
    done

    info "Removing unused files."
    find "${HOME}/.local/share/fonts" -type f -not -name "*.ttf" -not -name "*.otf" -exec rm {} \;

    info "Generating font cache."
    fc-cache -fv "${HOME}/.local/share/fonts"

    info "Regenerating font cache."
    fc-cache -fv "${HOME}/.local/share/fonts"
fi
