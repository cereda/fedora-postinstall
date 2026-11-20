#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "uv installation and configuration"

description "uv is an extremely fast Python package and project manager, \
written in Rust. It's faster than pip, and prrovides comprehensive project \
management, with a universal lockfile. It's also disk-space efficient, \
with a global cache for dependency deduplication."

echo

question "Do you want to install uv?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    # uv has its own installation script, avoiding path modification
    # via environment variable (as described in the documentation)
    info "Installing uv."
    export UV_NO_MODIFY_PATH=1 && curl -LsSf https://astral.sh/uv/install.sh | sh
fi
