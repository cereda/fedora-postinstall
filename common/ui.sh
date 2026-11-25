#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

# The installer uses native Bash for static messages. Gum is reserved for
# interactive controls; keeping the two concerns separate avoids starting a
# presentation process for every line of progress.
declare -g UI_COLOR_OVERRIDE="${UI_COLOR_OVERRIDE:-auto}"
declare -g UI_SECTION_SEEN=0

UI_ANSI_RESET=$'\033[0m'
UI_ANSI_TITLE=$'\033[1;34m'
UI_ANSI_SECTION=$'\033[1;34m'
UI_ANSI_SUBSECTION=$'\033[1;36m'
UI_ANSI_DESCRIPTION=$'\033[2m'
UI_ANSI_STEP=$'\033[36m'
UI_ANSI_SUCCESS=$'\033[32m'
UI_ANSI_SKIP=$'\033[2m'
UI_ANSI_WARNING=$'\033[33m'
UI_ANSI_ERROR=$'\033[31m'
UI_ANSI_SUMMARY=$'\033[1m'

function ui_color_enabled {
    local ui_local_fd="${1:-1}"

    # NO_COLOR and TERM=dumb are hard opt-outs. The explicit override exists
    # for deterministic tests and for terminals that need a forced palette.
    [ -z "${NO_COLOR:-}" ] || return 1
    [ "${TERM:-}" != "dumb" ] || return 1

    case "${UI_COLOR_OVERRIDE}" in
    always) return 0 ;;
    never) return 1 ;;
    auto) ;;
    *) ;;
    esac

    [[ -t "${ui_local_fd}" ]]
}

function ui_render_message {
    local ui_local_role="${1:-text}"
    local ui_local_message="${2:-}"
    local ui_local_fd="${3:-1}"
    local ui_local_prefix=""
    local ui_local_code=""
    local ui_local_reset=""
    local ui_local_line
    local ui_local_first=1
    local ui_local_status=0

    case "${ui_local_role}" in
    title)
        ui_local_code="${UI_ANSI_TITLE}"
        ;;
    section)
        ui_local_code="${UI_ANSI_SECTION}"
        ;;
    subsection)
        ui_local_code="${UI_ANSI_SUBSECTION}"
        ;;
    description)
        ui_local_code="${UI_ANSI_DESCRIPTION}"
        ;;
    step)
        ui_local_prefix="• "
        ui_local_code="${UI_ANSI_STEP}"
        ;;
    success)
        ui_local_prefix="✓ "
        ui_local_code="${UI_ANSI_SUCCESS}"
        ;;
    skip)
        ui_local_prefix="− "
        ui_local_code="${UI_ANSI_SKIP}"
        ;;
    warning)
        ui_local_prefix="! "
        ui_local_code="${UI_ANSI_WARNING}"
        ;;
    error)
        ui_local_prefix="✗ "
        ui_local_code="${UI_ANSI_ERROR}"
        ;;
    summary)
        ui_local_code="${UI_ANSI_SUMMARY}"
        ;;
    text)
        ;;
    *)
        ui_local_prefix="info: "
        ui_local_code="${UI_ANSI_STEP}"
        ;;
    esac

    if ui_color_enabled "${ui_local_fd}"; then
        ui_local_reset="${UI_ANSI_RESET}"
    else
        case "${ui_local_role}" in
        step) ui_local_prefix="info: " ;;
        success) ui_local_prefix="done: " ;;
        skip) ui_local_prefix="skipped: " ;;
        warning) ui_local_prefix="warning: " ;;
        error) ui_local_prefix="error: " ;;
        esac
        ui_local_code=""
        ui_local_reset=""
    fi

    while IFS= read -r ui_local_line || [ -n "${ui_local_line}" ]; do
        if [ "${ui_local_first}" -eq 1 ]; then
            ui_local_first=0
        else
            ui_local_prefix="  "
        fi

        if [ "${ui_local_fd}" -eq 2 ]; then
            printf '%s%s%s%s\n' \
                "${ui_local_code}" "${ui_local_prefix}" \
                "${ui_local_line}" "${ui_local_reset}" >&2 || {
                ui_local_status="${?}"
                break
            }
        else
            printf '%s%s%s%s\n' \
                "${ui_local_code}" "${ui_local_prefix}" \
                "${ui_local_line}" "${ui_local_reset}" || {
                ui_local_status="${?}"
                break
            }
        fi
    done <<<"${ui_local_message}"

    return "${ui_local_status}"
}

function ui_title {
    UI_SECTION_SEEN=0
    ui_render_message "title" "${1:-}" 1
}

function ui_section {
    if [ "${UI_SECTION_SEEN}" -eq 1 ]; then
        printf '\n' || return $?
    fi
    UI_SECTION_SEEN=1
    ui_render_message "section" "${1:-}" 1
}

function ui_subsection {
    printf '\n' || return $?
    ui_render_message "subsection" "${1:-}" 1
}

function ui_description {
    ui_render_message "description" "${1:-}" 1
}

function ui_text {
    ui_render_message "text" "${1:-}" 1
}

function ui_step {
    ui_render_message "step" "${1:-}" 1
}

function ui_success {
    ui_render_message "success" "${1:-}" 1
}

function ui_skip {
    ui_render_message "skip" "${1:-}" 1
}

function ui_summary {
    ui_render_message "summary" "${1:-}" 1
}

function ui_warning {
    ui_render_message "warning" "${1:-}" 2
}

function ui_error {
    ui_render_message "error" "${1:-}" 2
}
