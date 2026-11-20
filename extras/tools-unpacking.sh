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

declare -gA EXTRAS_STAGED_BINARIES=()
declare -gA EXTRAS_STAGED_TOOLS=()

function extras_archive_path_is_safe {
    local path="${1}"

    if [ -z "${path}" ] || [[ "${path}" == /* ]] || [[ "${path}" == *\\* ]]; then
        return 1
    fi

    case "/${path}/" in
    */../*) return 1 ;;
    esac

    if [[ "${path}" =~ [[:cntrl:]] ]]; then
        return 1
    fi

    return 0
}

function extras_stage_executable {
    local tool="${1}"
    local source_path="${2}"
    local target_name="${3}"
    local staged_path

    if [ ! -f "${source_path}" ] || [ -L "${source_path}" ]; then
        printf 'extras: invalid executable for tool "%s"\n' "${tool}" >&2
        return 1
    fi

    if [ -n "${EXTRAS_STAGED_BINARIES[${target_name}]:-}" ]; then
        printf 'extras: duplicate executable target: %s\n' "${target_name}" >&2
        return 1
    fi

    staged_path="${EXTRAS_WORKSPACE}/staged/${target_name}"
    if ! install -m 0755 "${source_path}" "${staged_path}"; then
        printf 'extras: unable to stage executable "%s"\n' "${target_name}" >&2
        return 1
    fi

    EXTRAS_STAGED_BINARIES["${target_name}"]="${staged_path}"
    EXTRAS_STAGED_TOOLS["${target_name}"]="${tool}"
    if ! printf '%s\t%s\t%s\n' "${target_name}" "${staged_path}" "${tool}" \
        >>"${EXTRAS_STAGE_LEDGER}"; then
        printf 'extras: unable to update the staging ledger for tool "%s"\n' "${tool}" >&2
        return 1
    fi
}

function unpack_extras_tools {
    local tool archive archive_type extraction_directory
    local entry source_name target_name downloaded_filename staged_path
    local -a members=()

    for tool in "$@"; do
        archive="${EXTRAS_DOWNLOADED_ASSETS[${tool}]:-}"
        archive_type="${EXTRAS_DOWNLOADED_TYPES[${tool}]:-}"
        downloaded_filename="${EXTRAS_DOWNLOADED_FILENAMES[${tool}]:-}"

        if [ -z "${archive}" ] || [ ! -f "${archive}" ] || [ -z "${archive_type}" ]; then
            printf 'extras: downloaded artifact was not tracked for tool "%s"\n' "${tool}" >&2
            return 1
        fi

        entry=$(extras_manifest_entry "${tool}" "${EXTRAS_ARCHITECTURE}")
        extraction_directory="${EXTRAS_WORKSPACE}/extracted/${tool}"

        if [ "${archive_type}" = "none" ]; then
            if [ "$(basename -- "${archive}")" != "${downloaded_filename}" ]; then
                printf 'extras: invalid standalone artifact for tool "%s"\n' "${tool}" >&2
                return 1
            fi
        else
            members=()
            while IFS=$'\t' read -r source_name target_name; do
                members+=("${source_name}")
            done < <(jq -r '.files | to_entries[] | [.key, .value] | @tsv' <<<"${entry}")

            if [ "${#members[@]}" -eq 0 ]; then
                printf 'extras: no executables declared for tool "%s"\n' "${tool}" >&2
                return 1
            fi

            if ! python3 "${SCRIPT_PATH}/extras/archive-extract.py" \
                --archive "${archive}" \
                --type "${archive_type}" \
                --destination "${extraction_directory}" \
                --members "${members[@]}"; then
                printf 'extras: unable to unpack tool "%s"\n' "${tool}" >&2
                return 1
            fi
        fi

        while IFS=$'\t' read -r source_name target_name; do
            if [ "${archive_type}" = "none" ]; then
                if [ "$(basename -- "${archive}")" != "${source_name}" ]; then
                    printf 'extras: invalid standalone executable for tool "%s"\n' "${tool}" >&2
                    return 1
                fi
                staged_path="${archive}"
            else
                staged_path="${extraction_directory}/${source_name}"
            fi

            if ! extras_stage_executable "${tool}" "${staged_path}" "${target_name}"; then
                return 1
            fi
        done < <(jq -r '.files | to_entries[] | [.key, .value] | @tsv' <<<"${entry}")
    done
}
