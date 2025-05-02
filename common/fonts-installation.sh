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
