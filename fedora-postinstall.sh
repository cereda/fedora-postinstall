#!/usr/bin/env bash

declare -t EXISTING_PACKAGES=(
    "gnome-calendar"
    "gnome-clocks"
    "gnome-characters"
    "gnome-contacts"
    "gnome-maps"
    "gnome-user-docs"
    "gnome-weather"
    "libreoffice*"
    "rhythmbox"
    "simple-scan"
    "totem"
    "gnome-boxes"
    "mediawriter"
)

declare -t SUGGESTED_FLATPAKS=(
    "app.devsuite.Ptyxis"
    "com.felipekinoshita.Wildcard"
    "com.github.tchx84.Flatseal"
    "com.jeffser.Alpaca"
    "com.mattjakeman.ExtensionManager"
    "com.obsproject.Studio"
    "com.rafaelmardojai.Blanket"
    "fr.handbrake.ghb"
    "io.github.celluloid_player.Celluloid"
    "io.github.dvlv.boxbuddyrs"
    "io.gitlab.adhami3310.Impression"
    "io.gitlab.librewolf-community"
    "io.mpv.Mpv"
    "net.nokyan.Resources"
    "org.audacityteam.Audacity"
    "org.chromium.Chromium"
    "org.frescobaldi.Frescobaldi"
    "org.gimp.GIMP"
    "org.gnome.Boxes"
    "org.gnome.TwentyFortyEight"
    "org.gnome.dspy"
    "org.inkscape.Inkscape"
    "org.kde.kdenlive"
    "org.keepassxc.KeePassXC"
    "org.libreoffice.LibreOffice"
    "org.localsend.localsend_app"
    "org.mozilla.Thunderbird"
    "org.qbittorrent.qBittorrent"
)

function chapter {
    gum style --border double \
        --align center \
        --width 60 \
        --padding "1 1" \
        --foreground 10 \
        --border-foreground 10 \
        "$1"
}

function section {
    gum style --width 60 \
        --border rounded \
        --align center \
        --foreground 12 \
        --border-foreground 12 \
        "$1"
}

function question {
    gum confirm \
        --prompt.foreground=6 \
        --selected.background=6 \
        "$1"
}

function text {
    gum style --width 60 \
        --margin "1 1" \
    "$1"    
}

function command_exists {
    command -v "$1" >/dev/null 2>&1 ||
    {
        echo >&2 "This script requires $1. Please install it"
        echo >&2 "first and run this script again."
        exit 1
    }
}

command_exists gum

FEDORA_VERSION=$(rpm -E %fedora)

chapter "Paulo's Fedora ${FEDORA_VERSION} post installation script"

question "Did you upgrade your system?" || exit 1

text "Welcome to my post installation script for Fedora! Please select which flavour of Fedora you are currently running."

FEDORA_FLAVOUR=$(gum choose "Workstation" "Silverblue")

text "You are running Fedora ${FEDORA_FLAVOUR} ${FEDORA_VERSION}. Let's go!"

section "Flathub configuration"

question "Do you want to configure Flathub?"

if [ $? = 0 ]; then

    text "Let's configure the Flathub repository."

    text "Configuring Flathub."
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

    text "Enabling Flathub."
    flatpak remote-modify --enable flathub
    
fi

if [ "${FEDORA_FLAVOUR}" = "Silverblue" ]; then

    section "Flatpak cleanup"

    text "Fedora Silverblue comes with several applications installed as flatpaks. Would you like to remove some of them?"

    mapfile -t INSTALLED_FLATPAKS < <(flatpak list --app --columns=application)
    readarray -t FLATPAKS_TO_REMOVE <<< $(gum choose --no-limit --height 15 "${INSTALLED_FLATPAKS[@]}")

    if [ -z "${FLATPAKS_TO_REMOVE}" ]; then
        text "You haven't selected any items from the list. Moving on."
    else
        text "You've selected ${#FLATPAKS_TO_REMOVE[@]} flatpak(s) to remove. Please wait."

        for FLATPAK_TO_REMOVE in "${FLATPAKS_TO_REMOVE[@]}"; do
            text "Removing ${FLATPAK_TO_REMOVE}."
            flatpak uninstall "${FLATPAK_TO_REMOVE}" -y
        done

        text "Removing unused framework(s)."
        flatpak uninstall --unused -y
    fi
