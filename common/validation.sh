#!/usr/bin/env bash

# MIT License
#
# Copyright (c) 2026, Paulo Cereda
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

function is_valid_hostname {
    [[ "${1}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

function is_valid_container_name {
    [[ "${1}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$ ]]
}

function is_valid_git_name {
    [[ -n "${1}" && "${1}" != *$'\n'* && "${1}" != *$'\r'* ]]
}

function is_valid_git_email {
    [[ "${1}" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]]
}

function is_valid_root_directory {
    local candidate="${1}"
    local canonical_home
    local canonical_parent
    local canonical_candidate
    local candidate_parent
    local candidate_name

    canonical_home=$(realpath -e -- "${HOME}") || return 1
    candidate_parent=$(dirname -- "${candidate}")
    candidate_name=$(basename -- "${candidate}")
    [[ "${candidate_name}" != "." && "${candidate_name}" != ".." ]] || return 1
    canonical_parent=$(realpath -e -- "${candidate_parent}") || return 1
    canonical_candidate="${canonical_parent}/${candidate_name}"

    [[ "${canonical_candidate}" == "${canonical_home}" || "${canonical_candidate}" == "${canonical_home}/"* ]] || return 1
    [[ "${canonical_candidate}" =~ ^/[A-Za-z0-9_./-]+$ ]] || return 1

    if [ -d "${canonical_candidate}" ]; then
        [[ -w "${canonical_candidate}" ]] || return 1
    else
        [[ -w "${canonical_parent}" ]] || return 1
    fi
}

function validate_root_directory {
    local candidate="${1}"

    if ! is_valid_root_directory "${candidate}"; then
        warning "The configuration directory must be an existing writable directory under ${HOME} and contain only letters, digits, dots, underscores, slashes, and hyphens."
        return 1
    fi
}

function prompt_valid_hostname {
    local value

    while true; do
        value=$("${GUM}" input --prompt "Your machine name: ")
        if is_valid_hostname "${value}"; then
            printf '%s\n' "${value}"
            return 0
        fi

        warning "Invalid hostname. Use 1-63 letters, digits, or hyphens; it must not start or end with a hyphen."
    done
}

function prompt_valid_container_name {
    local prompt="${1}"
    local default="${2:-}"
    local value

    while true; do
        if [ -n "${default}" ]; then
            value=$("${GUM}" input --prompt "${prompt}" --value "${default}")
        else
            value=$("${GUM}" input --prompt "${prompt}")
        fi

        if is_valid_container_name "${value}"; then
            printf '%s\n' "${value}"
            return 0
        fi

        warning "Invalid container name. Use 1-63 letters, digits, dots, underscores, or hyphens."
    done
}

function prompt_valid_git_name {
    local value

    while true; do
        value=$("${GUM}" input --prompt "Your full name: ")
        if is_valid_git_name "${value}"; then
            printf '%s\n' "${value}"
            return 0
        fi

        warning "The Git user name cannot be empty or contain line breaks."
    done
}

function prompt_valid_git_email {
    local value

    while true; do
        value=$("${GUM}" input --prompt "Your e-mail address: ")
        if is_valid_git_email "${value}"; then
            printf '%s\n' "${value}"
            return 0
        fi

        warning "Invalid e-mail address. Use a non-empty address in the form user@example.com."
    done
}
