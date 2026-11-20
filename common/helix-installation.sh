#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Helix installation and configuration"

description "Helix is an open source, modal code editor that aims to \
provide a modern, efficient, and customizable text editing experience. \
It's designed to be fast, lightweight, and highly extensible, with a \
focus on productivity and developer experience."

echo

question "Do you want to install and configure Helix?"

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

    info "Getting latest version of Helix from GitHub."
    test -f helix-editor.json || wget -q -O helix-editor.json https://api.github.com/repos/helix-editor/helix/releases/latest

    info "Downloading Helix from GitHub."
    case "$(runtime_selected_architecture)" in
    x86_64) HELIX_ASSET_SUFFIX="x86_64-linux.tar.xz" ;;
    aarch64) HELIX_ASSET_SUFFIX="aarch64-linux.tar.xz" ;;
    *)
        text "Unsupported architecture for Helix: $(runtime_selected_architecture)."
        return 1
        ;;
    esac
    HELIX_ASSET_URL=$(runtime_select_github_asset_by_suffix \
        helix-editor.json "${HELIX_ASSET_SUFFIX}") || return 1
    wget -q "${HELIX_ASSET_URL}" -O helix.tar.xz

    info "Extracting Helix."
    rm -rf helix-temp
    mkdir -p helix-temp
    tar xJf helix.tar.xz -C helix-temp
    HELIX_SOURCE_DIRECTORY=$(find helix-temp -mindepth 1 -maxdepth 1 -type d -print -quit)
    if [ -z "${HELIX_SOURCE_DIRECTORY}" ]; then
        text "The Helix archive does not contain an application directory."
        return 1
    fi

    info "Renaming application directory."
    rm -rf helix-editor
    mv "${HELIX_SOURCE_DIRECTORY}" helix-editor

    info "Moving Helix."
    mv "helix-editor" "${ROOT_DIRECTORY_STRUCTURE}/applications/"

    info "Creating configuration file for Helix."
    mkdir -p "${HOME}/.config/helix"
    tee "${HOME}/.config/helix/config.toml" <<EOF
theme = "onedark"

[editor]
line-number = "relative"
cursorline = true

[editor.cursor-shape]
insert = "bar"
normal = "block"
select = "underline"

[editor.file-picker]
hidden = false

[editor.indent-guides]
render = true

[keys.normal]
F1 = ":set whitespace.render none"
F2 = ":set whitespace.render all"
F3 = ":w"
F4 = ":wq"
F5 = ":q!"

[editor.soft-wrap]
enable = true
EOF

    info "Creating symbolic link to make Helix available."
    mkdir -p "${HOME}/.local/bin"
    ln -s "${ROOT_DIRECTORY_STRUCTURE}/applications/helix-editor/hx" "${HOME}/.local/bin/hx"

    echo

    warning "If you don't plan to install vim or neovim, consider creating \
aliases for vim or nvim that point to Helix (e.g, alias vim='hx')."

    info "Removing archive file."
    rm -rf helix-temp helix.tar.xz

fi
