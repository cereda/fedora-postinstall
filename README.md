# Fedora post installation guide

Welcome to my personal Fedora post installation guide. This repository describes most of the tasks I do after a clean install of this awesome
Linux distribution. Ideas and suggestions were collected from different sources and also from personal experience and preference. Use this
guide at your own risk and have fun with Fedora!

| Script                  | Description                                                                                                  |
|-------------------------|--------------------------------------------------------------------------------------------------------------|
| `fedora-postinstall.sh` | Entry point, this interactive script contains most of the tasks to enhance the desktop experience.           |
| `extra-binaries.sh`     | Optional, this script downloads extra binaries I typically use and deploys them into my local bin directory. |
| `gen-cat.sh`            | Optional, this script, as the name implies, generates a file named `cat.png` that I use as my profile photo. |

## How to run these scripts?

Open your terminal and type:

```bash
$ git clone --depth 1 https://github.com/cereda/fedora-postinstall
$ cd fedora-postinstall
$ bash fedora-postinstall.sh # main script
$ bash extra-binaries.sh # extra binaries
```

## What does this script do?

This script basically does the following tasks:

1. Removes packages that I never use. The script should detect whether you are running Workstation or Silverbule and run the
   appropriate commands.
2. Installs and enables FlatHub, a centralized repository of Flatpak apps. This is recommended and encouraged going forward.
3. Asks whether you want to install the RPMFusion repositories. This is only recommended if you are running Workstation.
4. In case you have Fedora's version of `ffmpeg`, it asks whether you want to replace it by the one available in the RPMFusion
   repositories.
5. It does the following tweaks:
   - GNOME Editor: highlight current line, disable restore session, show grid, show line numbers, show right margin, disable
     spellcheck.
   - GNOME Clock: Show weekday.
   - Autorun: disable autorun for removable media.
   - Touchpad: enable tap to click, enable two finger scrolling.
   - Notifications: disable show banners, disable show in lock screen.
   - Technical reports: disable problem reporting.
   - Nautilus: set default folder viewer, disable image thumbnails.
   - Brightness: night light enabled.
   - GNOME Software: disable download updates, disable notify updates.
6. Configures hostname.
7. Customises the `${HOME}` directory by creating a structure with aliases, local applications and path management.
8. Configures vim and neovim.
9. Installs useful applications (archiving, profiling, etc).
10. Installs assorted development environments (Rust, Node, Java, etc).
11. Configures git.
12. Installs and configures VSCodium (a community-driven, freely-licensed binary distribution of Microsoft's editor VSCode).
13. Configures system-wide TeX Live path resolution.
14. Installs and configures Distrobox.
15. Downloads and installs fonts from the Nerd Fonts project.
16. Downloads and configures `yt-dlp`.
17. Generates the cat profile photo from `gen-cat.sh`.

Additionally, `extra-binaries.sh` finds the latest versions of softwares I use from GitHub (beware of hitting the API rate limit),
downloads and deploys them into the `${HOME}/.local/bin` directory (already available in `${PATH}`).

## What to do if something goes wrong?

Quack in despair? On a more serious note, inspect this script before running it, it should not be difficult to understand what it
does on every line of code. There is always room for improvement, and make sure to have a fantastic Fedora experience! Have fun!