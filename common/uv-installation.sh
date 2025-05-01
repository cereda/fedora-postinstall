#!/usr/bin/env bash

section "uv installation and configuration"

description "uv is an extremely fast Python package and project manager, \
written in Rust. It's faster than pip, and prrovides comprehensive project \
management, with a universal lockfile. It's also disk-space efficient, \
with a global cache for dependency deduplication."

echo

question "Do you want to install uv?"

if [ $? = 0 ]; then
    info "Installing uv."
    export UV_NO_MODIFY_PATH=1 && curl -LsSf https://astral.sh/uv/install.sh | sh
fi
