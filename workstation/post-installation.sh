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
runtime_run_module "common/flathub-configuration.sh"
runtime_run_module "common/flatpark-configuration.sh"
runtime_run_module "workstation/packages-to-remove.sh" read-only
runtime_run_module "workstation/package-cleanup.sh"
runtime_run_module "workstation/rpmfusion-configuration.sh"
runtime_run_module "workstation/terra-installation.sh"
runtime_run_module "common/flatpaks-installation.sh"

# GNOME configuration
runtime_run_module "common/gnome-font-rendering.sh"
runtime_run_module "workstation/gnome-text-editor.sh"
runtime_run_module "common/gnome-clock.sh"
runtime_run_module "common/gnome-autorun.sh"
runtime_run_module "common/gnome-touchpad.sh"
runtime_run_module "common/gnome-notification-banners.sh"
runtime_run_module "common/gnome-technical-reports.sh"
runtime_run_module "common/gnome-nautilus.sh"
runtime_run_module "common/gnome-night-light.sh"
runtime_run_module "common/gnome-software.sh"
runtime_run_module "common/gnome-logo-gdm.sh"

# hostname configuration
runtime_run_module "common/hostname-configuration.sh" mutating MACHINE_NAME

# custom home configuration
runtime_run_module "workstation/home-configuration.sh" mutating ROOT_DIRECTORY_STRUCTURE COMMAND_NAME

# useful command line tools
runtime_run_module "common/starship-installation.sh"
runtime_run_module "common/carapace-installation.sh"
runtime_run_module "common/zoxide-installation.sh"
runtime_run_module "common/uv-installation.sh"
runtime_run_module "common/sdkman-installation.sh"
runtime_run_module "common/rust-installation.sh"
runtime_run_module "common/go-installation.sh"
runtime_run_module "common/nvm-installation.sh"
runtime_run_module "common/mise-installation.sh"

# vim and neovim editors
runtime_run_module "workstation/vim-installation.sh"
runtime_run_module "workstation/neovim-installation.sh"

# taskwarrior
runtime_run_module "workstation/taskwarrior-installation.sh"

# Ghostty
runtime_run_module "workstation/ghostty-installation.sh"

# yazi
runtime_run_module "workstation/yazi-installation.sh"

# forgit
runtime_run_module "workstation/forgit-installation.sh"

# color themes for the terminal
runtime_run_module "common/color-themes.sh" read-only
runtime_run_module "common/terminal-colors.sh"

# useful packages to install
runtime_run_module "workstation/packages-to-install.sh" read-only
runtime_run_module "workstation/useful-packages.sh"

# git configuration
runtime_run_module "common/git-configuration.sh"

# VSCodium
runtime_run_module "workstation/vscodium-installation.sh"

# TeX Live configuration
runtime_run_module "workstation/texlive-configuration.sh"

# Distrobox
runtime_run_module "common/distrobox-installation.sh"

# fonts
runtime_run_module "common/fonts-installation.sh"
runtime_run_module "common/cascadia-code-installation.sh"

# yt-dlp
runtime_run_module "common/yt-dlp-installation.sh"

# Nix
runtime_run_module "workstation/nix-installation.sh"

# Nix toolbox
runtime_run_module "common/nix-toolbox-configuration.sh"

# direnv
runtime_run_module "common/direnv-installation.sh"

# Helix and Zed editors
runtime_run_module "common/helix-installation.sh"
runtime_run_module "common/zed-installation.sh"

# tmux
runtime_run_module "workstation/tmux-installation.sh"

# Miniconda
runtime_run_module "common/miniconda-installation.sh"

# profile photo
runtime_run_module "common/profile-photo.sh"
