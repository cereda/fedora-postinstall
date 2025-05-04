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

section "Paulo's custom configuration for the home directory"

description "A custom home directory setup provides improved \
organization, security, and system performance by allowing \
users to tailor the directory structure and access \
permissions to their specific needs."

echo

question "Do you want to use a hidden directory structure? [recommended]"

if [ $? = 0 ]; then

    ROOT_DIRECTORY_STRUCTURE="${HOME}/.${MACHINE_NAME}"
else

    ${GUM} style --width ${GUM_TEXT_WIDTH} \
"Please select a directory. You can navigate between \
directories using the left and right arrow keys, and \
select one with the Enter key."

    SELECT_DIRECTORY=null

    while [ ! -d "${SELECT_DIRECTORY}" ]; do

        SELECT_DIRECTORY=$(${GUM} file --all --permissions --directory)
    done

    ROOT_DIRECTORY_STRUCTURE="${SELECT_DIRECTORY}"
fi

text "The root directory structure will be located at ${ROOT_DIRECTORY_STRUCTURE}."

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

# load the aliases for this machine
if [ -e "${ROOT_DIRECTORY_STRUCTURE}/scripts/aliases.sh" ]; then
    source "${ROOT_DIRECTORY_STRUCTURE}/scripts/aliases.sh"
fi

# load the bash completion functions
if [ -e "${ROOT_DIRECTORY_STRUCTURE}/scripts/completion.sh" ]; then
    source "${ROOT_DIRECTORY_STRUCTURE}/scripts/completion.sh"
fi

# load the color scheme
if [ -e "${ROOT_DIRECTORY_STRUCTURE}/scripts/colors.sh" ]; then
    source "${ROOT_DIRECTORY_STRUCTURE}/scripts/colors.sh"
fi

# load the Rust config
if [ -e "${ROOT_DIRECTORY_STRUCTURE}/scripts/rust.sh" ]; then
    source "${ROOT_DIRECTORY_STRUCTURE}/scripts/rust.sh"
fi

# load the toolbox config
if [ -e "${ROOT_DIRECTORY_STRUCTURE}/scripts/toolbox.sh" ]; then
    source "${ROOT_DIRECTORY_STRUCTURE}/scripts/toolbox.sh"
fi

# set starship as default prompt
if [ -x "\$(command -v starship)" ]; then

    # set the configuration and log settings for starship
    export STARSHIP_CONFIG="${ROOT_DIRECTORY_STRUCTURE}/config/starship/starship.toml"
    export STARSHIP_LOG="error"

    # init starship prompt
    eval "\$(starship init bash)"
fi

# hook direnv into the shell
if [ -x "\$(command -v direnv)" ]; then

    # activate direnv
    eval "\$(direnv hook bash)"
fi

# hook carapace-bin into the shell
if [ -x "\$(command -v carapace)" ]; then

    # optional, but suggested in the user manual
    export CARAPACE_BRIDGES='zsh,fish,bash,inshellisense'

    # 
    source <(carapace _carapace)
fi
EOF

