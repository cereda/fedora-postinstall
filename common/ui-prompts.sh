#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

UI_PROMPT_ACCEPTED=0
UI_PROMPT_DECLINED=1

if ! declare -F ui_error >/dev/null; then
    UI_PROMPT_UI_DIRECTORY="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" &&
        pwd -P)" || return 1
    source "${UI_PROMPT_UI_DIRECTORY}/ui.sh" || return 1
fi

function ui_prompt_binary {
    local ui_prompt_local_binary="${GUM:-}"
    local ui_prompt_local_resolved=""

    if [ -n "${ui_prompt_local_binary}" ]; then
        if [[ "${ui_prompt_local_binary}" == */* ]]; then
            if [ -f "${ui_prompt_local_binary}" ] &&
                [ -x "${ui_prompt_local_binary}" ] &&
                [ ! -d "${ui_prompt_local_binary}" ]; then
                printf '%s\n' "${ui_prompt_local_binary}"
                return 0
            fi
        else
            ui_prompt_local_resolved="$(command -v "${ui_prompt_local_binary}" || true)"
            if [ -n "${ui_prompt_local_resolved}" ] &&
                [ -f "${ui_prompt_local_resolved}" ] &&
                [ -x "${ui_prompt_local_resolved}" ]; then
                printf '%s\n' "${ui_prompt_local_resolved}"
                return 0
            fi
        fi

        ui_error "The configured interactive prompt backend is unavailable: ${ui_prompt_local_binary}"
        return 127
    fi

    ui_prompt_local_resolved="$(command -v gum || true)"
    if [ -n "${ui_prompt_local_resolved}" ] &&
        [ -f "${ui_prompt_local_resolved}" ] &&
        [ -x "${ui_prompt_local_resolved}" ]; then
        printf '%s\n' "${ui_prompt_local_resolved}"
        return 0
    fi

    ui_error "The interactive prompt backend is unavailable."
    return 127
}

function ui_confirm {
    local ui_prompt_local_prompt="${1:-}"
    local ui_prompt_local_affirmative="${2:-Yes}"
    local ui_prompt_local_negative="${3:-No}"
    local ui_prompt_local_binary
    local ui_prompt_local_output=""
    local ui_prompt_local_expected_decline=""
    local ui_prompt_local_status=0

    ui_prompt_local_binary="$(ui_prompt_binary)" || exit $?
    if ui_prompt_local_output=$("${ui_prompt_local_binary}" confirm \
        --show-output \
        --prompt.foreground=6 \
        --selected.background=6 \
        --affirmative="${ui_prompt_local_affirmative}" \
        --negative="${ui_prompt_local_negative}" \
        "${ui_prompt_local_prompt}"); then
        return "${UI_PROMPT_ACCEPTED}"
    else
        ui_prompt_local_status="${?}"
    fi

    # Gum uses status 1 both for a completed negative response and for some
    # operational failures. --show-output prints the completed selection on
    # standard output. Require the exact prompt and negative label so an
    # unrelated diagnostic cannot be mistaken for a completed decline.
    ui_prompt_local_expected_decline="${ui_prompt_local_prompt} ${ui_prompt_local_negative}"
    if [ "${ui_prompt_local_status}" -eq "${UI_PROMPT_DECLINED}" ] &&
        [ "${ui_prompt_local_output}" = "${ui_prompt_local_expected_decline}" ]; then
        return "${UI_PROMPT_DECLINED}"
    fi

    ui_error "Prompt failed with status ${ui_prompt_local_status}; aborting."
    exit "${ui_prompt_local_status}"
}

function ui_choose_one {
    local ui_prompt_local_header="${1:-Choose an option}"
    local ui_prompt_local_binary
    shift

    ui_prompt_local_binary="$(ui_prompt_binary)" || return $?
    "${ui_prompt_local_binary}" choose \
        --header="${ui_prompt_local_header}" \
        "$@"
}

function ui_choose_many {
    local ui_prompt_local_header="${1:-Choose one or more options}"
    local ui_prompt_local_selected="${2:-}"
    local ui_prompt_local_binary
    shift 2

    ui_prompt_local_binary="$(ui_prompt_binary)" || return $?
    if [ -n "${ui_prompt_local_selected}" ]; then
        "${ui_prompt_local_binary}" choose \
            --no-limit \
            --height=15 \
            --header="${ui_prompt_local_header}" \
            --selected="${ui_prompt_local_selected}" \
            "$@"
    else
        "${ui_prompt_local_binary}" choose \
            --no-limit \
            --height=15 \
            --header="${ui_prompt_local_header}" \
            "$@"
    fi
}

function ui_input {
    local ui_prompt_local_prompt="${1:-}"
    local ui_prompt_local_default="${2:-}"
    local ui_prompt_local_binary

    ui_prompt_local_binary="$(ui_prompt_binary)" || return $?
    if [ -n "${ui_prompt_local_default}" ]; then
        "${ui_prompt_local_binary}" input \
            --prompt="${ui_prompt_local_prompt}" \
            --value="${ui_prompt_local_default}"
    else
        "${ui_prompt_local_binary}" input \
            --prompt="${ui_prompt_local_prompt}"
    fi
}

function ui_select_directory {
    local ui_prompt_local_start="${1:-${HOME:-.}}"
    local ui_prompt_local_binary

    ui_prompt_local_binary="$(ui_prompt_binary)" || return $?
    # Restrict the chooser to directories while retaining its permissions view.
    "${ui_prompt_local_binary}" file \
        --all \
        --permissions \
        --file=false \
        --directory \
        "${ui_prompt_local_start}"
}