else

    section "Package cleanup"

    text "Fedora Workstation comes with several applications that could be removed. Would you like to remove some of them?"

    readarray -t PACKAGES_TO_REMOVE <<< $(gum choose --no-limit --height 15 "${EXISTING_PACKAGES[@]}")

    if [ -z "${PACKAGES_TO_REMOVE}" ]; then
        text "You haven't selected any items from the list. Moving on."
    else
        text "You've selected ${#PACKAGES_TO_REMOVE[@]} package(s) to remove. Please wait."

        PACKAGE_REMOVAL_LIST=$(printf " %s" "${PACKAGES_TO_REMOVE[@]}")

        text "Removing package(s)."
        sudo dnf remove ${PACKAGE_REMOVAL_LIST:1} -y

        text "Cleaning up orphan packages."
        sudo dnf autoremove -y
    fi

    section "RPMFusion configuration"

    question "Do you want to configure the RPMFusion repositories?"

    if [ $? = 0 ]; then

        text "Let's configure the RPMFusion repositories."

        text "Configuring the free repository."
        sudo dnf install https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VERSION}.noarch.rpm -y

        text "Configuring the non-free repository."
        sudo dnf install https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VERSION}.noarch.rpm -y

        rpm -qa | grep -i ffmpeg >/dev/null 2>&1 && section "ffmpeg configuration" && question "Do you want to replace Fedora's ffmpeg?"

        if [ $? = 0 ]; then
            
            text "Replacing Fedora's ffmpeg."
            sudo dnf swap ffmpeg-free ffmpeg --allowerasing
        fi
    fi
fi

section "Flatpak applications"

text "Do you want to install any of these Flatpak applications?"

readarray -t FLATPAKS_TO_INSTALL <<< $(gum choose --no-limit --height 15 "${SUGGESTED_FLATPAKS[@]}")

if [ -z "${FLATPAKS_TO_INSTALL}" ]; then
    text "You haven't selected any items from the list. Moving on."
    FLATPAKS_KEEP_CACHE_LIST=""
else
    text "You've selected ${#FLATPAKS_TO_INSTALL[@]} flatpak(s) to install. Please wait."

    for FLATPAK_TO_INSTALL in "${FLATPAKS_TO_INSTALL[@]}"; do
        text "Installing ${FLATPAK_TO_REMOVE}."
        flatpak install flathub ${FLATPAK_TO_INSTALL} --y
    done

    text "Which Flatpak applications do you want to keep from cache cleaning?"

    readarray -t FLATPAKS_TO_KEEP_CACHE <<< $(gum choose --no-limit --selected="com.github.tchx84.Flatseal" --height 15 "${FLATPAKS_TO_INSTALL[@]}")
    FLATPAKS_KEEP_CACHE_LIST=$(printf " -not -name %s" "${FLATPAKS_TO_KEEP_CACHE[@]}")    
fi

section "GNOME configuration"

question "Do you want to improve font rendering?"

if [ $? = 0 ]; then

    text "Font antialiasing."
    gsettings set org.gnome.desktop.interface font-antialiasing rgba

    text "Font hinting."
    gsettings set org.gnome.desktop.interface font-hinting slight
fi

question "Do you want to configure the GNOME text editor?"

if [ $? = 0 ]; then

    text "Highlighting current line."
    gsettings set org.gnome.TextEditor highlight-current-line true

    text "Disabling restore session."
    gsettings set org.gnome.TextEditor restore-session false

    text "Showing grid."
    gsettings set org.gnome.TextEditor show-grid true

    text "Showing line numbers."
    gsettings set org.gnome.TextEditor show-line-numbers true

    text "Showing right margin."
    gsettings set org.gnome.TextEditor show-right-margin true

    text "Disabling spellcheck."
    gsettings set org.gnome.TextEditor spellcheck false
