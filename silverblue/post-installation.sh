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

if [ ${0##*/} == ${BASH_SOURCE[0]##*/} ]; then    
    echo "╭──────────────────────────────────────────╮"
    echo "│ This script cannot be executed directly. │"
    echo "╰──────────────────────────────────────────╯"
    exit 1
fi

source "common/flathub-configuration.sh"
source "silverblue/flatpak-unpin.sh"
source "silverblue/flatpak-cleanup.sh"
source "common/flatpaks-installation.sh"

source "common/gnome-font-rendering.sh"
source "common/gnome-clock.sh"
source "common/gnome-autorun.sh"
source "common/gnome-touchpad.sh"
source "common/gnome-notification-banners.sh"
source "common/gnome-technical-reports.sh"
source "common/gnome-nautilus.sh"
source "common/gnome-night-light.sh"
source "common/gnome-software.sh"
source "common/gnome-logo-gdm.sh"

source "common/hostname-configuration.sh"

source "silverblue/home-configuration.sh"
source "common/starship-installation.sh"
source "common/carapace-installation.sh"
source "common/uv-installation.sh"
source "common/sdkman-installation.sh"
source "common/rust-installation.sh"

source "common/nvm-installation.sh"
source "common/color-themes.sh"
source "common/terminal-colors.sh"

source "common/git-configuration.sh"
source "silverblue/vscodium-installation.sh"

source "common/distrobox-installation.sh"
source "common/fonts-installation.sh"
source "common/cascadia-code-installation.sh"
source "common/yt-dlp-installation.sh"

source "silverblue/nix-installation.sh"
source "common/direnv-installation.sh"
source "common/helix-installation.sh"
source "common/zed-installation.sh"

source "silverblue/toolbox-configuration.sh"
source "silverblue/packages-to-install.sh"
source "silverblue/useful-packages.sh"

source "silverblue/neovim-installation.sh"
source "common/miniconda-installation.sh"
source "silverblue/homebrew-installation.sh"

source "common/profile-photo.sh"
