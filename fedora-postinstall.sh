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

declare -A NERD_FONTS=(
    ["Caskaydia Cove"]="CascadiaCode"
    ["Fira Code"]="FiraCode"
    ["Fura Mono"]="FiraMono"
    ["JetBrains Mono"]="JetBrainsMono"
)

GUM_LINK="https://github.com/charmbracelet/gum/releases/download/v0.14.5/gum_0.14.5_Linux_x86_64.tar.gz"

SCRIPT_PATH=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

GUM="${SCRIPT_PATH}/gum"

if [ ! -x "${GUM}" ]; then
    echo "gum is needed for this script, please wait."
    wget "${GUM_LINK}" -O gum.tar.gz
    tar xvzf gum.tar.gz --wildcards --no-anchored '*gum' && mv gum_*/gum . && rm -rf gum_*
fi

function chapter {
    ${GUM} style --border double \
        --align center \
        --width 60 \
        --padding "1 0" \
        --foreground 10 \
        --border-foreground 10 \
        "$1"
}

function section {
    ${GUM} style --width 60 \
        --border rounded \
        --align center \
        --foreground 12 \
        --border-foreground 12 \
        "$1"
}

function question {
    ${GUM} confirm \
        --prompt.foreground=6 \
        --selected.background=6 \
        "$1"
}

function text {
    ${GUM} style --width 60 \
        --margin "1 0" \
    "$1"    
}

function info {
    ${GUM} style --width 60 \
        --foreground 11 \
        "$1"
}

FEDORA_VERSION=$(rpm -E %fedora)

chapter "Paulo's Fedora ${FEDORA_VERSION} post installation script"

question "Did you upgrade your system?" || exit 1

text "Welcome to my post installation script for Fedora! Please select which flavour of Fedora you are currently running."

FEDORA_FLAVOUR=$(${GUM} choose "Workstation" "Silverblue")

text "You are running Fedora ${FEDORA_FLAVOUR} ${FEDORA_VERSION}. Let's go!"

section "Flathub configuration"

question "Do you want to configure Flathub?"

if [ $? = 0 ]; then

    text "Let's configure the Flathub repository."

    info "Configuring Flathub."
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

    info "Enabling Flathub."
    flatpak remote-modify --enable flathub
    
fi

if [ "${FEDORA_FLAVOUR}" = "Silverblue" ]; then

    section "Flatpak cleanup"

    text "Fedora Silverblue comes with several applications installed as flatpaks. Would you like to remove some of them?"

    mapfile -t INSTALLED_FLATPAKS < <(flatpak list --app --columns=application)
    readarray -t FLATPAKS_TO_REMOVE <<< $(${GUM} choose --no-limit --height 15 "${INSTALLED_FLATPAKS[@]}")

    if [ -z "${FLATPAKS_TO_REMOVE}" ]; then
        text "You haven't selected any items from the list. Moving on."
    else
        text "You've selected ${#FLATPAKS_TO_REMOVE[@]} flatpak(s) to remove. Please wait."

        for FLATPAK_TO_REMOVE in "${FLATPAKS_TO_REMOVE[@]}"; do
            info "Removing ${FLATPAK_TO_REMOVE}."
            flatpak uninstall "${FLATPAK_TO_REMOVE}" -y
        done

        info "Removing unused framework(s)."
        flatpak uninstall --unused -y
    fi
