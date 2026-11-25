#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Fedora Workstation home configuration"

ui_description "Set up the managed home-directory structure and Bash configuration for Fedora Workstation."

HOME_CONFIGURATION_FLATPAKS_RETENTION_AVAILABLE=1
if [ "${FLATPAKS_KEEP_CACHE_IDS_JSON+x}" != "x" ]; then
    HOME_CONFIGURATION_FLATPAKS_RETENTION_AVAILABLE=0
    FLATPAKS_KEEP_CACHE_LIST=""
    ui_warning "Flatpak cache-retention state is unavailable; generated cleanup will not remove Flatpak application data."
elif [ -z "${FLATPAKS_KEEP_CACHE_IDS_JSON}" ]; then
    ui_error "The Flatpak cache-retention state is missing."
    return 1
else
    flatpaks_keep_cache_filter_from_state "${FLATPAKS_KEEP_CACHE_IDS_JSON}" || return $?
fi

# use a shell-safe command name independent from the host name
COMMAND_NAME="host_${MACHINE_NAME//[^A-Za-z0-9_]/_}"

HIDDEN_DIRECTORY_PROMPT_STATUS=0
ui_confirm \
    "Use the recommended hidden directory (~/.${MACHINE_NAME}) or choose a custom location?" \
    "Use hidden directory" "Choose location" ||
    HIDDEN_DIRECTORY_PROMPT_STATUS="${?}"

case "${HIDDEN_DIRECTORY_PROMPT_STATUS}" in
0)

    # Keep the managed tree hidden by default.
    ROOT_DIRECTORY_STRUCTURE="${HOME}/.${MACHINE_NAME}"
    ;;
1)

    ui_step "Selecting a custom configuration directory."

    HOME_CONFIGURATION_DIRECTORY_MAX_ATTEMPTS=3
    HOME_CONFIGURATION_DIRECTORY_ATTEMPT=0
    HOME_CONFIGURATION_DIRECTORY_SELECTED=0
    ROOT_DIRECTORY_STRUCTURE=""

    # Reject paths outside the user's home directory, but do not retry a
    # cancelled or failed chooser indefinitely.
    while [ "${HOME_CONFIGURATION_DIRECTORY_ATTEMPT}" -lt \
        "${HOME_CONFIGURATION_DIRECTORY_MAX_ATTEMPTS}" ]; do

        HOME_CONFIGURATION_DIRECTORY_ATTEMPT=$((HOME_CONFIGURATION_DIRECTORY_ATTEMPT + 1))
        SELECT_DIRECTORY=""
        HOME_CONFIGURATION_DIRECTORY_STATUS=0

        if SELECT_DIRECTORY=$(ui_select_directory "${HOME}"); then
            HOME_CONFIGURATION_DIRECTORY_STATUS=0
        else
            HOME_CONFIGURATION_DIRECTORY_STATUS="${?}"
        fi

        case "${HOME_CONFIGURATION_DIRECTORY_STATUS}" in
        0)
            if [ -z "${SELECT_DIRECTORY}" ]; then
                ui_error "No directory was selected."
                return 1
            fi

            if ROOT_DIRECTORY_STRUCTURE=$(realpath -e -- "${SELECT_DIRECTORY}"); then
                if validate_root_directory "${ROOT_DIRECTORY_STRUCTURE}"; then
                    HOME_CONFIGURATION_DIRECTORY_SELECTED=1
                    break
                fi
            fi
            ;;
        1)
            ui_error "Directory selection was cancelled."
            return 1
            ;;
        *)
            ui_error "Unable to select a directory (status ${HOME_CONFIGURATION_DIRECTORY_STATUS})."
            return "${HOME_CONFIGURATION_DIRECTORY_STATUS}"
            ;;
        esac
    done

    if [ "${HOME_CONFIGURATION_DIRECTORY_SELECTED}" -ne 1 ]; then
        ui_error "Unable to select a safe configuration directory after ${HOME_CONFIGURATION_DIRECTORY_MAX_ATTEMPTS} attempts."
        return 1
    fi
    ;;
