#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

GUM_TEXT_WIDTH=75
GUM_PROMPT_ACCEPTED=0
GUM_PROMPT_DECLINED=1

function chapter {
    "${GUM}" style --border double \
        --align center \
        --width ${GUM_TEXT_WIDTH} \
        --padding "1 0" \
        --foreground 10 \
        --border-foreground 10 \
        "$1"
}

function section {
    "${GUM}" style --width ${GUM_TEXT_WIDTH} \
        --border rounded \
        --align center \
        --foreground 12 \
        --border-foreground 12 \
        "$1"
}

function tool-section {
    "${GUM}" style --width ${GUM_TEXT_WIDTH} \
        --border rounded \
        "Additional command line tools: $1"
}

# Prompt contract: status 0 means accepted, status 1 means declined, and any
# other status is an operational failure that aborts the installer with that
# status.
function question {
    local prompt="${1:-}"
    local gum="${GUM:-}"
    local status

    if [ -z "${gum}" ]; then
        gum="$(command -v gum || true)"
    fi
    if [ -z "${gum}" ]; then
        printf 'Unable to locate gum; aborting.\n' >&2
        exit 127
    fi

    if "${gum}" confirm \
        --prompt.foreground=6 \
        --selected.background=6 \
        "${prompt}"; then
        return "${GUM_PROMPT_ACCEPTED}"
    else
        status="${?}"
    fi

    if [ "${status}" -eq "${GUM_PROMPT_DECLINED}" ]; then
        return "${GUM_PROMPT_DECLINED}"
    fi

    printf 'Prompt failed with status %s; aborting.\n' "${status}" >&2
    exit "${status}"
}

function text {
    "${GUM}" style --width ${GUM_TEXT_WIDTH} \
        "$1"
}

function description {
    "${GUM}" style --width ${GUM_TEXT_WIDTH} \
        --italic \
        "$1"
}

function info {
    "${GUM}" style --width ${GUM_TEXT_WIDTH} \
        --foreground 11 \
        "$1"
}

function warning {
    "${GUM}" style --width ${GUM_TEXT_WIDTH} \
        --foreground 3 \
        --italic \
        "$1"
}