info "Creating aliases file."
tee "${ROOT_DIRECTORY_STRUCTURE}/scripts/aliases.sh" <<EOF
# wrapper around some tools and commands I typically use in this computer
function ${MACHINE_NAME} {
    
    local PAULO_ICON_SYSTEM="💻"
    local PAULO_ICON_TOOLBOX="📦"

    if [ "\$#" -ne 2 ]; then
        echo "Usage: ${MACHINE_NAME} <action> <target>" >&2
        echo
        echo "╭──────────┬────────────────────────────────────────────────╮"
        echo "│ Actions  │ Targets                                        │"
        echo "├──────────┼────────────────────────────────────────────────┤"
        echo "│ upgrade  │ system, starship, tex, sdk, uv, node, youtube  │"
        echo "│          │ rust, deno, bun, flatpak, conda, distrobox     │"
        echo "│          │ nvim, direnv, world                            │"
        echo "├──────────┼────────────────────────────────────────────────┤"
        echo "│ clean    │ flatpak, cache, system                         │"
        echo "├──────────┼────────────────────────────────────────────────┤"
        echo "│ config   │ menu, toolbox                                  │"
        echo "├──────────┼────────────────────────────────────────────────┤"
        echo "│ use      │ sdk, conda, node, server                       │"
        echo "╰──────────┴────────────────────────────────────────────────╯"
        return 1
    fi

    case "\$1" in
        upgrade)

            case "\$2" in
                system)
                    if [[ -f /run/.containerenv && -f /run/.toolboxenv ]]; then
                        echo "\${PAULO_ICON_TOOLBOX} Upgrading system (via dnf)."
                        sudo dnf upgrade --refresh
                        sudo dnf autoremove
                    else
                        echo "\${PAULO_ICON_SYSTEM} Upgrading system (via rpm-ostree)."
                        rpm-ostree upgrade
                    fi
                ;;

                starship)
                    sh -c "\$(curl -fsSL https://starship.rs/install.sh)" -- -b "${HOME}/.local/bin" -y
                ;;

                tex)
                    if [[ -f /run/.containerenv && -f /run/.toolboxenv ]]; then
                        if [ -x "\$(command -v tlmgr)" ]; then
                            echo "\${PAULO_ICON_TOOLBOX} Upgrading TeX distro (via tlmgr)."
                            tlmgr update --self --all --reinstall-forcibly-removed
                        fi
                    else
                        echo "\${PAULO_ICON_SYSTEM} No TeX distro manager available."
                    fi
                ;;
                
                sdk)
                    if [ -e "${ROOT_DIRECTORY_STRUCTURE}/scripts/sdk.sh" ]; then
                        source "${ROOT_DIRECTORY_STRUCTURE}/scripts/sdk.sh"
                        sdk upgrade
                        sdk update
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
                        bun upgrade --stable
                    fi
                ;;

                nvim)
                    if [[ -f /run/.containerenv && -f /run/.toolboxenv ]]; then
                        if [ -x "\$(command -v nvim)" ]; then
                            echo "\${PAULO_ICON_TOOLBOX} Upgrading neovim."
                            nvim --headless "+Lazy! sync" +qa
                        fi
                    else
                        echo "\${PAULO_ICON_SYSTEM} neovim is not available."
                    fi
                ;;

                flatpak)
                    if [[ -f /run/.containerenv && -f /run/.toolboxenv ]]; then
                        echo "\${PAULO_ICON_TOOLBOX} Flatpak is not available."
                    else
                        echo "\${PAULO_ICON_SYSTEM} Upgrading flatpaks."
                        flatpak upgrade -y
                        flatpak remove --unused -y
                    fi
                ;;

                conda)
                    if [ -e "${ROOT_DIRECTORY_STRUCTURE}/applications/miniconda/3/bin/conda" ]; then
                        eval "\$("${ROOT_DIRECTORY_STRUCTURE}/applications/miniconda/3/bin/conda" shell.bash hook)"
                        conda upgrade --all
                    fi
                ;;

                distrobox)
                    if [ -x "\$(command -v distrobox)" ]; then
                        curl -s https://raw.githubusercontent.com/89luca89/distrobox/main/install | sh -s -- --prefix ~/.local
                    fi
                ;;

                direnv)
                    if [ -x "\$(command -v direnv)" ]; then
                        export bin_path="${HOME}/.local/bin" && curl -sfL https://direnv.net/install.sh | bash
                    fi
                ;;

                uv)
                    if [ -x "\$(command -v uv)" ]; then
                        uv self update
                    fi
                ;;
                
                world)
                    ${MACHINE_NAME} upgrade flatpak
                    ${MACHINE_NAME} upgrade tex
                    ${MACHINE_NAME} upgrade sdk
                    ${MACHINE_NAME} upgrade node
                    ${MACHINE_NAME} upgrade youtube
                    ${MACHINE_NAME} upgrade rust
                    ${MACHINE_NAME} upgrade deno
                    ${MACHINE_NAME} upgrade bun
                    ${MACHINE_NAME} upgrade nvim
                    ${MACHINE_NAME} upgrade conda
                    ${MACHINE_NAME} upgrade uv
                    ${MACHINE_NAME} clean flatpak
                    ${MACHINE_NAME} clean cache
                ;;

                *)
                    echo "I don't know this target."
                    echo
                    echo "╭──────────┬────────────────────────────────────────────────╮"
                    echo "│ upgrade  │ system, starship, tex, sdk, uv, node, youtube  │"
                    echo "│          │ rust, deno, bun, flatpak, conda, distrobox     │"
                    echo "│          │ nvim, direnv, world                            │"
                    echo "╰──────────┴────────────────────────────────────────────────╯"
                ;;
            esac
        ;;

        clean)
            case "\$2" in
                flatpak)
                    if [[ -f /run/.containerenv && -f /run/.toolboxenv ]]; then
                        echo "\${PAULO_ICON_TOOLBOX} Flatpak is not available."
                    else
                        echo "\${PAULO_ICON_SYSTEM} Cleaning installed flatpaks."
                        flatpak remove --unused -y
                    fi
                    find "${HOME}/.var/app" -maxdepth 1 -mindepth 1 -not -name org.gnome.TextEditor ${FLATPAKS_KEEP_CACHE_LIST:1} -type d -exec rm -rf "{}" \; 2>/dev/null
                    find "/run/user/$(id --user)/app" -maxdepth 1 -mindepth 1 -type d -exec rm -rf "{}" \; 2>/dev/null
                ;;

                cache)
                    if [[ -f /run/.containerenv && -f /run/.toolboxenv ]]; then
                        echo "\${PAULO_ICON_TOOLBOX} bleachbit is not available."
                    else
                        if [ "\$(flatpak list --app | grep bleachbit)" ]; then
                            echo "\${PAULO_ICON_SYSTEM} Cleaning cache (bleachbit)."
                            if [ -x "\$(command -v gum)" ]; then
                                pidof -q firefox && gum confirm "Firefox is running. Should I stop it?" && killall firefox
                            fi
                            flatpak run org.bleachbit.BleachBit --preset --clean system.custom
                        fi
                        gio trash --empty
                    fi
                ;;

                system)
                    ${MACHINE_NAME} clean cache
                    shutdown -h now
                ;;

                *)
                    echo "I don't know this target."
                    echo
                    echo "╭──────────┬────────────────────────────────────────────────╮"
                    echo "│ config   │ flatpak, cache, system                         │"
                    echo "╰──────────┴────────────────────────────────────────────────╯"
                ;;
            esac       
        ;;

        config)
            case "\$2" in
                menu)
                    gsettings set org.gnome.shell app-picker-layout "[]"
                ;;

                toolbox)
                    if [[ -f /run/.containerenv && -f /run/.toolboxenv ]]; then
                        local PACKAGE_LIST="TOOLBOX_INSTALLATION_LIST"
                        echo -e "\${PAULO_ICON_TOOLBOX} Packages to install (via DNF).\n"

                        if [[ -x "\$(command -v gum)" ]]; then
                            gum style --width=80 --italic "\${PACKAGE_LIST}"
                        else
                            echo "\${PACKAGE_LIST}"
                        fi
                    else
                        echo "\${PAULO_ICON_SYSTEM} Cannot run this command."
                    fi
                ;;

                *)
                    echo "I don't know this target."
                    echo
                    echo "╭──────────┬────────────────────────────────────────────────╮"
                    echo "│ config   │ menu, toolbox                                  │"
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

                server)
                    local IP_ADDRESS=\$(ip address | grep 192 | awk -F ' ' '{print \$2}' | cut -d'/' -f1)
                    echo "Current IP: \${IP_ADDRESS}"
                    if [ -x "\$(command -v caddy)" ]; then
                        echo "Starting the Caddy server, please wait."
                        caddy file-server --browse --listen :8000
                    else
                        echo "Starting the Python HTTP server, please wait."
                        python -m http.server
                    fi
                ;;

                *)
                    echo "I don't know this target."
                    echo
                    echo "╭──────────┬────────────────────────────────────────────────╮"
                    echo "│ use      │ sdk, conda, node, server                       │"
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
            echo "│ upgrade  │ system, starship, tex, sdk, uv, node, youtube  │"
            echo "│          │ rust, deno, bun, flatpak, conda, distrobox     │"
            echo "│          │ nvim, direnv, world                            │"
            echo "├──────────┼────────────────────────────────────────────────┤"
            echo "│ clean    │ flatpak, cache, system                         │"
            echo "├──────────┼────────────────────────────────────────────────┤"
            echo "│ config   │ menu, toolbox                                  │"
            echo "├──────────┼────────────────────────────────────────────────┤"
            echo "│ use      │ sdk, conda, node, server                       │"
            echo "╰──────────┴────────────────────────────────────────────────╯"
        ;;
    esac
}

