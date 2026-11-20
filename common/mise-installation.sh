#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "mise installation"

description "mise is a command line tool designed for setting up and managing \
development environments. It simplifies the installation of development tools \
and runtimes, manages environment variables, and can act as a task runner. By \
streamlining these processes, mise helps developers create consistent and \
efficient workflows, allowing them to focus more on coding and less on \
configuration."

echo

question "Do you want to install mise?"

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

    info "Getting latest version of mise from GitHub."
    test -f mise.json || wget -q -O mise.json https://api.github.com/repos/jdx/mise/releases/latest

    info "Downloading mise from GitHub."
    case "$(runtime_selected_architecture)" in
    x86_64) MISE_ASSET_SUFFIX="linux-x64.tar.gz" ;;
    aarch64) MISE_ASSET_SUFFIX="linux-arm64.tar.gz" ;;
    *)
        text "Unsupported architecture for mise: $(runtime_selected_architecture)."
        return 1
        ;;
    esac
    MISE_ASSET_URL=$(runtime_select_github_asset_by_suffix \
        mise.json "${MISE_ASSET_SUFFIX}") || return 1
    wget -q "${MISE_ASSET_URL}" -O mise.tar.gz

    info "Extracting mise."
    tar xzf mise.tar.gz

    info "Preparing the installation directory."
    mkdir -p "${HOME}/.local/bin"

    info "Moving binary to the installation directory."
    mv mise/bin/mise "${HOME}/.local/bin/"

    info "Creating data directory."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/data/mise"

    info "Creating configuration directory."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/config/mise"

    info "Removing archive file."
    rm -f mise.tar.gz
fi