fi

question "Do you want to configure the GNOME clock?"

if [ $? = 0 ]; then

    text "Showing weekday."
    gsettings set org.gnome.desktop.interface clock-show-weekday true
fi

question "Do you want to disable autorum for removable media?"

if [ $? = 0 ]; then

    text "Disabling autorun for removable media."
    gsettings set org.gnome.desktop.media-handling autorun-never true
fi

question "Do you want to configure your laptop touchpad?"

if [ $? = 0 ]; then

    text "Enabling tap to click."
    gsettings set org.gnome.desktop.peripherals.touchpad tap-to-click true

    text "Enabling two finger scrolling."
    gsettings set org.gnome.desktop.peripherals.touchpad two-finger-scrolling-enabled true
fi

question "Do you want to disable notification banners?"

if [ $? = 0 ]; then

    text "Disabling show banners."
    gsettings set org.gnome.desktop.notifications show-banners false

    text "Disabling show in lock screen."
    gsettings set org.gnome.desktop.notifications show-in-lock-screen false
fi

question "Do you want to disable technical reports?"

if [ $? = 0 ]; then

    text "Disabling problem reporting."
    gsettings set org.gnome.desktop.privacy report-technical-problems false
fi

question "Do you want to configure Nautilus?"

if [ $? = 0 ]; then

    text "Setting default folder viewer."
    gsettings set org.gnome.nautilus.preferences default-folder-viewer icon-view

    text "Disabling image thumbnails."
    gsettings set org.gnome.nautilus.preferences show-image-thumbnails never
fi

question "Do you want to enable night light?"

if [ $? = 0 ]; then

    text "Enabling night light."
    gsettings set org.gnome.settings-daemon.plugins.color night-light-enabled true
fi

question "Do you want to disable notifications from GNOME Software?"

if [ $? = 0 ]; then

    text "Disabling download updates."
    gsettings set org.gnome.software download-updates false

    text "Disabling notify updates."
    gsettings set org.gnome.software download-updates-notify false
fi

section "Hostname configuration"

MACHINE_NAME=$(gum input --prompt "Your machine name: ")

text "Configuring hostname."
sudo hostnamectl hostname "${MACHINE_NAME}"

text "Your Fedora ${FEDORA_FLAVOUR} ${FEDORA_VERSION} is now named ${MACHINE_NAME}."

section "Paulo's custom configuration for the home directory"

question "Do you want to create a custom configuration for your home directory?"

if [ $? = 0 ]; then

    ROOT_DIRECTORY_STRUCTURE="${HOME}/.${MACHINE_NAME}"

    text "The root directory structure will be located at ${ROOT_DIRECTORY_STRUCTURE} (Paulo's configuration)."

    text "Creating root directory."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}"

    text "Creating directory for applications."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/applications"

    text "Creating directory for config files."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/config"

    text "Creating directory for profile."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/profile"

    text "Creating directory for scripts."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/scripts"

    text "Creating directory for general stuff."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/stuff"

    text "Creating directory for environments."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/environments"

    text "Updating bash entry point."
    tee --append "${HOME}/.bashrc" <<EOF

# my personal configuration
if [ -e "${ROOT_DIRECTORY_STRUCTURE}/scripts/bash.sh" ]; then
    source "${ROOT_DIRECTORY_STRUCTURE}/scripts/bash.sh"
fi
EOF

    text "Creating main file for bash."
    tee "${ROOT_DIRECTORY_STRUCTURE}/scripts/bash.sh" <<EOF
# check if fortune exists and displays a message
if [ -f /usr/bin/fortune ]; then
    /usr/bin/fortune
fi

# loads the aliases for this machine
if [ -e "${ROOT_DIRECTORY_STRUCTURE}/scripts/aliases.sh" ]; then
    source "${ROOT_DIRECTORY_STRUCTURE}/scripts/aliases.sh"
