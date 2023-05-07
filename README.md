# Fedora post installation guide

Welcome to my personal Fedora post installation guide. In this particular document, I try to describe most of steps I do after a clean install of this awesome Linux distribution. Ideas and suggestions were collected from different sources and also from personal experience. Use this guide at your own risk and have fun with Fedora! :wink:

**Note:** This repository holds a `fedora-postinstall.sh` script that pretty much automates the steps set forth in this guide. But of course, do not run it without understanding what it actually does!

## Upgrade the entire system

```bash
sudo dnf upgrade --refresh -y
```

## Enable RPM Fusion

1. Free:

    ```bash
    sudo dnf install \
    https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm -y
    ```

2. Non-free:

    ```bash
    sudo dnf install \
    https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm -y
    ```


## Improve font rendering

```bash
sudo dnf install gnome-tweaks
```

Now, open this tool we have just installed and set _subpixel antialising_ in the _Fonts_ section. Alternatively, we can use the terminal to adjust such things:

1. Font antialiasing

    ```bash
    gsettings set org.gnome.desktop.interface font-antialiasing rgba
    ```

2. Font hinting

    ```bash
    gsettings set org.gnome.desktop.interface font-hinting slight
    ```

## Configuring the GNOME text editor

1. Highlighting current line

    ```bash
    gsettings set org.gnome.TextEditor highlight-current-line true
    ```

2. Disabling restore session

    ```bash
    gsettings set org.gnome.TextEditor restore-session false
    ```

3. Showing grid

    ```bash
    gsettings set org.gnome.TextEditor show-grid true
    ```

4. Showing line numbers

    ```bash
    gsettings set org.gnome.TextEditor show-line-numbers true
    ```

5. Showing right margin

    ```bash
    gsettings set org.gnome.TextEditor show-right-margin true
    ```

6. Disabling spellcheck

    ```bash
    gsettings set org.gnome.TextEditor spellcheck false
    ```

## Configuring the interface clock

```bash
gsettings set org.gnome.desktop.interface clock-show-weekday true
```

## Removable media

```bash
gsettings set org.gnome.desktop.media-handling autorun-never true
```

## Configuring touchpad

1. Enabling tap to click

    ```bash
    gsettings set org.gnome.desktop.peripherals.touchpad tap-to-click true
    ```

2. Enabling two finger scrolling

    ```bash
    gsettings set org.gnome.desktop.peripherals.touchpad two-finger-scrolling-enabled true
    ```

## Configuring notifications

1. Disabling show banners

    ```bash
    gsettings set org.gnome.desktop.notifications show-banners false
    ```

2. Disabling show in lock screen

    ```bash
    gsettings set org.gnome.desktop.notifications show-in-lock-screen false
    ```

## Technical problems

```bash
gsettings set org.gnome.desktop.privacy report-technical-problems false
```

## Configuring Nautilus

1. Setting default folder viewer

    ```bash
    gsettings set org.gnome.nautilus.preferences default-folder-viewer icon-view
    ```

2. Disabling image thumbnails

    ```bash
    gsettings set org.gnome.nautilus.preferences show-image-thumbnails never
    ```

## Night light

```bash
gsettings set org.gnome.settings-daemon.plugins.color night-light-enabled true
```

## Configuring GNOME Software

1. Disabling download updates

    ```bash
    gsettings set org.gnome.software download-updates false
    ```

2. Disabling notify updates

    ```bash
    gsettings set org.gnome.software download-updates-notify false
    ```

## Setting hostname

```bash
sudo hostnamectl hostname <your host name>
```

## Removal of certain GNOME applications

```bash
sudo dnf remove gnome-calendar gnome-clocks gnome-characters \
gnome-contacts gnome-maps gnome-user-docs gnome-weather \
libreoffice* rhythmbox simple-scan totem gnome-boxes \
mediawriter
```

## Enabling Flathub

1. Adding repository

    ```bash
    flatpak remote-add --if-not-exists \
    flathub https://flathub.org/repo/flathub.flatpakrepo
    ```

2. Enabling repository

    ```bash
    flatpak remote-modify --enable flathub
    ```

## My custom `/opt` directory structure

```bash
WHO=$(whoami)
sudo mkdir -p "/opt/$WHO"
sudo chown $WHO:$WHO "/opt/$WHO"
mkdir -p "/opt/$WHO/applications"
mkdir -p "/opt/$WHO/profile"
mkdir -p "/opt/$WHO/scripts"
mkdir -p "/opt/$WHO/stuff"
mkdir -p "/opt/$WHO/environments"
mkdir -p "/opt/$WHO/config"
```

## Configuring bash

1. Updating `.bashrc`

    ```bash
    printf "\n# my personal configuration\nsource /opt/$WHO/scripts/bash.sh" | \
    tee --append /home/$WHO/.bashrc
    ```

