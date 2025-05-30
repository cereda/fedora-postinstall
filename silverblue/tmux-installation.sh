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

section "tmux installation and configuration"

description "tmux is a terminal multiplexer, which allows you to create and \
manage multiple terminal sessions within a single window. It enables you to \
split your terminal into multiple panes, each running a separate process, \
and switch between them easily."

echo

question "Do you want to install and configure tmux?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    info "Installing tmux as an RPM package."
    toolbox --container ${TOOLBOX_NAME} run sudo dnf install tmux

    info "Creating the configuration directories for tmux."
    mkdir -p "${HOME}/.config/tmux/plugins"

    info "Downloading the tmux plugin manager (TPM)."
    git clone https://github.com/tmux-plugins/tpm "${HOME}/.config/tmux/plugins/tpm"

    info "Creating the configuration file."
    tee "${HOME}/.config/tmux/tmux.conf" <<EOF
# default plugins to make tpm work
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-sensible'

# my personal configuration
set -g @plugin 'jaclu/tmux-menus'
set -g @plugin 'wfxr/tmux-power'
set -g @tmux_power_theme 'moon'

# initialize the plugin manager
run '~/.config/tmux/plugins/tpm/tpm'
EOF

fi

# Default prefix: Ctrl + b
#
# Installing plugins
# - Add new plugin to ~/.config/tmux/tmux.conf with set -g @plugin '...'
# - Press prefix + I (capital i, as in Install) to fetch the plugin.
#
# The plugin was cloned to ~/.config/tmux/plugins/ directory and sourced.
#
# Uninstalling plugins
# - Remove (or comment out) plugin from the list.
# - Press prefix + alt + u (lowercase u as in uninstall) to remove the plugin.
#
# All the plugins are installed to ~/.config/tmux/plugins/ so alternatively 
# you can find plugin directory there and remove it.
#
# Key bindings
#
# prefix + I
# - Installs new plugins from GitHub or any other git repository
# - Refreshes the tmux environment
#
# prefix + U
# - updates plugin(s)
#
# prefix + alt + u
# - remove/uninstall plugins not on the plugin list