*)
    ui_error "Unable to read the directory-structure preference."
    return "${HIDDEN_DIRECTORY_PROMPT_STATUS}"
    ;;
esac

if ! validate_root_directory "${ROOT_DIRECTORY_STRUCTURE}"; then
    ui_error "The selected configuration directory is not safe to use."
    return 1
fi

ui_text "The managed home directory will be located at ${ROOT_DIRECTORY_STRUCTURE}."

ui_step "Creating the managed directory structure."
HOME_CONFIGURATION_CREATE_STATUS=0
mkdir -p "${ROOT_DIRECTORY_STRUCTURE}" || HOME_CONFIGURATION_CREATE_STATUS="${?}"
mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/applications" || HOME_CONFIGURATION_CREATE_STATUS="${?}"
mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/config" || HOME_CONFIGURATION_CREATE_STATUS="${?}"
mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/data" || HOME_CONFIGURATION_CREATE_STATUS="${?}"
mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/profile" || HOME_CONFIGURATION_CREATE_STATUS="${?}"
mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/scripts" || HOME_CONFIGURATION_CREATE_STATUS="${?}"
mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/stuff" || HOME_CONFIGURATION_CREATE_STATUS="${?}"
mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/environments" || HOME_CONFIGURATION_CREATE_STATUS="${?}"
if [ "${HOME_CONFIGURATION_CREATE_STATUS}" -eq 0 ]; then
    ui_success "Managed directory structure created."
else
    ui_error "Unable to create the managed directory structure."
    return "${HOME_CONFIGURATION_CREATE_STATUS}"
fi

ui_step "Updating the Bash entry point and shell configuration."
HOME_CONFIGURATION_SHELL_STATUS=0
cat >"${ROOT_DIRECTORY_STRUCTURE}/scripts/bash.sh" <<SH || HOME_CONFIGURATION_SHELL_STATUS="${?}"
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

# load the taskwarrior config
if [ -e "${ROOT_DIRECTORY_STRUCTURE}/scripts/taskwarrior.sh" ]; then
    source "${ROOT_DIRECTORY_STRUCTURE}/scripts/taskwarrior.sh"
fi

# load the forgit config
if [ -e "${ROOT_DIRECTORY_STRUCTURE}/scripts/forgit.sh" ]; then
    source "${ROOT_DIRECTORY_STRUCTURE}/scripts/forgit.sh"
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

# hook fzf into the shell
if [ -x "\$(command -v fzf)" ]; then

    # shell integration for fzf
    eval "\$(fzf --bash)"
fi
SH

# Append the loader only after the managed shell file exists.
if [ "${HOME_CONFIGURATION_SHELL_STATUS}" -eq 0 ]; then
    cat >>"${HOME}/.bashrc" <<BASH || HOME_CONFIGURATION_SHELL_STATUS="${?}"

# managed home configuration
if [ -e "${ROOT_DIRECTORY_STRUCTURE}/scripts/bash.sh" ]; then
    source "${ROOT_DIRECTORY_STRUCTURE}/scripts/bash.sh"
fi
BASH
fi

if [ "${HOME_CONFIGURATION_SHELL_STATUS}" -eq 0 ]; then
    ui_success "Bash entry point and shell configuration updated."
else
    ui_error "Unable to update the Bash entry point and shell configuration."
    return "${HOME_CONFIGURATION_SHELL_STATUS}"
fi

