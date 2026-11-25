#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

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
        ui_error "Invalid command for command-line tool ${tool}."
        return 1
    fi

    if [ -n "${EXTRAS_STAGED_BINARIES[${target_name}]:-}" ]; then
        ui_error "Duplicate command target: ${target_name}."
        return 1
    fi

    staged_path="${EXTRAS_WORKSPACE}/staged/${target_name}"
    if ! install -m 0755 "${source_path}" "${staged_path}"; then
        ui_error "Could not stage the command ${target_name}. No command-line tools were deployed."
        return 1
    fi

    EXTRAS_STAGED_BINARIES["${target_name}"]="${staged_path}"
    EXTRAS_STAGED_TOOLS["${target_name}"]="${tool}"
    if ! printf '%s\t%s\t%s\n' "${target_name}" "${staged_path}" "${tool}" \
        >>"${EXTRAS_STAGE_LEDGER}"; then
        ui_error "Could not update the staging ledger for ${tool}. Deployment will stop before any command is replaced."
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
            ui_error "The downloaded artifact was not tracked for command-line tool ${tool}."
            return 1
        fi

        entry=$(extras_manifest_entry "${tool}" "${EXTRAS_ARCHITECTURE}")
        extraction_directory="${EXTRAS_WORKSPACE}/extracted/${tool}"

        if [ "${archive_type}" = "none" ]; then
            if [ "$(basename -- "${archive}")" != "${downloaded_filename}" ]; then
                ui_error "Invalid standalone artifact for command-line tool ${tool}."
                return 1
            fi
        else
            members=()
            while IFS=$'\t' read -r source_name target_name; do
                members+=("${source_name}")
            done < <(jq -r '.files | to_entries[] | [.key, .value] | @tsv' <<<"${entry}")

            if [ "${#members[@]}" -eq 0 ]; then
                ui_error "No commands are declared for command-line tool ${tool}."
                return 1
            fi

            if ! python3 "${SCRIPT_PATH}/extras/archive-extract.py" \
                --archive "${archive}" \
                --type "${archive_type}" \
                --destination "${extraction_directory}" \
                --members "${members[@]}"; then
                ui_error "Could not extract command-line tool ${tool}. No command-line tools were deployed."
                return 1
            fi
        fi

        while IFS=$'\t' read -r source_name target_name; do
            if [ "${archive_type}" = "none" ]; then
                if [ "$(basename -- "${archive}")" != "${source_name}" ]; then
                    ui_error "Invalid standalone command for command-line tool ${tool}."
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
