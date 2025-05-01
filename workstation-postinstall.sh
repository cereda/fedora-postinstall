#!/usr/bin/env bash

source "common/flathub-configuration.sh"
source "workstation/packages-to-remove.sh"
source "workstation/package-cleanup.sh"
source "workstation/rpmfusion-configuration.sh"
source "common/flatpaks-installation.sh"

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

source "common/hostname-configuration.sh"

source "workstation/home-configuration.sh"
source "common/starship-installation.sh"
source "common/uv-installation.sh"
source "common/sdkman-installation.sh"
source "common/rust-installation.sh"

source "workstation/vim-installation.sh"
source "workstation/neovim-installation.sh"

source "common/nvm-installation.sh"
source "common/terminal-colours.sh"

source "workstation/packages-to-install.sh"
source "workstation/useful-packages.sh"

source "common/git-configuration.sh"
source "workstation/vscodium-installation.sh"
source "workstation/texlive-configuration.sh"

source "common/distrobox-installation.sh"
source "common/fonts-installation.sh"
source "common/cascadia-code-installation.sh"
source "common/yt-dlp-installation.sh"

source "workstation/nix-installation.sh"
source "common/direnv-installation.sh"
source "common/helix-installation.sh"
source "common/zed-installation.sh"

source "common/profile-photo.sh"