else

    section "Package cleanup"

    text "Fedora Workstation comes with several applications that could be removed. Would you like to remove some of them?"

    readarray -t PACKAGES_TO_REMOVE <<< $(${GUM} choose --no-limit --height 15 "${EXISTING_PACKAGES[@]}")

    if [ -z "${PACKAGES_TO_REMOVE}" ]; then
        text "You haven't selected any items from the list. Moving on."
    else
        text "You've selected ${#PACKAGES_TO_REMOVE[@]} package(s) to remove. Please wait."

        PACKAGE_REMOVAL_LIST=$(printf " %s" "${PACKAGES_TO_REMOVE[@]}")

        info "Removing package(s)."
        sudo dnf remove ${PACKAGE_REMOVAL_LIST:1} -y

        info "Cleaning up orphan packages."
        sudo dnf autoremove -y
    fi

    section "RPMFusion configuration"

    question "Do you want to configure the RPMFusion repositories?"

    if [ $? = 0 ]; then

        text "Let's configure the RPMFusion repositories."

        info "Configuring the free repository."
        sudo dnf install https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VERSION}.noarch.rpm -y

        info "Configuring the non-free repository."
        sudo dnf install https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VERSION}.noarch.rpm -y

        rpm -qa | grep -i ffmpeg >/dev/null 2>&1 && section "ffmpeg configuration" && question "Do you want to replace Fedora's ffmpeg?"

        if [ $? = 0 ]; then
            
            info "Replacing Fedora's ffmpeg."
            sudo dnf swap ffmpeg-free ffmpeg --allowerasing -y
        fi
    fi
fi

section "Flatpak applications"

text "Do you want to install any of these Flatpak applications?"

readarray -t FLATPAKS_TO_INSTALL <<< $(${GUM} choose --no-limit --height 15 "${SUGGESTED_FLATPAKS[@]}")

if [ -z "${FLATPAKS_TO_INSTALL}" ]; then
    text "You haven't selected any items from the list. Moving on."
    FLATPAKS_KEEP_CACHE_LIST=""
else
    text "You've selected ${#FLATPAKS_TO_INSTALL[@]} flatpak(s) to install. Please wait."

    for FLATPAK_TO_INSTALL in "${FLATPAKS_TO_INSTALL[@]}"; do
        info "Installing ${FLATPAK_TO_REMOVE}."
        flatpak install flathub ${FLATPAK_TO_INSTALL} -y
    done

    text "Which Flatpak applications do you want to keep from cache cleaning?"

    readarray -t FLATPAKS_TO_KEEP_CACHE <<< $(${GUM} choose --no-limit --selected="com.github.tchx84.Flatseal" --height 15 "${FLATPAKS_TO_INSTALL[@]}")
    FLATPAKS_KEEP_CACHE_LIST=$(printf " -not -name %s" "${FLATPAKS_TO_KEEP_CACHE[@]}")    
fi

section "GNOME configuration"

question "Do you want to improve font rendering?"

if [ $? = 0 ]; then

    info "Font antialiasing."
    gsettings set org.gnome.desktop.interface font-antialiasing rgba

    info "Font hinting."
    gsettings set org.gnome.desktop.interface font-hinting slight
fi

question "Do you want to configure the GNOME text editor?"

if [ $? = 0 ]; then

    info "Highlighting current line."
    gsettings set org.gnome.TextEditor highlight-current-line true

    info "Disabling restore session."
    gsettings set org.gnome.TextEditor restore-session false

    info "Showing grid."
    gsettings set org.gnome.TextEditor show-grid true

    info "Showing line numbers."
    gsettings set org.gnome.TextEditor show-line-numbers true

    info "Showing right margin."
    gsettings set org.gnome.TextEditor show-right-margin true

    info "Disabling spellcheck."
    gsettings set org.gnome.TextEditor spellcheck false
fi

question "Do you want to configure the GNOME clock?"

if [ $? = 0 ]; then

    info "Showing weekday."
    gsettings set org.gnome.desktop.interface clock-show-weekday true
fi

question "Do you want to disable autorum for removable media?"

if [ $? = 0 ]; then

    info "Disabling autorun for removable media."
    gsettings set org.gnome.desktop.media-handling autorun-never true
fi

question "Do you want to configure your laptop touchpad?"

if [ $? = 0 ]; then

    info "Enabling tap to click."
    gsettings set org.gnome.desktop.peripherals.touchpad tap-to-click true

    info "Enabling two finger scrolling."
    gsettings set org.gnome.desktop.peripherals.touchpad two-finger-scrolling-enabled true
