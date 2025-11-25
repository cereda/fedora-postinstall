#!/usr/bin/env bash

section "Paulo's custom configuration for the home directory"

description "A custom home directory setup provides improved \
organization, security, and system performance by allowing \
users to tailor the directory structure and access \
permissions to their specific needs."

echo

question "Do you want to use a hidden directory structure? [recommended]"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    # the root directory will be defined based on the HOME
    # directory + .<machine name> (hidden structure)
    ROOT_DIRECTORY_STRUCTURE="${HOME}/.${MACHINE_NAME}"
else

    # ask user to select a directory to store applications, scripts,
    # settings, profile, and other relevant files

    text "Please select a directory. You can navigate \
between directories using the left and right arrow keys, \
and select one with the Enter key."

    SELECT_DIRECTORY=null

    # the script will loop until the user selects a directory
    while [ ! -d "${SELECT_DIRECTORY}" ]; do

        # show the directory chooser
        SELECT_DIRECTORY=$(${GUM} file --all --permissions --directory)
    done

    # the selected directory will be the root directory
    ROOT_DIRECTORY_STRUCTURE="${SELECT_DIRECTORY}"
fi

text "The root directory structure will be located at ${ROOT_DIRECTORY_STRUCTURE}."

echo

info "Creating root directory."
mkdir -p "${ROOT_DIRECTORY_STRUCTURE}"

info "Creating directory for applications."
mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/applications"

info "Creating directory for config files."
mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/config"

info "Creating directory for data files."
mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/data"

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

# load the Go config
if [ -e "${ROOT_DIRECTORY_STRUCTURE}/scripts/go.sh" ]; then
    source "${ROOT_DIRECTORY_STRUCTURE}/scripts/go.sh"
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

    # activate carapace-bin
    source <(carapace _carapace)
fi

# hook zoxide into the shell
if [ -x "\$(command -v zoxide)" ]; then

    # the zoxide database will be stored here
    export _ZO_DATA_DIR="${ROOT_DIRECTORY_STRUCTURE}/data/zoxide"

    # activate zoxide
    eval "\$(zoxide init bash)"
fi

