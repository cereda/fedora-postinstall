#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Git configuration"

description "Configure Git identity, editor, pager, and hooks."
echo

warning "This configuration uses 'git-delta' as pager and 'vim' as editor. \
Make sure you have these packages installed on your system, or edit the \
configuration to use your preferred settings."

echo

GIT_USERNAME=$(prompt_valid_git_name)
GIT_EMAIL=$(prompt_valid_git_email)

# Store user configuration in XDG while keeping hooks in the managed tree.
GIT_CONFIG_ROOT="${XDG_CONFIG_HOME:-${HOME}/.config}"
if [[ "${GIT_CONFIG_ROOT}" != /* ]]; then
    GIT_CONFIG_ROOT="${HOME}/.config"
fi
GIT_CONFIG_LOCATION="${GIT_CONFIG_ROOT}/git"
GIT_CONFIG_FILE="config"

mkdir -p "${GIT_CONFIG_LOCATION}"

mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/config/git/hooks"

info "Generating configuration file for Git."
git config --file "${GIT_CONFIG_LOCATION}/${GIT_CONFIG_FILE}" user.name "${GIT_USERNAME}"
git config --file "${GIT_CONFIG_LOCATION}/${GIT_CONFIG_FILE}" user.email "${GIT_EMAIL}"
git config --file "${GIT_CONFIG_LOCATION}/${GIT_CONFIG_FILE}" core.editor "vim"
git config --file "${GIT_CONFIG_LOCATION}/${GIT_CONFIG_FILE}" core.pager "delta"
git config --file "${GIT_CONFIG_LOCATION}/${GIT_CONFIG_FILE}" core.hooksPath "${ROOT_DIRECTORY_STRUCTURE}/config/git/hooks"
git config --file "${GIT_CONFIG_LOCATION}/${GIT_CONFIG_FILE}" push.default "simple"
git config --file "${GIT_CONFIG_LOCATION}/${GIT_CONFIG_FILE}" interactive.diffFilter "delta --color-only"
git config --file "${GIT_CONFIG_LOCATION}/${GIT_CONFIG_FILE}" delta.side-by-side "true"
git config --file "${GIT_CONFIG_LOCATION}/${GIT_CONFIG_FILE}" delta.line-numbers "true"
