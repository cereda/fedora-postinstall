#!/usr/bin/env bash

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
source "common/uv-installation.sh"
source "common/sdkman-installation.sh"
source "common/rust-installation.sh"

source "common/nvm-installation.sh"
source "common/terminal-colours.sh"

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

source "common/profile-photo.sh"