fi

question "Do you want to disable notification banners?"

if [ $? = 0 ]; then

    info "Disabling show banners."
    gsettings set org.gnome.desktop.notifications show-banners false

    info "Disabling show in lock screen."
    gsettings set org.gnome.desktop.notifications show-in-lock-screen false
fi

question "Do you want to disable technical reports?"

if [ $? = 0 ]; then

    info "Disabling problem reporting."
    gsettings set org.gnome.desktop.privacy report-technical-problems false
fi

question "Do you want to configure Nautilus?"

if [ $? = 0 ]; then

    info "Setting default folder viewer."
    gsettings set org.gnome.nautilus.preferences default-folder-viewer icon-view

    info "Disabling image thumbnails."
    gsettings set org.gnome.nautilus.preferences show-image-thumbnails never
fi

question "Do you want to enable night light?"

if [ $? = 0 ]; then

    info "Enabling night light."
    gsettings set org.gnome.settings-daemon.plugins.color night-light-enabled true
fi

question "Do you want to disable notifications from GNOME Software?"

if [ $? = 0 ]; then

    info "Disabling download updates."
    gsettings set org.gnome.software download-updates false

    info "Disabling notify updates."
    gsettings set org.gnome.software download-updates-notify false
fi

section "Hostname configuration"

MACHINE_NAME=$(${GUM} input --prompt "Your machine name: ")

info "Configuring hostname."
sudo hostnamectl hostname "${MACHINE_NAME}"

text "Your Fedora ${FEDORA_FLAVOUR} ${FEDORA_VERSION} is now named ${MACHINE_NAME}."

section "Paulo's custom configuration for the home directory"

question "Do you want to create a custom configuration for your home directory?"

if [ $? = 0 ]; then

    ROOT_DIRECTORY_STRUCTURE="${HOME}/.${MACHINE_NAME}"

    text "The root directory structure will be located at ${ROOT_DIRECTORY_STRUCTURE} (Paulo's configuration)."

    info "Creating root directory."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}"

    info "Creating directory for applications."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/applications"

    info "Creating directory for config files."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/config"

    info "Creating directory for profile."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/profile"

    info "Creating directory for scripts."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/scripts"

    info "Creating directory for general stuff."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/stuff"

    info "Creating directory for environments."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/environments"

    info "Updating bash entry point."
    tee --append "${HOME}/.bashrc" <<EOF

# my personal configuration
if [ -e "${ROOT_DIRECTORY_STRUCTURE}/scripts/bash.sh" ]; then
    source "${ROOT_DIRECTORY_STRUCTURE}/scripts/bash.sh"
fi
EOF

    info "Creating main file for bash."
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

    info "Creating aliases file."
    tee "${ROOT_DIRECTORY_STRUCTURE}/scripts/aliases.sh" <<EOF