# extract a playlist from YouTube and creates a proper list
function playlist {
    if [ "\$#" -ne 2 ]; then
        echo "Usage: playlist <link> <title>" >&2
        return 1
    fi
    yt-dlp -f 18 "\$1" -o "\$2, part %(video_autonumber)s.%(ext)s"
}

# extract videos from certain links
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

# **********************************************************************
# Additional scripts, disabled by default
# **********************************************************************
#
# # extract videos from certain links (loop it until link resolves)
# function social-media-downloader {
#     for link in "\$@"; do
#         name="\$(shuf -er -n10 {A..Z} {a..z} {0..9} | tr -d '\n').mp4"
#         until yt-dlp "\$link" -o - | ffmpeg -i pipe: "\${name}"; do
#             :
#         done
#     done
# }
#
# # wrap yt-dlp into a function to support browser cookies
# function yt-dlp-cookies {
#     echo "Activating environment."
#     source "${ROOT_DIRECTORY_STRUCTURE}/environments/python/youtube/bin/activate"
#     yt-dlp --cookies-from-browser <browser>:<location> "$\@"
#     echo "Deactivating environment."
#     deactivate
# }
#
# check packages from the previous Fedora release that are still installed
# function release-pkg-cheker {
#     local hits=\$(rpm -qa | grep "fc\$((\$(rpm -E %fedora) - 1))" | grep -v "kernel" | wc -l)
#     echo "Packages found: \$hits"
# }
# **********************************************************************