ui_step "Creating the helper assets."
HOME_CONFIGURATION_HELPER_STATUS=0
cat >"${ROOT_DIRECTORY_STRUCTURE}/scripts/aliases.sh" <<SH || HOME_CONFIGURATION_HELPER_STATUS="${?}"
# wrapper around tools and commands commonly used on this machine
_${COMMAND_NAME}_print_usage() {
    printf '%s\n' \
        "Fedora Workstation command helper." \
        "Usage: ${COMMAND_NAME} <action> <target>" >&2
    cat <<'USAGE' >&2
╭──────────┬─────────────────────────────────────────────────────────────────────╮
│ Actions  │ Targets                                                             │
├──────────┼─────────────────────────────────────────────────────────────────────┤
│ upgrade  │ system, starship, tex, sdk, vim, nvim, node, youtube,               │
│          │ rust, deno, bun, flatpak, conda, distrobox, direnv, uv, mise, world │
├──────────┼─────────────────────────────────────────────────────────────────────┤
│ clean    │ flatpak, files, cache, system, permissions                          │
├──────────┼─────────────────────────────────────────────────────────────────────┤
│ config   │ menu                                                                │
├──────────┼─────────────────────────────────────────────────────────────────────┤
│ use      │ sdk, conda, node, server, mise                                      │
╰──────────┴─────────────────────────────────────────────────────────────────────╯
USAGE
    printf '%s\n' \
        "Destructive targets:" \
        "  flatpak     reset non-retained Flatpak application data" \
        "  files       delete system log files" \
        "  cache       clean cached data and empty trash" \
        "  system      empty trash and shut down" \
        "  permissions reset Flatpak permissions" >&2
}