# wrapper around some tools and commands I typically use in this computer
function ${MACHINE_NAME} {
    if [ "\$#" -ne 2 ]; then
        echo "Usage: ${MACHINE_NAME} <action> <target>" >&2
        echo
        echo "╭──────────┬────────────────────────────────────────────────╮"
        echo "│ Actions  │ Targets                                        │"
        echo "├──────────┼────────────────────────────────────────────────┤"
        echo "│ upgrade  │ system, starship, tex, sdk, vim, node, youtube │"
        echo "│          │ rust, deno, bun, flatpak, conda, world         │"
        echo "├──────────┼────────────────────────────────────────────────┤"
        echo "│ clean    │ flatpak, files, cache, system                  │"
        echo "├──────────┼────────────────────────────────────────────────┤"
        echo "│ config   │ menu                                           │"
        echo "├──────────┼────────────────────────────────────────────────┤"
        echo "│ use      │ sdk, conda, node                               │"
        echo "╰──────────┴────────────────────────────────────────────────╯"
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
                        eval "\$("${ROOT_DIRECTORY_STRUCTURE}/applications/miniconda/3/bin/conda" shell.bash hook)"
                        conda upgrade --all
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
                    echo
                    echo "╭──────────┬────────────────────────────────────────────────╮"
                    echo "│ upgrade  │ system, starship, tex, sdk, vim, node, youtube │"
                    echo "│          │ rust, deno, bun, flatpak, conda, world         │"
                    echo "╰──────────┴────────────────────────────────────────────────╯"
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
                    echo
                    echo "╭──────────┬────────────────────────────────────────────────╮"
                    echo "│ clean    │ flatpak, files, cache, system                  │"
                    echo "╰──────────┴────────────────────────────────────────────────╯"
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
                    echo
                    echo "╭──────────┬────────────────────────────────────────────────╮"
                    echo "│ config   │ menu                                           │"
                    echo "╰──────────┴────────────────────────────────────────────────╯"

                ;;
            esac
        ;;

        use)
            case "\$2" in
                sdk)
                    if [ -e "${ROOT_DIRECTORY_STRUCTURE}/scripts/sdk.sh" ]; then
                        source "${ROOT_DIRECTORY_STRUCTURE}/scripts/sdk.sh"
                    fi
                ;;

                conda)
                    if [ -e "${ROOT_DIRECTORY_STRUCTURE}/applications/miniconda/3/bin/conda" ]; then
                        eval "\$("${ROOT_DIRECTORY_STRUCTURE}/applications/miniconda/3/bin/conda" shell.bash hook)"
                    fi
                ;;

                node)
                    if [ -e "${ROOT_DIRECTORY_STRUCTURE}/scripts/node.sh" ]; then
                        source "${ROOT_DIRECTORY_STRUCTURE}/scripts/node.sh"
                    fi
                ;;

                *)
                    echo "I don't know this target."
                    echo
                    echo "╭──────────┬────────────────────────────────────────────────╮"
                    echo "│ use      │ sdk, conda, node                               │"
                    echo "╰──────────┴────────────────────────────────────────────────╯"
                ;;
            esac
        ;;

        *)
            echo "I don't know this action."
            echo
            echo "╭──────────┬────────────────────────────────────────────────╮"
            echo "│ Actions  │ Targets                                        │"
            echo "├──────────┼────────────────────────────────────────────────┤"
            echo "│ upgrade  │ system, starship, tex, sdk, vim, node, youtube │"
            echo "│          │ rust, deno, bun, flatpak, conda, world         │"
            echo "├──────────┼────────────────────────────────────────────────┤"
            echo "│ clean    │ flatpak, files, cache, system                  │"
            echo "├──────────┼────────────────────────────────────────────────┤"
            echo "│ config   │ menu                                           │"
            echo "├──────────┼────────────────────────────────────────────────┤"
            echo "│ use      │ sdk, conda, node                               │"
            echo "╰──────────┴────────────────────────────────────────────────╯"
        ;;
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
        
        info "Preparing the installation directory."
        mkdir -p "${HOME}/.local/bin"
        
        info "Installing starship."
        sh -c "$(curl -fsSL https://starship.rs/install.sh)" -- -b "${HOME}/.local/bin" -y

        info "Preparing the configuration directory."
        mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/config/starship"

        info "Creating the configuration file."
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
        info "Installing the SDKman binary."
        export SDKMAN_DIR="${ROOT_DIRECTORY_STRUCTURE}/applications/sdkman" && curl -s "https://get.sdkman.io?rcupdate=false" | bash

        info "Creating wrapper script."
        tee "${ROOT_DIRECTORY_STRUCTURE}/scripts/sdk.sh" <<EOF