# **********************************************************************
# Flatpak aliases, uncomment to use
# **********************************************************************
# alias codium="flatpak run com.vscodium.codium"
# alias bleachbit="flatpak run org.bleachbit.BleachBit"
# alias burnfix="flatpak run io.github.vinser.burnfix"
# alias mpv="flatpak run io.mpv.Mpv"
# **********************************************************************
EOF

info "Creating completion file."
tee "${ROOT_DIRECTORY_STRUCTURE}/scripts/completion.sh" <<EOF
_${MACHINE_NAME}()
{
    local cur prev

    cur=\${COMP_WORDS[COMP_CWORD]}
    prev=\${COMP_WORDS[COMP_CWORD-1]}

    case \${COMP_CWORD} in
        1)
            COMPREPLY=(\$(compgen -W "upgrade clean config use" -- \${cur}))
        ;;

        2)
            case \${prev} in
                upgrade)
                    COMPREPLY=(\$(compgen -W "system starship tex sdk nvim node youtube rust deno bun flatpak conda distrobox uv direnv world" -- \${cur}))
                ;;

                clean)
                    COMPREPLY=(\$(compgen -W "flatpak cache system" -- \${cur}))
                ;;

                config)
                    COMPREPLY=(\$(compgen -W "menu toolbox" -- \${cur}))
                ;;

                use)
                    COMPREPLY=(\$(compgen -W "sdk conda node server" -- \${cur}))
                ;;
            esac
        ;;

        *)
            COMPREPLY=()
        ;;
    esac
}

complete -F _${MACHINE_NAME} ${MACHINE_NAME}
EOF

    info "Creating toolbox file."
    tee "${ROOT_DIRECTORY_STRUCTURE}/scripts/toolbox.sh" <<EOF
# check if inside a toolbox container
if [[ -f /run/.containerenv && -f /run/.toolboxenv ]]; then
    
    # add any toolbox-specific configuration inside this block,
    # e.g, path to TeX Live from the host system:
    #
    # pathmunge () {
    #     if ! echo \$PATH | /bin/grep -E -q "(^|:)\$1(\$|:)" ; then
    #         if [ "\$2" = "after" ] ; then
    #             PATH=\$PATH:\$1
    #         else
    #             PATH=\$1:\$PATH
    #         fi
    #     fi
    # }
    #
    # pathmunge ${ROOT_DIRECTORY_STRUCTURE}/applications/texlive/current after
    # unset pathmunge
    :
fi
EOF