# hook mise into the shell
if [ -x "\$(command -v mise)" ]; then

    # binaries will be installed here
    export MISE_DATA_DIR="${ROOT_DIRECTORY_STRUCTURE}/data/mise"

    # configuration file will be written here
    export MISE_CONFIG_DIR="${ROOT_DIRECTORY_STRUCTURE}/config/mise"

    # activate mise (optional, uncomment it to enable)
    # eval "\$(mise activate bash)"
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
        echo "│          │ rust, deno, bun, flatpak, conda, distrobox     │"
        echo "│          │ nvim, uv, direnv, mise, world                  │"
        echo "├──────────┼────────────────────────────────────────────────┤"
        echo "│ clean    │ flatpak, files, cache, system, permissions     │"
        echo "├──────────┼────────────────────────────────────────────────┤"
        echo "│ config   │ menu                                           │"
        echo "├──────────┼────────────────────────────────────────────────┤"
        echo "│ use      │ sdk, conda, node, server, mise                 │"
        echo "╰──────────┴────────────────────────────────────────────────╯"
        return 1
    fi

    case "\$1" in
        upgrade)

            case "\$2" in
                system)
                    sudo dnf upgrade --refresh
                    sudo dnf autoremove
                    ${MACHINE_NAME} clean files
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
                        sdk selfupdate
                        sdk upgrade
                        sdk update
                    fi
                ;;

                vim)
                    if [ -x "\$(command -v vim)" ]; then
                        vim -c "PlugUpgrade" -c "PlugUpdate" -c "q" -c "q"
                    fi
                ;;

                nvim)
                    if [ -x "\$(command -v nvim)" ]; then
                        echo "\${PAULO_ICON_TOOLBOX} Upgrading neovim."
                        nvim --headless "+Lazy! sync" +qa
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

                mise)
                    if [ -x "\$(command -v mise)" ]; then
                        mise self-update --yes
                        mise upgrade --bump
                    fi
                ;;

                world)
                    ${MACHINE_NAME} upgrade flatpak
                    ${MACHINE_NAME} upgrade tex
                    ${MACHINE_NAME} upgrade sdk
                    ${MACHINE_NAME} upgrade vim
                    ${MACHINE_NAME} upgrade nvim
                    ${MACHINE_NAME} upgrade node
                    ${MACHINE_NAME} upgrade youtube
                    ${MACHINE_NAME} upgrade rust
                    ${MACHINE_NAME} upgrade deno
                    ${MACHINE_NAME} upgrade bun
                    ${MACHINE_NAME} upgrade conda
                    ${MACHINE_NAME} upgrade uv
                    ${MACHINE_NAME} upgrade mise
                    ${MACHINE_NAME} clean flatpak
                    ${MACHINE_NAME} clean cache
                ;;

                *)
                    echo "I don't know this target."
                    echo
                    echo "╭──────────┬────────────────────────────────────────────────╮"
                    echo "│ upgrade  │ system, starship, tex, sdk, vim, node, youtube │"
                    echo "│          │ rust, deno, bun, flatpak, conda, distrobox     │"
                    echo "│          │ nvim, uv, direnv, mise, world                  │"
                    echo "╰──────────┴────────────────────────────────────────────────╯"
                ;;
            esac
        ;;

        clean)
            case "\$2" in
                flatpak)
                    flatpak remove --unused -y
                    find "${HOME}/.var/app" -maxdepth 1 -mindepth 1 ${FLATPAKS_KEEP_CACHE_LIST:1} -type d -exec rm -rf "{}" \; 2>/dev/null
                    find "/run/user/$(id --user)/app" -maxdepth 1 -mindepth 1 -type d -exec rm -rf "{}" \; 2>/dev/null
                ;;

                files)
                    sudo rm -f /var/log/boot.log-*
                    sudo rm -f /var/log/btmp-*
                    sudo rm -f /var/log/dnf.librepo.log.*
                    sudo rm -f /var/log/dnf.log.*
                    sudo rm -f /var/log/dnf5.log.*
                    sudo rm -f /var/log/dnf.rpm.log.*
                    sudo rm -f /var/log/hawkey.log-*
                    sudo rm -f /var/log/tuned/tuned.log.*
                    sudo rm -f /var/log/cron-*
                    sudo rm -f /var/log/maillog-*
                    sudo rm -f /var/log/messages-*
                    sudo rm -f /var/log/secure-*
                    sudo rm -f /var/log/spooler-*
                ;;

                cache)
                    if [ -x "\$(command -v bleachbit)" ]; then
                        if [ -x "\$(command -v gum)" ]; then
                            pidof -q firefox && gum confirm "Firefox is running. Should I stop it?" && killall firefox
                        fi
                        bleachbit --preset --clean system.custom
                    fi
                    gio trash --empty
                ;;

                system)
                    ${MACHINE_NAME} clean cache
                    shutdown -h now
                ;;

                permissions)
                    flatpak permissions | awk -F'\t' '{print \$1, \$2}' | while read entry1 entry2; do
                        if [ -n "\${entry1}" ] && [ -n "\${entry2}" ]; then
                            flatpak permission-remove "\${entry1}" "\${entry2}" 2>/dev/null || true
                        fi
                    done
                ;;

                *)
                    echo "I don't know this target."
                    echo
                    echo "╭──────────┬────────────────────────────────────────────────╮"
                    echo "│ clean    │ flatpak, files, cache, system, permissions     │"
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

                mise)
                    if [ -x "\$(command -v mise)" ]; then
                        eval "\$(mise activate bash)"
                    fi
                ;;

                *)
                    echo "I don't know this target."
                    echo
                    echo "╭──────────┬────────────────────────────────────────────────╮"
                    echo "│ use      │ sdk, conda, node, server, mise                 │"
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
            echo "│          │ rust, deno, bun, flatpak, conda, distrobox     │"
            echo "│          │ nvim, uv, direnv, mise, world                  │"
            echo "├──────────┼────────────────────────────────────────────────┤"
            echo "│ clean    │ flatpak, files, cache, system, permissions     │"
            echo "├──────────┼────────────────────────────────────────────────┤"
            echo "│ config   │ menu                                           │"
            echo "├──────────┼────────────────────────────────────────────────┤"
            echo "│ use      │ sdk, conda, node, server, mise                 │"
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
# # wrap yt-dlp into a function to support browser cookies; the script
# # relies on a Python virtual environment, the setup is as follows:
# #
# # python -m venv "${ROOT_DIRECTORY_STRUCTURE}/environments/python/youtube"
# # source "${ROOT_DIRECTORY_STRUCTURE}/environments/python/youtube/bin/activate"
# # python -m pip install SecretStorage
# #
# # yt-dlp requires SecretStorage to extract cookies from Chromium-based
# # browsers; if used with Firefox, the library is not needed
# function yt-dlp-cookies {
#     echo "Activating environment."
#     source "${ROOT_DIRECTORY_STRUCTURE}/environments/python/youtube/bin/activate"
#     local USER_AGENT="<user agent>"
#     yt-dlp --cookies-from-browser <browser>:<location> --user-agent "${USER_AGENT}" "$\@"
#     echo "Deactivating environment."
#     deactivate
# }
#
# # check packages from the previous Fedora release that are still installed
# function release-pkg-cheker {
#     local hits=\$(rpm -qa | grep "fc\$((\$(rpm -E %fedora) - 1))" | grep -v "kernel" | wc -l)
#     echo "Packages found: \$hits"
# }
#
# # create a zip file with the current timestamp appended to the file name
# function zip-date {
#     if [ -d "\$1" ]; then
#         local DIR_NAME="\${1%/}"
#         local TIMESTAMP=\$(date +"%Y%m%d-%H%M%S")
#         local ZIP_FILE="\${DIR_NAME}-\${TIMESTAMP}.zip"
#         zip -r "\${ZIP_FILE}" "\${DIR_NAME}"
#         echo "Created ZIP file: \${ZIP_FILE}"
#     else
#         echo "Error: Directory '\$1' does not exist."
#     fi
# }
#
# # set a JDK based on user selection
# function cafebabe() {
#
#     # set the directory containing JDKs
#     local JDK_DIR="/home/paulo/.jdks"
#
#     # function to get the current PATH update and remove existing JDK paths
#     reset_path() {
#
#         # remove existing JDK paths from the PATH, ensuring delimiters are preserved
#         export PATH=\$(echo "\${PATH}" | sed -E 's|:*/home/paulo/.jdks/[^:]+/bin||g; s|^/home/paulo/.jdks/[^:]+/bin:||g; s|^:||; s|:\$||')
#
#     }
#
#     # build the list of directories under JDK_DIR
#     local JDK_LIST=\$(ls -1 "\${JDK_DIR}")
#
#     # append the "Reset path" option
#     local OPTIONS=\$(printf "%s\n" \${JDK_LIST} "Reset path")