function ${COMMAND_NAME} {
    local firefox_response=""
    local firefox_process_status=0
    local firefox_read_status=0
    local firefox_killall_status=0
    local cache_cleanup_status=0
    local flatpak_cleanup_status=0
    local flatpak_cleanup_list=""
    local flatpak_cleanup_path=""
    local flatpak_retention_state_available=${HOME_CONFIGURATION_FLATPAKS_RETENTION_AVAILABLE}
    local flatpak_permissions_output=""
    local flatpak_permissions_status=0
    local flatpak_permission_remove_status=0
    local flatpak_permission_line=""
    local flatpak_permission_remainder=""
    local flatpak_permission_entry1=""
    local flatpak_permission_entry2=""

    if [ "\$#" -ne 2 ]; then
        printf 'Error: expected an action and a target.\n' >&2
        _${COMMAND_NAME}_print_usage
        return 1
    fi

    case "\$1" in
        upgrade)

            case "\$2" in
                system)
                    sudo dnf upgrade --refresh
                    sudo dnf autoremove
                    ${COMMAND_NAME} clean files
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
                    ${COMMAND_NAME} upgrade flatpak
                    ${COMMAND_NAME} upgrade tex
                    ${COMMAND_NAME} upgrade sdk
                    ${COMMAND_NAME} upgrade vim
                    ${COMMAND_NAME} upgrade nvim
                    ${COMMAND_NAME} upgrade node
                    ${COMMAND_NAME} upgrade youtube
                    ${COMMAND_NAME} upgrade rust
                    ${COMMAND_NAME} upgrade deno
                    ${COMMAND_NAME} upgrade bun
                    ${COMMAND_NAME} upgrade conda
                    ${COMMAND_NAME} upgrade uv
                    ${COMMAND_NAME} upgrade mise
                    ${COMMAND_NAME} clean flatpak
                    ${COMMAND_NAME} clean cache
                ;;

                *)
                    printf 'Error: unknown target for action %s: %s.\n' "\$1" "\$2" >&2
                    _${COMMAND_NAME}_print_usage
                    return 1
                ;;
            esac
        ;;

        clean)
            case "\$2" in
                flatpak)
                    if [ "\${flatpak_retention_state_available}" != "1" ]; then
                        printf '%s\n' "Error: Flatpak cache-retention state is unavailable; application data was not changed." >&2
                        return 1
                    fi

                    printf '%s\n' "Remove unused Flatpaks and reset non-retained Flatpak application data."
                    flatpak_cleanup_status=0
                    flatpak remove --unused -y || flatpak_cleanup_status="\${?}"
                    if [ "\${flatpak_cleanup_status}" -ne 0 ]; then
                        printf '%s\n' "Error: unable to remove unused Flatpak applications." >&2
                        return "\${flatpak_cleanup_status}"
                    fi

                    flatpak_cleanup_list=\$(mktemp "\${TMPDIR:-/tmp}/fedora-postinstall-flatpak-cleanup.XXXXXX") ||
                        flatpak_cleanup_status="\${?}"
                    if [ "\${flatpak_cleanup_status}" -ne 0 ]; then
                        printf '%s\n' "Error: unable to prepare the Flatpak cleanup list." >&2
                        return "\${flatpak_cleanup_status}"
                    fi

                    if [ -d "\${HOME}/.var/app" ]; then
                        find "\${HOME}/.var/app" -maxdepth 1 -mindepth 1 ${FLATPAKS_KEEP_CACHE_LIST:1} -type d -print0 >"\${flatpak_cleanup_list}" ||
                            flatpak_cleanup_status="\${?}"
                    fi
                    if [ "\${flatpak_cleanup_status}" -eq 0 ] &&
                        [ -d "/run/user/\$(id --user)/app" ]; then
                        find "/run/user/\$(id --user)/app" -maxdepth 1 -mindepth 1 -type d -print0 >>"\${flatpak_cleanup_list}" ||
                            flatpak_cleanup_status="\${?}"
                    fi
                    if [ "\${flatpak_cleanup_status}" -ne 0 ]; then
                        rm -f -- "\${flatpak_cleanup_list}" || true
                        printf '%s\n' "Error: unable to enumerate Flatpak application data." >&2
                        return "\${flatpak_cleanup_status}"
                    fi

                    while IFS= read -r -d '' flatpak_cleanup_path; do
                        rm -rf -- "\${flatpak_cleanup_path}" || {
                            flatpak_cleanup_status="\${?}"
                            break
                        }
                    done <"\${flatpak_cleanup_list}"
                    if [ "\${flatpak_cleanup_status}" -eq 0 ]; then
                        rm -f -- "\${flatpak_cleanup_list}" || flatpak_cleanup_status="\${?}"
                    else
                        rm -f -- "\${flatpak_cleanup_list}" || true
                    fi
                    if [ "\${flatpak_cleanup_status}" -ne 0 ]; then
                        printf '%s\n' "Error: unable to reset Flatpak application data." >&2
                        return "\${flatpak_cleanup_status}"
                    fi
                ;;

                files)
                    printf '%s\n' "Delete system log files."
                    sudo rm -f /var/log/boot.log-*
                    sudo rm -f /var/log/btmp-*
                    sudo rm -f /var/log/dnf.librepo.log.*
                    sudo rm -f /var/log/dnf.log.*
                    sudo rm -f /var/log/dnf5.log.*
                    sudo rm -f /var/log/dnf.rpm.log.*
                    sudo rm -f /var/log/hawkey.log-*
                    sudo rm -f /var/log/tuned/tuned.log.*
                    sudo rm -f /var/log/tuned/tuned-ppd.log.*
                    sudo rm -f /var/log/cron-*
                    sudo rm -f /var/log/maillog-*
                    sudo rm -f /var/log/messages-*
                    sudo rm -f /var/log/secure-*
                    sudo rm -f /var/log/spooler-*
                ;;

                cache)
                    printf '%s\n' "Clean cached data and empty the trash."
                    if [ -x "\$(command -v bleachbit)" ]; then
                        firefox_process_status=0
                        pidof -q firefox || firefox_process_status="\${?}"
                        if [ "\${firefox_process_status}" -eq 0 ]; then
                            firefox_read_status=0
                            read -r -p "Firefox is running. Stop it now? Unsaved work may be lost. [y/N] " firefox_response || firefox_read_status="\${?}"
                            if [ "\${firefox_read_status}" -ne 0 ]; then
                                printf '%s\n' "Unable to read the Firefox confirmation; cache cleanup was canceled." >&2
                                return "\${firefox_read_status}"
                            fi
                            case "\${firefox_response}" in
                            [yY] | [yY][eE][sS])
                                killall firefox || firefox_killall_status="\${?}"
                                if [ "\${firefox_killall_status}" -ne 0 ]; then
                                    printf '%s\n' "Unable to stop Firefox; cache cleanup was canceled." >&2
                                    return "\${firefox_killall_status}"
                                fi
                                ;;
                            *)
                                printf '%s\n' "Firefox was not stopped; cache cleanup was canceled." >&2
                                return 1
                            ;;
                            esac
                        elif [ "\${firefox_process_status}" -ne 1 ]; then
                            printf '%s\n' "Unable to determine whether Firefox is running; cache cleanup was canceled." >&2
                            return "\${firefox_process_status}"
                        fi
                        bleachbit --preset --clean system.custom || cache_cleanup_status="\${?}"
                        if [ "\${cache_cleanup_status}" -ne 0 ]; then
                            printf '%s\n' "Unable to clean cached data with BleachBit; cache cleanup was canceled." >&2
                            return "\${cache_cleanup_status}"
                        fi
                    fi
                    cache_cleanup_status=0
                    gio trash --empty || cache_cleanup_status="\${?}"
                    if [ "\${cache_cleanup_status}" -ne 0 ]; then
                        printf '%s\n' "Unable to empty the trash; cache cleanup failed." >&2
                        return "\${cache_cleanup_status}"
                    fi
                ;;

                system)
                    printf '%s\n' "Empty the trash and shut down."
                    cache_cleanup_status=0
                    ${COMMAND_NAME} clean cache || cache_cleanup_status="\${?}"
                    if [ "\${cache_cleanup_status}" -ne 0 ]; then
                        printf '%s\n' "Cache cleanup failed; shutdown was canceled." >&2
                        return "\${cache_cleanup_status}"
                    fi
                    shutdown -h now
                ;;

                permissions)
                    printf '%s\n' "Reset Flatpak permissions."
                    flatpak_permissions_output=\$(flatpak permissions) || flatpak_permissions_status="\${?}"
                    if [ "\${flatpak_permissions_status}" -ne 0 ]; then
                        printf '%s\n' "Unable to read the Flatpak permissions." >&2
                        return "\${flatpak_permissions_status}"
                    fi
                    while IFS= read -r flatpak_permission_line; do
                        case "\${flatpak_permission_line}" in
                            *\$'\\t'*)
                                flatpak_permission_entry1="\${flatpak_permission_line%%\$'\\t'*}"
                                flatpak_permission_remainder="\${flatpak_permission_line#*\$'\\t'}"
                                flatpak_permission_entry2="\${flatpak_permission_remainder%%\$'\\t'*}"
                                ;;
                            *)
                                flatpak_permission_entry1="\${flatpak_permission_line}"
                                flatpak_permission_entry2=""
                                ;;
                        esac
                        if [ -n "\${flatpak_permission_entry1}" ] &&
                            [ -n "\${flatpak_permission_entry2}" ]; then
                            flatpak permission-remove "\${flatpak_permission_entry1}" "\${flatpak_permission_entry2}" ||
                                flatpak_permission_remove_status="\${?}"
                            if [ "\${flatpak_permission_remove_status}" -ne 0 ]; then
                                printf 'Error: unable to reset the Flatpak permission for %s.\n' "\${flatpak_permission_entry1}" >&2
                                return "\${flatpak_permission_remove_status}"
                            fi
                        fi
                    done <<<"\${flatpak_permissions_output}"
                ;;

                *)
                    printf 'Error: unknown target for action %s: %s.\n' "\$1" "\$2" >&2
                    _${COMMAND_NAME}_print_usage
                    return 1
                ;;
            esac
        ;;

        config)
            case "\$2" in
                menu)
                    gsettings set org.gnome.shell app-picker-layout "[]"
                ;;

                *)
                    printf 'Error: unknown target for action %s: %s.\n' "\$1" "\$2" >&2
                    _${COMMAND_NAME}_print_usage
                    return 1
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
                        echo "Starting the Caddy file server on port 8000."
                        caddy file-server --browse --listen :8000
                    else
                        echo "Starting the Python HTTP server."
                        python -m http.server
                    fi
                ;;

                mise)
                    if [ -x "\$(command -v mise)" ]; then
                        eval "\$(mise activate bash)"
                    fi
                ;;

                *)
                    printf 'Error: unknown target for action %s: %s.\n' "\$1" "\$2" >&2
                    _${COMMAND_NAME}_print_usage
                    return 1
                ;;
            esac
        ;;

        *)
            printf 'Error: unknown action: %s.\n' "\$1" >&2
            _${COMMAND_NAME}_print_usage
            return 1
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
#     yt-dlp --cookies-from-browser <browser>:<location> --user-agent "${USER_AGENT}" "\$@"
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
#     # prompt user to choose a JDK version or reset path
#     local CHOSEN=""
#     local -a OPTIONS=()
#     mapfile -t OPTIONS < <(printf '%s\n' "\${JDK_LIST}" "Reset path")
#     select CHOSEN in "\${OPTIONS[@]}"; do
#         break
#     done
#
#     # check if user selected an option
#     if [ -z "\${CHOSEN}" ]; then
#
#         # simply warn user
#         echo "You haven't selected a JDK version. Keeping PATH as is."
#
#     else
#
#         # check if the user selected "Reset path"
#         if [[ "\${CHOSEN}" == "Reset path" ]]; then
#             reset_path
#             echo "PATH has been reset to the original state."
#         else
#
#             # remove any existing JDK path from PATH
#             reset_path
#
#             # set the new JDK path
#             export PATH="\${JDK_DIR}/\${CHOSEN}/bin:\${PATH}"
#             echo "Updated PATH to include: \${JDK_DIR}/\${CHOSEN}/bin"
#         fi
#     fi
#
#     # unset the reset function
#     unset -f reset_path
# }
# **********************************************************************
SH

