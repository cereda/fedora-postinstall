#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Git configuration"

description "Git is a distributed version control system used for tracking \
changes in source code during software development, allowing multiple \
developers to collaborate on a project."

echo

warning "This configuration uses 'git-delta' as pager and 'vim' as editor. \
Make sure you have these packages installed on your system, or edit the \
configuration to use your preferred settings."

echo

# ask for user input (name and e-mail address)
GIT_USERNAME=$(prompt_valid_git_name)
GIT_EMAIL=$(prompt_valid_git_email)

# XDG-based configuration
GIT_CONFIG_LOCATION="${HOME}/.config/git"

# legacy configuration
# GIT_CONFIG_LOCATION="${HOME}"

# XDG-based configuration file
GIT_CONFIG_FILE="config"

# legacy configuration file
# GIT_CONFIG_FILE=".gitconfig"

# ensure XDG-based path exists
mkdir -p "${GIT_CONFIG_LOCATION}"

# ensure the hooks path exists
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