fi

# loads the color scheme
if [ -e "${ROOT_DIRECTORY_STRUCTURE}/scripts/colors.sh" ]; then
    source "${ROOT_DIRECTORY_STRUCTURE}/scripts/colors.sh"
fi

# loads the Rust config
if [ -e "${ROOT_DIRECTORY_STRUCTURE}/scripts/rust.sh" ]; then
    source "${ROOT_DIRECTORY_STRUCTURE}/scripts/rust.sh"
fi

if [ -x "\$(command -v starship)" ]; then

    # set the configuration and log settings for starship
    export STARSHIP_CONFIG="${ROOT_DIRECTORY_STRUCTURE}/config/starship/starship.toml"
    export STARSHIP_LOG="error"

    # init starship prompt
    eval "\$(starship init bash)"
fi
EOF

    text "Creating aliases file."
    tee "${ROOT_DIRECTORY_STRUCTURE}/scripts/aliases.sh" <<EOF
# wrapper around some tools and commands I typically use in this computer
function ${MACHINE_NAME} {
    if [ "\$#" -ne 2 ]; then
        echo "Usage: ${MACHINE_NAME} <action> <target>" >&2
        return 1
    fi

    case "\$1" in
        upgrade)

            case "\$2" in
                system)
                    sudo dnf upgrade --refresh
                    sudo dnf autoremove
                ;;

                starship)
                    sh -c "\$(curl -fsSL https://starship.rs/install.sh)" -- -b "${HOME}/.local/bin" -y
                ;;

                tex)
                    if [ -x "\$(command -v tlmgr)" ]; then
                        tlmgr update --self --all --reinstall-forcibly-removed
                    fi
                ;;
                
                sdk)
                    if [ -e "${ROOT_DIRECTORY_STRUCTURE}/scripts/sdk.sh" ]; then
                        source "${ROOT_DIRECTORY_STRUCTURE}/scripts/sdk.sh"
                        sdk upgrade
                        sdk update
                    fi
                ;;

                vim)
                    if [ -x "\$(command -v vim)" ]; then
                        vim -c "PlugUpgrade" -c "PlugUpdate" -c "q" -c "q"
                    fi
                ;;

                node)
                    if [ -e "${ROOT_DIRECTORY_STRUCTURE}/scripts/node.sh" ]; then
                        source "${ROOT_DIRECTORY_STRUCTURE}/scripts/node.sh"
                        nvm install node
                    fi
                ;;

                youtube)
                    if [ -x "\$(command -v yt-dlp)" ]; then
                        yt-dlp -U
                    fi
                    ;;
                ;;

                rust)
                    if [ -x "\$(command -v rustup)" ]; then
                        rustup upgrade
                    fi
                ;;

                deno)
                    if [ -x "\$(command -v deno)" ]; then
                        deno upgrade
                    fi
                ;;

                bun)
                    if [ -x "\$(command -v bun)" ]; then
                        bun upgrade
                    fi
                ;;

                flatpak)
                    flatpak upgrade -y
                    flatpak remove --unused -y
                ;;

                conda)
                    if [ -e "${ROOT_DIRECTORY_STRUCTURE}/applications/miniconda/3/bin/conda" ]; then
                        eval "$("${ROOT_DIRECTORY_STRUCTURE}/applications/miniconda/3/bin/conda" shell.bash hook)"
                    fi
                ;;
                
                world)
                    ${MACHINE_NAME} upgrade flatpak
                    ${MACHINE_NAME} upgrade tex
                    ${MACHINE_NAME} upgrade sdk
                    ${MACHINE_NAME} upgrade vim
                    ${MACHINE_NAME} upgrade node
                    ${MACHINE_NAME} upgrade youtube
                    ${MACHINE_NAME} upgrade rust
                    ${MACHINE_NAME} upgrade deno
                    ${MACHINE_NAME} upgrade bun
                    ${MACHINE_NAME} upgrade conda
                    ${MACHINE_NAME} clean flatpak
                    ${MACHINE_NAME} clean cache
                ;;

                *)
                    echo "I don't know this target."
                ;;
            esac
        ;;

        clean)
            case "\$2" in
                flatpak)
                    flatpak remove --unused -y
                    find "${HOME}/.var/app" -maxdepth 1 -mindepth 1 ${FLATPAKS_KEEP_CACHE_LIST:1} -type d -exec rm -rf "{}" \;
                    find "/run/user/$(id --user)/app" -maxdepth 1 -mindepth 1 -type d -exec rm -rf "{}" \;
                ;;

                files)
                    sudo rm -f /var/log/boot.log-*
                    sudo rm -f /var/log/btmp-*
                    sudo rm -f /var/log/dnf.librepo.log.*
                    sudo rm -f /var/log/dnf.log.*
                    sudo rm -f /var/log/dnf.rpm.log.*
                    sudo rm -f /var/log/hawkey.log-*
                ;;

                cache)
                    if [ -x "\$(command -v bleachbit)" ]; then
                        bleachbit --preset --clean system.custom
                    fi
                    gio trash --empty
                ;;

                system)
                    ${MACHINE_NAME} clean cache
                    shutdown -h now
                ;;

                *)
                    echo "I don't know this target."
                ;;
            esac       
        ;;

        config)
            case "\$2" in
                menu)
                    gsettings set org.gnome.shell app-picker-layout "[]"
                ;;

                *)
                    echo "I don't know this target."
                ;;
            esac
        ;;

        *)
            echo "I don't know this action."
        ;
    esac
}