cat >"${ROOT_DIRECTORY_STRUCTURE}/scripts/completion.sh" <<SH || HOME_CONFIGURATION_HELPER_STATUS="${?}"
_${COMMAND_NAME}()
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

complete -F _${COMMAND_NAME} ${COMMAND_NAME}
SH

HOME_CONFIGURATION_FINAL_STATUS=0
cat >"${ROOT_DIRECTORY_STRUCTURE}/scripts/toolbox.sh" <<'TOOLBOX' || HOME_CONFIGURATION_FINAL_STATUS="${?}"
# check if inside a toolbox container
if [[ -f /run/.containerenv && -f /run/.toolboxenv ]]; then

    # add any toolbox-specific configuration inside this block,
    # e.g, path to TeX Live from the host system:
    #
    # pathmunge () {
    #     if ! echo $PATH | /bin/grep -E -q "(^|:)$1($|:)" ; then
    #         if [ "$2" = "after" ] ; then
    #             PATH=$PATH:$1
    #         else
    #             PATH=$1:$PATH
    #         fi
    #     fi
    # }
    #
    # pathmunge /var/run/host/opt/texbin after
    # unset pathmunge
    :
fi
TOOLBOX
if [ "${HOME_CONFIGURATION_FINAL_STATUS}" -ne 0 ]; then
    HOME_CONFIGURATION_HELPER_STATUS="${HOME_CONFIGURATION_FINAL_STATUS}"
fi
if [ "${HOME_CONFIGURATION_HELPER_STATUS}" -eq 0 ]; then
    ui_success "Fedora Workstation helper assets are ready."
else
    ui_error "Unable to create the Fedora Workstation helper assets."
    return "${HOME_CONFIGURATION_HELPER_STATUS}"
fi
return 0
