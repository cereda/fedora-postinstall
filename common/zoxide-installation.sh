#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "zoxide installation"

description "zoxide is a command line tool designed to enhance navigation \
in the terminal by allowing users to quickly jump to frequently accessed \
directories. It uses a smart algorithm to track and prioritize directory \
usage, enabling faster access through simple commands."

echo

question "Do you want to install zoxide?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    # Note: GitHub may apply rate limits to the API endpoint, which could
    # cause this section to fail (been there, done that)

    info "Getting latest version of zoxide from GitHub."
    test -f zoxide.json || wget -q -O zoxide.json https://api.github.com/repos/ajeetdsouza/zoxide/releases/latest

    info "Downloading zoxide from GitHub."
    case "$(runtime_selected_architecture)" in
    x86_64) ZOXIDE_ASSET_SUFFIX="x86_64-unknown-linux-musl.tar.gz" ;;
    aarch64) ZOXIDE_ASSET_SUFFIX="aarch64-unknown-linux-musl.tar.gz" ;;
    *)
        text "Unsupported architecture for zoxide: $(runtime_selected_architecture)."
        return 1
        ;;
    esac
    ZOXIDE_ASSET_URL=$(runtime_select_github_asset_by_suffix \
        zoxide.json "${ZOXIDE_ASSET_SUFFIX}") || return 1
    wget -q "${ZOXIDE_ASSET_URL}" -O zoxide.tar.gz

    info "Extracting zoxide."
    mkdir -p zoxide-temp
    tar xzf zoxide.tar.gz -C zoxide-temp

    info "Preparing the installation directory."
    mkdir -p "${HOME}/.local/bin"

    info "Moving binary to the installation directory."
    mv zoxide-temp/zoxide "${HOME}/.local/bin/"

    info "Creating data directory."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/data/zoxide"

    info "Removing archive file."
    rm -f zoxide.tar.gz
fi