# extracts a playlist from YouTube and creates a proper list
function playlist {
    if [ "\$#" -ne 2 ]; then
        echo "Usage: playlist <link> <title>" >&2
        return 1
    fi
    yt-dlp -f 18 "\$1" -o "\$2, part %(video_autonumber)s.%(ext)s"
}

# extracts videos from certain links
function video-downloader {
    for link in "\$@"; do
        yt-dlp "\$link" -o - | ffmpeg -i pipe: "\$(shuf -er -n10  {A..Z} {a..z} {0..9} | tr -d '\n').mp4"
    done
}

# convert audio files to ogg
function audio-to-ogg {
    if [ "\$#" -ne 1 ]; then
        echo "Usage: audio-to-ogg <filename>" >&2
        return 1
    fi
    ffmpeg -i "\$1" -vn -c:a libvorbis -b:a 64k "\${1%.*}.ogg"
}
EOF

    question "Do you want to install starship?"

    if [ $? = 0 ]; then
        
        text "Preparing the installation directory."
        mkdir -p "${HOME}/.local/bin"
        
        text "Installing starship."
        sh -c "$(curl -fsSL https://starship.rs/install.sh)" -- -b "${HOME}/.local/bin" -y

        text "Preparing the configuration directory."
        mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/config/starship"

        text "Creating the configuration file."
        tee "${ROOT_DIRECTORY_STRUCTURE}/config/starship/starship.toml" <<EOF
[character]
success_symbol = "[➜](bold green)"
error_symbol = "[➜](bold red)"

[username]
show_always = true
format = "[\$user](\$style) at "
style_root = "bold red"
style_user = "bold yellow"

[hostname]
ssh_only = false
style = "bold blue"

[java]
style = "bold green"
EOF

    fi

    question "Do you want to install SDKman?"

    if [ $? = 0 ]; then
        text "Installing the SDKman binary."
        export SDKMAN_DIR="${ROOT_DIRECTORY_STRUCTURE}/applications/sdkman" && curl -s "https://get.sdkman.io?rcupdate=false" | bash

        text "Creating wrapper script."
        tee "${ROOT_DIRECTORY_STRUCTURE}/scripts/sdk.sh" <<EOF
