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

# flatpaks and packages
source "common/flathub-configuration.sh"
source "workstation/packages-to-remove.sh"
source "workstation/package-cleanup.sh"
source "workstation/rpmfusion-configuration.sh"
source "common/flatpaks-installation.sh"

# GNOME configuration
source "common/gnome-font-rendering.sh"
source "workstation/gnome-text-editor.sh"
source "common/gnome-clock.sh"
source "common/gnome-autorun.sh"
source "common/gnome-touchpad.sh"
source "common/gnome-notification-banners.sh"
source "common/gnome-technical-reports.sh"
source "common/gnome-nautilus.sh"
source "common/gnome-night-light.sh"
source "common/gnome-software.sh"
source "common/gnome-logo-gdm.sh"

# hostname configuration
source "common/hostname-configuration.sh"

# custom home configuration
source "workstation/home-configuration.sh"

# useful command line tools
source "common/starship-installation.sh"
source "common/carapace-installation.sh"
source "common/zoxide-installation.sh"
source "common/uv-installation.sh"
source "common/sdkman-installation.sh"
source "common/rust-installation.sh"
source "common/nvm-installation.sh"
source "common/mise-installation.sh"

# vim and neovim editors
source "workstation/vim-installation.sh"
source "workstation/neovim-installation.sh"

# color themes for the terminal
source "common/color-themes.sh"
source "common/terminal-colors.sh"

# useful packages to install
source "workstation/packages-to-install.sh"
source "workstation/useful-packages.sh"

# git configuration
source "common/git-configuration.sh"

# VSCodium
source "workstation/vscodium-installation.sh"

# TeX Live configuration
source "workstation/texlive-configuration.sh"

# Distrobox
source "common/distrobox-installation.sh"

# fonts
source "common/fonts-installation.sh"
source "common/cascadia-code-installation.sh"

# yt-dlp
source "common/yt-dlp-installation.sh"

# Nix
source "workstation/nix-installation.sh"

# direnv
source "common/direnv-installation.sh"

# Helix and Zed editors
source "common/helix-installation.sh"
source "common/zed-installation.sh"

# tmux
source "workstation/tmux-installation.sh"

# Miniconda
source "common/miniconda-installation.sh"

# profile photo
source "common/profile-photo.sh"