2. Creating my personal bash configuration

    ```bash
    tee /opt/$WHO/scripts/bash.sh <<EOF
    # check if fortune exists and displays a message
    if [ -f /usr/bin/fortune ]; then
        /usr/bin/fortune
    fi

    # loads the aliases for this machine
    source /opt/$WHO/scripts/aliases.sh

    # loads the Rust config
    source /opt/$WHO/scripts/rust.sh

    # set the configuration and log settings for starship
    export STARSHIP_CONFIG=/opt/$WHO/config/starship/starship.toml
    export STARSHIP_LOG="error"

    # init starship prompt
    eval "\$(starship init bash)"
    EOF
    ```

3. Creating aliases

    ```bash
    MACHINENAME=<my machine name>
    tee /opt/$WHO/scripts/aliases.sh <<EOF
    # wrapper around some tools and commands I typically use in this computer
    function $MACHINENAME() {
        if [ "\$#" -ne 1 ]; then
        echo "Usage: $MACHINENAME <action>" >&2
        return 1
        fi

        case "\$1" in
            starship)
                sh -c "\$(curl -fsSL https://starship.rs/install.sh)" -- -b /home/$WHO/.local/bin -y
                ;;
            debris)
                bleachbit --preset --clean system.custom
                ;;
            declutter)
                bleachbit --preset --clean system.custom
                gio trash --empty
                shutdown -h now
                ;;
            tlmgr)
                tlmgr update --self --all
                ;;
            youtube)
                yt-dlp -U
                ;;
            sdk)
                source /opt/$WHO/scripts/sdk.sh
                ;;
            rust)
                rustup upgrade
                ;;
            reset-fp)
                find /home/$WHO/.var/app -maxdepth 1 -mindepth 1 \
                -not -name "org.keepassxc.KeePassXC" \
                -not -name "com.github.tchx84.Flatseal" \
                -type d -exec rm -rf "{}" \;
                find /run/user/$(id --user)/app -maxdepth 1 -mindepth 1 \
                -type d -exec rm -rf "{}" \;
                ;;
            flatpak)
                flatpak upgrade -y
                flatpak remove --unused
                ;;
            vim)
                vim -c "PlugUpgrade" -c "PlugUpdate" -c "q" -c "q"
                ;;
            *)
                echo "I don't know this action."
                ;;
        esac
    }

    # extracts a playlist from YouTube and creates a proper list
    function playlist() {
    if [ "\$#" -ne 2 ]; then
        echo "Usage: playlist <link> <title>" >&2
        return 1
        fi
        yt-dlp -f 18 "\$1" -o "\$2, part %(video_autonumber)s.%(ext)s"
    }
    EOF
    ```

## Installing the starship prompt

```bash
mkdir -p "~/.local/bin"
sh -c "$(curl -fsSL https://starship.rs/install.sh)" -- -b /home/$WHO/.local/bin -y
mkdir -p "/opt/$WHO/config/starship"
tee /opt/$WHO/config/starship/starship.toml <<EOF
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
```

## Installing SDKman

1. Installing the binary

    ```bash
    export SDKMAN_DIR="/opt/$WHO/applications/sdkman" && \
    curl -s "https://get.sdkman.io?rcupdate=false" | bash
    ```

2. Creating the wrapper script

    ```bash
    tee /opt/$WHO/scripts/sdk.sh <<EOF
    # moving these lines to a single file to source it on demand
    export SDKMAN_DIR="/opt/$WHO/applications/sdkman"
    [[ -s "/opt/$WHO/applications/sdkman/bin/sdkman-init.sh" ]] && \
    source "/opt/$WHO/applications/sdkman/bin/sdkman-init.sh"
    EOF
    ```

## Installing Rust

1. Preparing the environment

    ```bash
    mkdir -p "/opt/$WHO/environments/rust"
    export CARGO_HOME=/opt/$WHO/environments/rust/cargo
    export RUSTUP_HOME=/opt/$WHO/applications/rustup
    ```

2. Installing the binaries

    ```bash
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
    ```

3. Writing the helper script

    ```bash
    tee /opt/$WHO/scripts/rust.sh <<EOF
    export CARGO_HOME=/opt/$WHO/environments/rust/cargo
    export RUSTUP_HOME=/opt/$WHO/applications/rustup
    export PATH=\${PATH}:\${CARGO_HOME}/bin
    EOF
    ```

## Installing vim and neovim

1. Installing the binaries

    ```bash
    sudo dnf install vim neovim
    ```

2. Installing the plug-in manager for vim and neovim

    ```bash
    curl -fLo /home/$WHO/.vim/autoload/plug.vim \
    --create-dirs https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
    curl -fLo /home/$WHO/.local/share/nvim/site/autoload/plug.vim \
    --create-dirs https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
    ```

3. Creating configuration file for vim

    ```bash
    tee /home/$WHO/.vimrc <<EOF
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
    ```