# moving these lines to a single file to source it on demand
export SDKMAN_DIR="${ROOT_DIRECTORY_STRUCTURE}/applications/sdkman"
[[ -s "${ROOT_DIRECTORY_STRUCTURE}/applications/sdkman/bin/sdkman-init.sh" ]] && source "${ROOT_DIRECTORY_STRUCTURE}/applications/sdkman/bin/sdkman-init.sh"
EOF
    fi

    question "Do you want to install Rust?"

    if [ $? = 0 ]; then
        text "Preparing the Rust environment."
        mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/environments/rust"
        
        text "Exporting environment variables."
        export CARGO_HOME="${ROOT_DIRECTORY_STRUCTURE}/environments/rust/cargo"
        export RUSTUP_HOME="${ROOT_DIRECTORY_STRUCTURE}/applications/rustup"

        text "Installing binaries."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

        text "Writing helper script."
        tee "${ROOT_DIRECTORY_STRUCTURE}/scripts/rust.sh" <<EOF
export CARGO_HOME="${ROOT_DIRECTORY_STRUCTURE}/environments/rust/cargo"
export RUSTUP_HOME="${ROOT_DIRECTORY_STRUCTURE}/applications/rustup"
export PATH=${PATH}:${CARGO_HOME}/bin
EOF
    fi

    question "Do you want to install and configure vim?"

    if [ $? = 0 ]; then

        text "Installing vim."
        sudo dnf install vim

        text "Installing the plug-in manager for vim."
        curl -fLo "${HOME}/.vim/autoload/plug.vim" --create-dirs https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

        text "Creating the configuration file."
        tee "${HOME}/.vimrc" <<EOF
call plug#begin('~/.vim/plugged')

Plug 'godlygeek/tabular'
Plug 'itchyny/lightline.vim'
Plug 'sheerun/vim-polyglot'
Plug 'sainnhe/edge'
Plug 'preservim/nerdtree'
Plug 'psliwka/vim-smoothie'
Plug 'mhinz/vim-startify'
Plug 'tpope/vim-surround'
Plug 'preservim/nerdcommenter'
Plug 'luochen1990/rainbow'
Plug 'teto/vim-listchars'
Plug 'cohama/lexima.vim'
Plug 'junegunn/vim-easy-align'

call plug#end()

set nocompatible

filetype plugin indent on
syntax on

set autoindent
set expandtab

set softtabstop=4
set shiftwidth=4
set shiftround

set backspace=indent,eol,start
set hidden

set incsearch
set nohlsearch

set ttyfast
set lazyredraw

set number
set ruler

set noshowmode
set laststatus=2

set background=dark
if has('termguicolors')
    set termguicolors
endif

let g:edge_style = 'aura'
let g:edge_enable_italic = 0
let g:edge_disable_italic_comment = 1

let g:lightline = {'colorscheme' : 'edge'}

colorscheme edge

let g:startify_fortune_use_unicode = 1
let g:startify_custom_footer =
    \ ['', "   ooh vim", '']

let g:rainbow_active = 0
set viminfo=""
EOF
    fi

    question "Do you want to install and configure neovim?"

    if [ $? = 0 ]; then
        text "Installing neovim."
        sudo dnf install neovim

        text "Installing the plug-in manager for neovim."
        curl -fLo "${HOME}/.local/share/nvim/site/autoload/plug.vim" --create-dirs https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

        text "Creating configuration directory for neovim."
        mkdir -p "${HOME}/.config/nvim"

        tee "${HOME}/.config/nvim/init.vim" <<EOF
call plug#begin('~/.vim/plugged')

Plug 'godlygeek/tabular'
Plug 'itchyny/lightline.vim'
Plug 'sheerun/vim-polyglot'
Plug 'sainnhe/edge'
Plug 'preservim/nerdtree'
Plug 'psliwka/vim-smoothie'
Plug 'mhinz/vim-startify'
Plug 'tpope/vim-surround'
Plug 'preservim/nerdcommenter'
Plug 'luochen1990/rainbow'
Plug 'teto/vim-listchars'
Plug 'cohama/lexima.vim'
Plug 'junegunn/vim-easy-align'

call plug#end()

set nocompatible

