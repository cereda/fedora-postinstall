#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

# Shell-facing snapshot API. The implementation lives in a small Python
# helper so archive validation and path handling are consistent and safe.

function snapshot_python {
    local snapshot_local_python="${SNAPSHOT_PYTHON:-}"
    local snapshot_local_resolved=""

    if [ -n "${snapshot_local_python}" ]; then
        if [[ "${snapshot_local_python}" == */* ]]; then
            if [ -f "${snapshot_local_python}" ] &&
                [ -x "${snapshot_local_python}" ] &&
                [ ! -d "${snapshot_local_python}" ]; then
                printf '%s\n' "${snapshot_local_python}"
                return 0
            fi
        else
            snapshot_local_resolved=$(command -v "${snapshot_local_python}" || true)
            if [ -n "${snapshot_local_resolved}" ] &&
                [ -x "${snapshot_local_resolved}" ]; then
                printf '%s\n' "${snapshot_local_resolved}"
                return 0
            fi
        fi
        printf 'snapshot: the configured Python interpreter is unavailable: %s\n' \
            "${snapshot_local_python}" >&2
        return 127
    fi

    if command -v python3 >/dev/null 2>&1; then
        command -v python3
        return 0
    fi
    if command -v python >/dev/null 2>&1; then
        command -v python
        return 0
    fi

    printf 'snapshot: Python 3 is required.\n' >&2
    return 127
}

function snapshot_helper_path {
    local snapshot_local_directory=""
    local snapshot_local_path=""

    snapshot_local_directory=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" &&
        pwd -P) || return 1
    snapshot_local_path="${snapshot_local_directory}/snapshot.py"
    if [ ! -f "${snapshot_local_path}" ] || [ -L "${snapshot_local_path}" ]; then
        printf 'snapshot: the snapshot helper is unavailable.\n' >&2
        return 1
    fi
    printf '%s\n' "${snapshot_local_path}"
}

function snapshot_run_helper {
    local snapshot_local_python=""
    local snapshot_local_helper=""

    snapshot_local_python=$(snapshot_python) || return $?
    snapshot_local_helper=$(snapshot_helper_path) || return $?
    "${snapshot_local_python}" "${snapshot_local_helper}" "$@"
}

function snapshot_preflight {
    if [ "$#" -ne 0 ]; then
        printf 'snapshot: preflight does not accept arguments.\n' >&2
        return 64
    fi
    snapshot_run_helper "preflight"
}

function snapshot_create {
    local snapshot_local_label=""
    local -a snapshot_local_arguments=("create")

    if [ "$#" -gt 1 ]; then
        printf 'snapshot: create accepts at most one label.\n' >&2
        return 64
    fi
    if [ "$#" -eq 1 ]; then
        snapshot_local_label="${1}"
    fi
    if [ -n "${snapshot_local_label}" ]; then
        snapshot_local_arguments+=("${snapshot_local_label}")
    fi
    snapshot_run_helper "${snapshot_local_arguments[@]}"
}

function snapshot_list {
    if [ "$#" -ne 0 ]; then
        printf 'snapshot: list does not accept arguments.\n' >&2
        return 64
    fi
    snapshot_run_helper "list"
}

function snapshot_recover {
    if [ "$#" -ne 0 ]; then
        printf 'snapshot: recover does not accept arguments.\n' >&2
        return 64
    fi
    snapshot_run_helper "recover"
}

function snapshot_diff {
    if [ "$#" -ne 2 ]; then
        printf 'snapshot: diff requires two snapshot identifiers.\n' >&2
        return 64
    fi
    snapshot_run_helper "diff" "$1" "$2"
}

function snapshot_restore {
    local snapshot_local_identifier=""
    local snapshot_local_assume_yes=0
    local -a snapshot_local_arguments=()
    local snapshot_local_path

    if [ "$#" -eq 0 ]; then
        printf 'snapshot: restore requires a snapshot identifier.\n' >&2
        return 64
    fi
    snapshot_local_identifier="${1}"
    shift
    while [ "$#" -gt 0 ]; do
        case "${1}" in
        --path)
            shift
            if [ "$#" -eq 0 ]; then
                printf 'snapshot: --path requires a value.\n' >&2
                return 64
            fi
            snapshot_local_path="${1}"
            shift
            snapshot_local_arguments+=("--path=${snapshot_local_path}")
            ;;
        --path=*)
            snapshot_local_path="${1#--path=}"
            if [ -z "${snapshot_local_path}" ]; then
                printf 'snapshot: --path requires a value.\n' >&2
                return 64
            fi
            shift
            snapshot_local_arguments+=("--path=${snapshot_local_path}")
            ;;
        --yes)
            snapshot_local_assume_yes=1
            shift
            ;;
        *)
            printf 'snapshot: unknown restore option.\n' >&2
            return 64
            ;;
        esac
    done

    snapshot_local_arguments=("restore" "${snapshot_local_identifier}"
        "${snapshot_local_arguments[@]}")
    if [ "${snapshot_local_assume_yes}" -eq 1 ]; then
        snapshot_local_arguments+=("--yes")
    fi
    snapshot_run_helper "${snapshot_local_arguments[@]}"
}
