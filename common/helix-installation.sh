#!/usr/bin/env bash

section "Helix configuration"

description "Helix is an open-source, modal code editor that aims to \
provide a modern, efficient, and customizable text editing experience. \
It's designed to be fast, lightweight, and highly extensible, with a \
focus on productivity and developer experience."

echo

question "Do you want to install and configure Helix?"

if [ $? = 0 ]; then

    info "Getting latest version of Helix from GitHub."
    test -f helix-editor.json || wget -q -O helix-editor.json https://api.github.com/repos/helix-editor/helix/releases/latest

    info "Downloading Helix from GitHub."
    wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux")).browser_download_url' helix-editor.json)

    info "Extracting Helix."
    tar xJf helix-*-x86_64-linux.tar.xz

    info "Renaming application directory."
    mv helix-*-linux helix-editor

    info "Moving Helix."
    mv "helix-editor" "${ROOT_DIRECTORY_STRUCTURE}/applications/"

    info "Creating configuration file."
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

fi