filetype plugin indent on
syntax on

set autoindent
set expandtab

set softtabstop=4
set shiftwidth=4
set shiftround

set backspace=indent,eol,start
set hidden

set incsearch
set nohlsearch

set ttyfast
set lazyredraw

set number
set ruler

set noshowmode
set laststatus=2

set background=dark
if has('termguicolors')
    set termguicolors
endif

let g:edge_style = 'aura'
let g:edge_enable_italic = 0
let g:edge_disable_italic_comment = 1

let g:lightline = {'colorscheme' : 'edge'}

colorscheme edge

let g:startify_fortune_use_unicode = 1
let g:startify_custom_footer =
    \ ['', "   ooh vim", '']

let g:rainbow_active = 0
set viminfo=""
EOF

    fi

    question "Do you want to install nvm?"

    if [ $? = 0 ]; then

        text "Installing nvm."
        NVM_DIR="${ROOT_DIRECTORY_STRUCTURE}/applications/nvm"
        (git clone https://github.com/nvm-sh/nvm.git "${NVM_DIR}" && cd "${NVM_DIR}" && git checkout `git describe --abbrev=0 --tags --match "v[0-9]*" $(git rev-list --tags --max-count=1)`)

        # TODO rename file
        tee "${ROOT_DIRECTORY_STRUCTURE}/scripts/node.sh" <<EOF
export NVM_DIR="${ROOT_DIRECTORY_STRUCTURE}/applications/nvm"
[ -s "\${NVM_DIR}/nvm.sh" ] && \. "\${NVM_DIR}/nvm.sh"
[ -s "\${NVM_DIR}/bash_completion" ] && \. "\${NVM_DIR}/bash_completion"
EOF

    fi

    question "Do you want to have custom terminal colours?"

    if [ $? = 0 ]; then

        text "Generating custom colors file."
        tee "${ROOT_DIRECTORY_STRUCTURE}/scripts/colors.sh" <<EOF
if [ -x "\$(command -v vivid)" ]; then
    export LS_COLORS="\$(vivid generate dracula)"
fi
EOF

    fi

    section "Useful applications"

    question "Do you want to install archiving tools (p7zip and unrar)?"

    if [ $? = 0 ]; then

        text "Installing command line archiving tools."
        sudo dnf install p7zip p7zip-plugins unrar file-roller
    fi

    question "Do you want to install the latest Java SDK?"

    if [ $? = 0 ]; then
        text "Installing the latest Java SDK."
        sudo dnf install java-latest-openjdk java-latest-openjdk-jmods java-latest-openjdk-devel java-latest-openjdk-headless
    fi

    question "Do you want to install other useful tools?"

    if [ $? = 0 ]; then

        text "Select which packages you want to install."

        declare -t PACKAGES_TO_INSTALL=(
            "ack"
            "bat"
            "bleachbit"
            "fdupes"
            "ffmpeg"
            "fortune-mod"
            "git-delta"
            "git-lfs"
            "hyperfine"
        )

        readarray -t SELECTED_PACKAGES <<< $(gum choose --no-limit --height 15 "${PACKAGES_TO_INSTALL[@]}")
        PACKAGE_INSTALL_LIST=$(printf " %s" "${SELECTED_PACKAGES[@]}")
        
        text "Installing packages."
        sudo dnf install ${PACKAGE_INSTALL_LIST:1} -y
    fi

    section "git configuration"

GIT_USERNAME=$(gum input --prompt "Your full name: ")
GIT_EMAIL=$(gum input --prompt "Your e-mail address: ")

    text "Generating configuration file for git."
    tee "${HOME}/.gitconfig" <<EOF
[user]
	name = ${GIT_USERNAME}
	email = ${GIT_EMAIL}
[core]
	editor = vim
	pager = delta
[push]
	default = simple
[interactive]
	diffFilter = delta --color-only
[delta]
	side-by-side = true
	line-numbers = true
EOF

    section "VSCodium configuration"

    question "Do you want to install and configure VSCodium?"

    if [ $? = 0 ]; then

        text "Adding the RPM repository."
        sudo tee "/etc/yum.repos.d/vscodium.repo" <<EOF
[paulcarroty-vscodium-repo]
name=Pavlo Rudyi's VSCodium repo
baseurl=https://paulcarroty.gitlab.io/vscodium-deb-rpm-repo/rpms/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg
metadata_expire=1h
EOF

        text "Installing the VSCodium application."
        sudo dnf install codium

        text "Preparing the configuration directory."
        mkdir -p "${HOME}/.config/VSCodium/User"

        text "Writing the configuration file."
        tee "${HOME}/.config/VSCodium/User/settings.json" <<EOF
{
    "workbench.startupEditor": "none",
    "editor.fontFamily": "'JetBrainsMono Nerd Font',  'Droid Sans Mono', 'monospace', monospace",
    "editor.fontLigatures": true,
    "security.workspace.trust.untrustedFiles": "open",
    "security.workspace.trust.startupPrompt": "never",
    "security.workspace.trust.enabled": false,
    "window.restoreWindows": "none",
    "workbench.colorTheme": "Default Light Modern"
}
EOF

    fi

    section "TeX Live configuration"

    question "Do you want to configure TeX Live?"

    if [ $? = 0 ]; then
    
        text "Creating script for TeX Live."
        sudo tee "/etc/profile.d/texlive.sh" <<EOF
#!/bin/bash
pathmunge () {
    if ! echo \$PATH | /bin/grep -E -q "(^|:)\$1($|:)" ; then
        if [ "\$2" = "after" ] ; then
            PATH=\$PATH:\$1
        else
            PATH=\$1:\$PATH
        fi
    fi
}
pathmunge /opt/texbin
unset pathmunge
EOF

    fi

    section "Custom font configuration"

    question "Do you want to install custom fonts?"

    if [ $? = 0 ]; then

        FONT_VERSION=$(gum input --prompt "Latest version of Nerd Fonts: " --value "3.2.1")

        text "Creating local font directory."
        mkdir -p "${HOME}/.local/share/fonts"

        text "Downloading Caskaydia Cove."
        wget https://github.com/ryanoasis/nerd-fonts/releases/download/${FONT_VERSION}/CascadiaCode.zip

        text "Extracting file."
        unzip CascadiaCode.zip -d "${HOME}/.local/share/fonts/Caskaydia Cove"

        text "Downloading Fira Code."
        wget https://github.com/ryanoasis/nerd-fonts/releases/download/${FONT_VERSION}/FiraCode.zip

        text "Extracting file."
        unzip FiraCode.zip -d "${HOME}/.local/share/fonts/Fira Code"

        text "Downloading Fura Mono."
        wget https://github.com/ryanoasis/nerd-fonts/releases/download/${FONT_VERSION}/FiraMono.zip

        text "Extracting file."
        unzip FiraMono.zip -d "${HOME}/.local/share/fonts/Fura Mono"

        text "Downloading JetBrains Mono."
        wget https://github.com/ryanoasis/nerd-fonts/releases/download/${FONT_VERSION}/JetBrainsMono.zip

        text "Extracting file."
        unzip JetBrainsMono.zip -d "${HOME}/.local/share/fonts/JetBrains Mono"

        text "Removing unused files."
        find "${HOME}/.local/share/fonts" -type f -not -name "*.ttf" -not -name "*.otf" -exec rm {} \;

        text "Generating font cache."
        fc-cache -fv "${HOME}/.local/share/fonts"
    fi

    section "yt-dlp installation and configuration"

    question "Do you want to install and configure yt-dlp?"

    if [ $? = 0 ]; then

        text "Downloading yt-dlp script."
        wget https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp

        text "Moving script to the installation directory."
        mv yt-dlp "${HOME}/.local/bin"

        text "Changing execute permissions."
        chmod +x "${HOME}/.local/bin/yt-dlp"
    fi

fi

text "That's all, folks!"