#     # prompt user to choose a JDK version or reset path
#     local CHOSEN=\$(echo "\${OPTIONS}" | gum choose --header "Choose a JDK version:")

#     # check if the user selected "Reset path"
#     if [[ "\${CHOSEN}" == "Reset path" ]]; then
#         reset_path
#         echo "PATH has been reset to the original state."
#     else

#         # remove any existing JDK path from PATH
#         reset_path
        
#         # set the new JDK path
#         export PATH="\${JDK_DIR}/\${CHOSEN}/bin:\${PATH}"
#         echo "Updated PATH to include: \${JDK_DIR}/\${CHOSEN}/bin"
#     fi

#     # unset the reset function
#     unset -f reset_path
# }
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
                    COMPREPLY=(\$(compgen -W "system starship tex sdk vim nvim node youtube rust deno bun flatpak conda distrobox uv direnv mise world" -- \${cur}))
                ;;

                clean)
                    COMPREPLY=(\$(compgen -W "flatpak files cache system permissions" -- \${cur}))
                ;;

                config)
                    COMPREPLY=(\$(compgen -W "menu" -- \${cur}))
                ;;

                use)
                    COMPREPLY=(\$(compgen -W "sdk conda node server mise" -- \${cur}))
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
    # pathmunge /var/run/host/opt/texbin after
    # unset pathmunge
    :
fi
EOF