# moving these lines to a single file to source it on demand
export SDKMAN_DIR="${ROOT_DIRECTORY_STRUCTURE}/applications/sdkman"
[[ -s "${ROOT_DIRECTORY_STRUCTURE}/applications/sdkman/bin/sdkman-init.sh" ]] && source "${ROOT_DIRECTORY_STRUCTURE}/applications/sdkman/bin/sdkman-init.sh"
EOF
    fi

    question "Do you want to install Rust?"

    if [ $? = 0 ]; then
        info "Preparing the Rust environment."
        mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/environments/rust"
        
        info "Exporting environment variables."
        export CARGO_HOME="${ROOT_DIRECTORY_STRUCTURE}/environments/rust/cargo"
        export RUSTUP_HOME="${ROOT_DIRECTORY_STRUCTURE}/applications/rustup"

        info "Installing binaries."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

        info "Writing helper script."
        tee "${ROOT_DIRECTORY_STRUCTURE}/scripts/rust.sh" <<EOF
export CARGO_HOME="${ROOT_DIRECTORY_STRUCTURE}/environments/rust/cargo"
export RUSTUP_HOME="${ROOT_DIRECTORY_STRUCTURE}/applications/rustup"
export PATH=\${PATH}:\${CARGO_HOME}/bin
EOF
    fi

    question "Do you want to install and configure vim?"

    if [ $? = 0 ]; then

        info "Installing vim."
        sudo dnf install vim -y

        info "Installing the plug-in manager for vim."
        curl -fLo "${HOME}/.vim/autoload/plug.vim" --create-dirs https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

        info "Creating the configuration file."
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
        info "Installing neovim."
        sudo dnf install neovim -y

        info "Installing the plug-in manager for neovim."
        curl -fLo "${HOME}/.local/share/nvim/site/autoload/plug.vim" --create-dirs https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

        info "Creating configuration directory for neovim."
        mkdir -p "${HOME}/.config/nvim"

        info "Creating configuration file for neovim."
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

        info "Installing nvm."
        NVM_DIR="${ROOT_DIRECTORY_STRUCTURE}/applications/nvm"
        (git clone https://github.com/nvm-sh/nvm.git "${NVM_DIR}" && cd "${NVM_DIR}" && git checkout `git describe --abbrev=0 --tags --match "v[0-9]*" $(git rev-list --tags --max-count=1)`)

        info "Creating configuration script."
        tee "${ROOT_DIRECTORY_STRUCTURE}/scripts/node.sh" <<EOF
export NVM_DIR="${ROOT_DIRECTORY_STRUCTURE}/applications/nvm"
[ -s "\${NVM_DIR}/nvm.sh" ] && \. "\${NVM_DIR}/nvm.sh"
[ -s "\${NVM_DIR}/bash_completion" ] && \. "\${NVM_DIR}/bash_completion"
EOF

    fi

    question "Do you want to have custom terminal colours?"

    if [ $? = 0 ]; then

        info "Generating custom colors file."
        tee "${ROOT_DIRECTORY_STRUCTURE}/scripts/colors.sh" <<EOF
if [ -x "\$(command -v vivid)" ]; then
    export LS_COLORS="\$(vivid generate dracula)"
fi
EOF

    fi

    section "Useful applications"

    question "Do you want to install archiving tools (p7zip and unrar)?"

    if [ $? = 0 ]; then

        info "Installing command line archiving tools."
        sudo dnf install p7zip p7zip-plugins unrar file-roller
    fi

    question "Do you want to install the latest Java SDK?"

    if [ $? = 0 ]; then
        info "Installing the latest Java SDK."
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

        readarray -t SELECTED_PACKAGES <<< $(${GUM} choose --no-limit --height 15 "${PACKAGES_TO_INSTALL[@]}")
        PACKAGE_INSTALL_LIST=$(printf " %s" "${SELECTED_PACKAGES[@]}")
        
        info "Installing packages."
        sudo dnf install ${PACKAGE_INSTALL_LIST:1} -y
    fi

    section "git configuration"

GIT_USERNAME=$(${GUM} input --prompt "Your full name: ")
GIT_EMAIL=$(${GUM} input --prompt "Your e-mail address: ")

    info "Generating configuration file for git."
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

        info "Adding the RPM repository."
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

        info "Installing the VSCodium application."
        sudo dnf install codium -y

        info "Preparing the configuration directory."
        mkdir -p "${HOME}/.config/VSCodium/User"

        info "Writing the configuration file."
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
    
        info "Creating script for TeX Live."
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

        FONT_VERSION=$(${GUM} input --prompt "Latest version of Nerd Fonts: " --value "3.2.1")

        info "Creating local font directory."
        mkdir -p "${HOME}/.local/share/fonts"

        for NERD_FONT in "${!NERD_FONTS[@]}" ; do
            info "Downloading ${NERD_FONT}."
            wget "https://github.com/ryanoasis/nerd-fonts/releases/download/v${FONT_VERSION}/${NERD_FONTS[${NERD_FONT}]}.zip"

            info "Extracting file."    
            unzip "${NERD_FONTS[${NERD_FONT}]}.zip" -d "${HOME}/.local/share/fonts/${NERD_FONT}"
        done

        info "Removing unused files."
        find "${HOME}/.local/share/fonts" -type f -not -name "*.ttf" -not -name "*.otf" -exec rm {} \;

        info "Generating font cache."
        fc-cache -fv "${HOME}/.local/share/fonts"

        info "Regenerating font cache."
        fc-cache -fv "${HOME}/.local/share/fonts"
    fi

    section "yt-dlp installation and configuration"

    question "Do you want to install and configure yt-dlp?"

    if [ $? = 0 ]; then

        info "Downloading yt-dlp script."
        wget https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp

        info "Moving script to the installation directory."
        mv yt-dlp "${HOME}/.local/bin"

        info "Changing execute permissions."
        chmod +x "${HOME}/.local/bin/yt-dlp"
    fi

    section "Extra binaries"

    question "Do you want to install extra binaries for your system?"

    if [ $? = 0 ]; then

        if [ ! -x "$(command -v jq)" ]; then

            info "Installing jq."
            sudo dnf install jq
        fi
        
        text "The script will get the latest versions of a list of binaries from the GitHub API. Please wait."

        info "Getting latest version and downloading 'vivid'."
        test -f vivid.json || wget -q -O vivid.json https://api.github.com/repos/sharkdp/vivid/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux-gnu")).browser_download_url' vivid.json)

        info "Getting latest version and downloading 'gum'."
        test -f gum.json || wget -q -O gum.json https://api.github.com/repos/charmbracelet/gum/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("Linux") and endswith("tar.gz")).browser_download_url' gum.json)

        info "Getting latest version and downloading 'vhs'."
        test -f vhs.json || wget -q -O vhs.json https://api.github.com/repos/charmbracelet/vhs/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("Linux") and endswith("tar.gz")).browser_download_url' vhs.json)

        info "Getting latest version and downloading 'ttyd'."
        test -f ttyd.json || wget -q -O ttyd.json https://api.github.com/repos/tsl0922/ttyd/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("x86_64")).browser_download_url' ttyd.json)

        info "Getting latest version and downloading 'trivy'."
        test -f trivy.json || wget -q -O trivy.json https://api.github.com/repos/aquasecurity/trivy/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("Linux") and contains("64bit") and endswith("tar.gz")).browser_download_url' trivy.json)

        info "Getting latest version and downloading 'trippy'."
        test -f trippy.json || wget -q -O trippy.json https://api.github.com/repos/fujiapple852/trippy/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux-gnu") and endswith("tar.gz")).browser_download_url' trippy.json)

        info "Getting latest version and downloading 'trdsql'."
        test -f trdsql.json || wget -q -O trdsql.json https://api.github.com/repos/noborus/trdsql/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("linux_amd64")).browser_download_url' trdsql.json)

        info "Getting latest version and downloading 'yq'."
        test -f yq.json || wget -q -O yq.json https://api.github.com/repos/mikefarah/yq/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("linux_amd64") and endswith("tar.gz")).browser_download_url' yq.json)

        info "Getting latest version and downloading 'zellij'."
        test -f zellij.json || wget -q -O zellij.json https://api.github.com/repos/zellij-org/zellij/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux") and endswith("tar.gz")).browser_download_url' zellij.json)

        info "Getting latest version and downloading 'surreal'."
        test -f surreal.json || wget -q -O surreal.json https://api.github.com/repos/surrealdb/surrealdb/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("amd64") and contains("linux") and endswith("tgz")).browser_download_url' surreal.json)

        info "Getting latest version and downloading 'ripgrep'."
        test -f ripgrep.json || wget -q -O ripgrep.json https://api.github.com/repos/BurntSushi/ripgrep/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux-musl") and endswith("tar.gz")).browser_download_url' ripgrep.json)

        info "Getting latest version and downloading 'procs'."
        test -f procs.json || wget -q -O procs.json https://api.github.com/repos/dalance/procs/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux") and endswith("zip")).browser_download_url' procs.json)

        info "Getting latest version and downloading 'pingu'."
        test -f pingu.json || wget -q -O pingu.json https://api.github.com/repos/sheepla/pingu/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("Linux") and endswith("tar.gz")).browser_download_url' pingu.json)

        info "Getting latest version and downloading 'picocrypt'."
        test -f picocrypt.json || wget -q -O picocrypt.json https://api.github.com/repos/Picocrypt/CLI/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("amd64") and contains("linux")).browser_download_url' picocrypt.json)

        info "Getting latest version and downloading 'ouch'."
        test -f ouch.json || wget -q -O ouch.json https://api.github.com/repos/ouch-org/ouch/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux-gnu")).browser_download_url' ouch.json)

        info "Getting latest version and downloading 'lsd'."
        test -f lsd.json || wget -q -O lsd.json https://api.github.com/repos/lsd-rs/lsd/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux-gnu")).browser_download_url' lsd.json)

        info "Getting latest version and downloading 'lapce'."
        test -f lapce.json || wget -q -O lapce.json https://api.github.com/repos/lapce/lapce/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("amd64") and contains("linux")).browser_download_url' lapce.json)

        info "Getting latest version and downloading 'jless'."
        test -f jless.json || wget -q -O jless.json https://api.github.com/repos/PaulJuliusMartinez/jless/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux")).browser_download_url' jless.json)

        info "Getting latest version and downloading 'ipinfo'."
        test -f ipinfo.json || wget -q -O ipinfo.json https://api.github.com/repos/ipinfo/cli/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("amd64") and contains("linux") and endswith("tar.gz")).browser_download_url' ipinfo.json)

        info "Getting latest version and downloading 'hexyl'."
        test -f hexyl.json || wget -q -O hexyl.json https://api.github.com/repos/sharkdp/hexyl/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux-gnu") and endswith("tar.gz")).browser_download_url' hexyl.json)

        info "Getting latest version and downloading 'grex'."
        test -f grex.json || wget -q -O grex.json https://api.github.com/repos/pemistahl/grex/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux") and endswith("tar.gz")).browser_download_url' grex.json)

        info "Getting latest version and downloading 'gping'."
        test -f gping.json || wget -q -O gping.json https://api.github.com/repos/orf/gping/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("Linux") and endswith("tar.gz")).browser_download_url' gping.json)

        info "Getting latest version and downloading 'glow'."
        test -f glow.json || wget -q -O glow.json https://api.github.com/repos/charmbracelet/glow/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("Linux") and endswith("tar.gz")).browser_download_url' glow.json)

        info "Getting latest version and downloading 'fx'."
        test -f fx.json || wget -q -O fx.json https://api.github.com/repos/antonmedv/fx/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("amd64") and contains("linux")).browser_download_url' fx.json)

        info "Getting latest version and downloading 'freeze'."
        test -f freeze.json || wget -q -O freeze.json https://api.github.com/repos/charmbracelet/freeze/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("Linux") and endswith("tar.gz")).browser_download_url' freeze.json)

        info "Getting latest version and downloading 'fd'."
        test -f fd.json || wget -q -O fd.json https://api.github.com/repos/sharkdp/fd/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux-gnu") and endswith("tar.gz")).browser_download_url' fd.json)

        info "Getting latest version and downloading 'f2'."
        test -f f2.json || wget -q -O f2.json https://api.github.com/repos/ayoisaiah/f2/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("amd64") and contains("linux") and endswith("tar.gz")).browser_download_url' f2.json)

        info "Getting latest version and downloading 'duf'."
        test -f duf.json || wget -q -O duf.json https://api.github.com/repos/muesli/duf/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux") and endswith("tar.gz")).browser_download_url' duf.json)

        info "Getting latest version and downloading 'duckdb'."
        test -f duckdb.json || wget -q -O duckdb.json https://api.github.com/repos/duckdb/duckdb/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("amd64") and contains("linux") and contains("cli")).browser_download_url' duckdb.json)

        info "Getting latest version and downloading 'deno'."
        test -f deno.json || wget -q -O deno.json https://api.github.com/repos/denoland/deno/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux-gnu") and contains("deno-") and endswith("zip")).browser_download_url' deno.json)

        info "Getting latest version and downloading 'bun'."
        test -f bun.json || wget -q -O bun.json https://api.github.com/repos/oven-sh/bun/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("linux") and endswith("x64.zip")).browser_download_url' bun.json)

        info "Getting latest version and downloading 'bottom'."
        test -f bottom.json || wget -q -O bottom.json https://api.github.com/repos/ClementTsang/bottom/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux") and endswith("gnu.tar.gz")).browser_download_url' bottom.json)

        info "Getting latest version and downloading 'binsider'."
        test -f binsider.json || wget -q -O binsider.json https://api.github.com/repos/orhun/binsider/releases/latest
        wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux-gnu") and endswith("tar.gz")).browser_download_url' binsider.json)

        text "Preparing to unpack binaries."

        info "Creating temporary directory."
        rm -f archives
        mkdir -p archives

        info "Moving files to temporary directory."
        find . -mindepth 1 -maxdepth 1 '(' -name "*.zip" -o -name "*.tar.gz" -o -name "*.tgz" ')' -exec mv {} archive/ \;

        info "Unpacking binaries."
        (cd archives && find -type f -name "*.tar.gz" -exec tar xzf {} \;)
        (cd archives && find -type f -name "*.tgz" -exec tar xzf {} \;)
        (cd archives && find -type f -name "*.zip" -exec unzip {} \;)

        info "Creating deployment directory."
        rm -f deploys
        mkdir -p deploys

        info "Moving binaries to the deployment directory."
        find archives -type f -executable -exec mv {} deploys/ \;

        info "Getting latest version and downloading 'vimv'."
        wget -q -O vimv https://raw.githubusercontent.com/thameera/vimv/master/vimv
        
        info "Making 'vimv' executable."
        chmod +x vimv

        info "Moving 'vimv' to the deployment directory."
        mv vimv deploys/

        info "Fixing 'yq' and moving to the deployment directory."
        mv deploys/yq_* deploys/yq

        info "Fixing 'ipinfo' and moving to the deployment directory."
        mv deploys/ipinfo_* deploys/ipinfo

        info "Fixing 'fx' and moving to the deployment directory."
        mv fx_* deploys/fx

        info "Fixing 'picocrypt' and moving to the deployment directory."
        mv picocrypt-* deploys/picocrypt

        info "Fixing 'ttyd' and moving to the deployment directory."
        mv ttyd.x* deploys/ttyd

        info "Removing unused files from the deployment directory."
        rm -f deploys/*.sh

        info "Moving binaries to the home directory."
        mkdir -p "${HOME}/.local/bin"
        (cd deploys && mv * "${HOME}/.local/bin/")
    fi

fi

text "That's all, folks!"
