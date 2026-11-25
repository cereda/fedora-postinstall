#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Git configuration"

ui_description "Configure your Git identity, email, editor, pager, and hooks."
ui_warning "This configuration uses 'git-delta' as the pager and 'vim' as the editor. Ensure both are installed, or adjust the generated configuration to your preferences."

if GIT_USERNAME=$(prompt_valid_git_name); then
    GIT_USERNAME_STATUS=0
else
    GIT_USERNAME_STATUS="${?}"
fi
if [ "${GIT_USERNAME_STATUS}" -ne 0 ]; then
    return "${GIT_USERNAME_STATUS}"
fi
if GIT_EMAIL=$(prompt_valid_git_email); then
    GIT_EMAIL_STATUS=0
else
    GIT_EMAIL_STATUS="${?}"
fi
if [ "${GIT_EMAIL_STATUS}" -ne 0 ]; then
    return "${GIT_EMAIL_STATUS}"
fi

# Store user configuration in XDG while keeping hooks in the managed tree.
GIT_CONFIG_ROOT="${XDG_CONFIG_HOME:-${HOME}/.config}"
if [[ "${GIT_CONFIG_ROOT}" != /* ]]; then
    GIT_CONFIG_ROOT="${HOME}/.config"
fi
GIT_CONFIG_LOCATION="${GIT_CONFIG_ROOT}/git"
GIT_CONFIG_FILE="config"

mkdir -p "${GIT_CONFIG_LOCATION}"

mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/config/git/hooks"

ui_step "Generating the Git configuration."
git config --file "${GIT_CONFIG_LOCATION}/${GIT_CONFIG_FILE}" user.name "${GIT_USERNAME}"
git config --file "${GIT_CONFIG_LOCATION}/${GIT_CONFIG_FILE}" user.email "${GIT_EMAIL}"
git config --file "${GIT_CONFIG_LOCATION}/${GIT_CONFIG_FILE}" core.editor "vim"
git config --file "${GIT_CONFIG_LOCATION}/${GIT_CONFIG_FILE}" core.pager "delta"
git config --file "${GIT_CONFIG_LOCATION}/${GIT_CONFIG_FILE}" core.hooksPath "${ROOT_DIRECTORY_STRUCTURE}/config/git/hooks"
git config --file "${GIT_CONFIG_LOCATION}/${GIT_CONFIG_FILE}" push.default "simple"
git config --file "${GIT_CONFIG_LOCATION}/${GIT_CONFIG_FILE}" interactive.diffFilter "delta --color-only"
git config --file "${GIT_CONFIG_LOCATION}/${GIT_CONFIG_FILE}" delta.side-by-side "true"
git config --file "${GIT_CONFIG_LOCATION}/${GIT_CONFIG_FILE}" delta.line-numbers "true"