4. Creating configuration file for neovim

    ```bash
    mkdir -p "/home/$WHO/.config/nvim"
    tee /home/$WHO/.config/nvim/init.vim <<EOF
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
    Plug 'nvim-treesitter/nvim-treesitter'
    Plug 'Eandrju/cellular-automaton.nvim'

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
    ```

## Installing command line archiving tools

```bash
sudo dnf install p7zip p7zip-plugins unrar file-roller
```

## Installing the latest Java SDK

```bash
sudo dnf install java-latest-openjdk java-latest-openjdk-jmods \
java-latest-openjdk-devel java-latest-openjdk-headless
```

## Installing assorted useful tools

```bash
sudo dnf install ack bat hyperfine \
git-delta ffmpeg fdupes fortune-mod
```

## Writing my git configuration

```bash
tee /home/$WHO/.gitconfig <<EOF
[user]
	name = $GITNAME
	email = $GITEMAIL
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
```

## Installing VSCodium

1. Adding RPM repository

    ```bash
    sudo tee /etc/yum.repos.d/vscodium.repo <<EOF
    [paulcarroty-vscodium-repo]
    name=Pavlo Rudyi's VSCodium repo
    baseurl=https://paulcarroty.gitlab.io/vscodium-deb-rpm-repo/rpms/
    enabled=1
    gpgcheck=1
    repo_gpgcheck=1
    gpgkey=https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg
    metadata_expire=1h
    EOF
    ```

2. Installing the binary

    ```bash
    sudo dnf install codium
    ```

## Installing Flatpak applications

```bash
flatpak install flathub com.github.tchx84.Flatseal
flatpak install flathub com.belmoussaoui.Authenticator
flatpak install flathub com.obsproject.Studio
flatpak install flathub com.rafaelmardojai.Blanket
flatpak install flathub com.skype.Client
flatpak install flathub io.mpv.Mpv
flatpak install flathub io.github.celluloid_player.Celluloid
flatpak install flathub org.audacityteam.Audacity
flatpak install flathub org.fedoraproject.MediaWriter
flatpak install flathub org.gimp.GIMP
flatpak install flathub org.inkscape.Inkscape
flatpak install flathub org.kde.kdenlive
flatpak install flathub org.keepassxc.KeePassXC
flatpak install flathub org.libreoffice.LibreOffice
flatpak install flathub org.qbittorrent.qBittorrent
flatpak install flathub fr.handbrake.ghb
flatpak install flathub org.gnome.Boxes
flatpak install flathub com.google.Chrome
flatpak install flathub io.dbeaver.DBeaverCommunity
```

## Creating script for TeX Live

```bash
sudo tee /etc/profile.d/texlive.sh <<EOF
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
```

## Installing Timidity++

```bash
sudo dnf install timidity++
```

## Installing Distrobox

```bash
sudo dnf install distrobox
```

## Installing GitHub and Gitlab helpers

```bash
sudo dnf install gh glab
```

## Running DNF autoremove

```bash
sudo dnf autoremove
```

## Removing unused Flatpak runtimes

```bash
flatpak remove --unused
```

## Installing fonts

1. Downloading fonts

    ```bash
    FONTVERSION="v3.0.0"
    mkdir -p /home/$WHO/.local/share/fonts
    wget https://github.com/ryanoasis/nerd-fonts/releases/download/$FONTVERSION/CascadiaCode.zip
    unzip CascadiaCode.zip -d "/home/$WHO/.local/share/fonts/Caskaydia Cove"
    wget https://github.com/ryanoasis/nerd-fonts/releases/download/$FONTVERSION/FiraCode.zip
    unzip FiraCode.zip -d "/home/$WHO/.local/share/fonts/Fira Code"
    wget https://github.com/ryanoasis/nerd-fonts/releases/download/$FONTVERSION/FiraMono.zip
    unzip FiraMono.zip -d "/home/$WHO/.local/share/fonts/Fura Mono"
    wget https://github.com/ryanoasis/nerd-fonts/releases/download/$FONTVERSION/JetBrainsMono.zip
    unzip JetBrainsMono.zip -d "/home/$WHO/.local/share/fonts/JetBrains Mono"
    ```

2. Removing unused files

    ```bash
    find /home/$WHO/.local/share/fonts -type f \
    -not -name "*.ttf" \
    -not -name "*.otf" \
    -exec rm {} \;
    ```

3. Generating font cache

    ```bash
    fc-cache -fv /home/$WHO/.local/share/fonts
    ```

## Installing YouTube downloader

```bash
wget https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp
mv yt-dlp /home/$WHO/.local/bin
chmod +x /home/$WHO/.local/bin/yt-dlp
```

## TeX Live hints

After installing TeX Live, don't forget to create a symlink:

```
sudo ln -s /opt/$WHO/applications/texlive/<year>/bin/<arch> /opt/texbin
```

*To be continued.* :wink:
