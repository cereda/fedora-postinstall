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

declare -gA EXTRAS_DOWNLOADED_ASSETS=()
declare -gA EXTRAS_DOWNLOADED_TYPES=()
declare -gA EXTRAS_DOWNLOADED_FILENAMES=()

function extras_detect_architecture {
    local machine

    machine=$(uname -m)

    case "${machine}" in
    x86_64 | amd64) printf '%s\n' "x86_64" ;;
    aarch64 | arm64) printf '%s\n' "aarch64" ;;
    *)
        return 1
        ;;
    esac
}

function extras_manifest_entry {
    local tool="${1}"
    local architecture="${2}"

    jq -ce --arg tool "${tool}" --arg architecture "${architecture}" \
        '.tools[$tool].assets[$architecture] // .tools[$tool].assets.any // empty' \
        "${EXTRAS_MANIFEST_FILE}"
}

function extras_manifest_version {
    local tool="${1}"

    jq -r --arg tool "${tool}" '.tools[$tool].version // empty' \
        "${EXTRAS_MANIFEST_FILE}"
}

function extras_validate_manifest_file {
    if [ ! -f "${EXTRAS_MANIFEST_FILE}" ] || [ -L "${EXTRAS_MANIFEST_FILE}" ]; then
        printf 'extras: manifest is not a regular file: %s\n' "${EXTRAS_MANIFEST_FILE}" >&2
        return 1
    fi

    if ! jq -e '.schema_version == 1 and (.tools | type == "object")' \
        "${EXTRAS_MANIFEST_FILE}" >/dev/null; then
        printf 'extras: invalid command line tool manifest: %s\n' "${EXTRAS_MANIFEST_FILE}" >&2
        return 1
    fi
}

function extras_validate_manifest_entry {
    local tool="${1}"
    local architecture="${2}"
    local entry url checksum archive_type source target version filename
    local url_regex='^https://[A-Za-z0-9._~:/?#@!$&()*,;=%+-]+$'
    local component normalized_source

    if ! [[ "${tool}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        printf 'extras: invalid tool identifier: %s\n' "${tool}" >&2
        return 1
    fi

    if ! entry=$(extras_manifest_entry "${tool}" "${architecture}"); then
        printf 'extras: tool "%s" is not available for architecture %s\n' \
            "${tool}" "${architecture}" >&2
        return 1
    fi

    url=$(jq -r '.url // empty' <<<"${entry}")
    checksum=$(jq -r '.sha256 // empty' <<<"${entry}")
    archive_type=$(jq -r '.type // empty' <<<"${entry}")
    version=$(extras_manifest_version "${tool}")

    if ! [[ "${url}" =~ ${url_regex} ]]; then
        printf 'extras: invalid download URL for tool "%s"\n' "${tool}" >&2
        return 1
    fi

    case "/${url}/" in
    */latest/* | */master/* | */main/* | */HEAD/*)
        printf 'extras: download URL for tool "%s" is not pinned\n' "${tool}" >&2
        return 1
        ;;
    esac

    if ! [[ "${checksum}" =~ ^[0-9a-f]{64}$ ]]; then
        printf 'extras: invalid SHA-256 checksum for tool "%s"\n' "${tool}" >&2
        return 1
    fi

    if ! [[ "${archive_type}" =~ ^(tar\.gz|zip|none)$ ]]; then
        printf 'extras: invalid archive type for tool "%s"\n' "${tool}" >&2
        return 1
    fi

    if [ -z "${version}" ] || [ "${version}" = "latest" ]; then
        printf 'extras: invalid version for tool "%s"\n' "${tool}" >&2
        return 1
    fi

    if [[ "${url}" != *"${version}"* ]]; then
        printf 'extras: download URL for tool "%s" does not match its pinned version\n' "${tool}" >&2
        return 1
    fi

    if ! jq -e '.files | type == "object" and length > 0' <<<"${entry}" >/dev/null; then
        printf 'extras: no executable declared for tool "%s"\n' "${tool}" >&2
        return 1
    fi

    while IFS=$'\t' read -r source target; do
        if ! [[ "${target}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
            printf 'extras: invalid executable target for tool "%s"\n' "${tool}" >&2
            return 1
        fi

        if [ "${archive_type}" = "none" ]; then
            if ! [[ "${source}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
                printf 'extras: invalid standalone executable for tool "%s"\n' "${tool}" >&2
                return 1
            fi
        else
            if ! extras_archive_path_is_safe "${source}"; then
                printf 'extras: unsafe executable member for tool "%s"\n' "${tool}" >&2
                return 1
            fi
            normalized_source="${source#./}"
            IFS='/' read -r -a path_components <<<"${normalized_source}"
            for component in "${path_components[@]}"; do
                if [ -z "${component}" ] || [ "${component}" = "." ] || [ "${component}" = ".." ]; then
                    printf 'extras: unsafe executable member for tool "%s"\n' "${tool}" >&2
                    return 1
                fi
            done
        fi
    done < <(jq -r '.files | to_entries[] | [.key, .value] | @tsv' <<<"${entry}")

    if [ "$(jq '.files | to_entries | map(.value) | unique | length' <<<"${entry}")" -ne \
        "$(jq '.files | length' <<<"${entry}")" ]; then
        printf 'extras: duplicate executable target for tool "%s"\n' "${tool}" >&2
        return 1
    fi

    filename=$(basename -- "${url}")
    if [ -z "${filename}" ] || [ "${filename}" = "." ] || [ "${filename}" = ".." ]; then
        printf 'extras: invalid artifact filename for tool "%s"\n' "${tool}" >&2
        return 1
    fi

    if [ "${archive_type}" = "none" ]; then
        if [ "$(jq '.files | length' <<<"${entry}")" -ne 1 ]; then
            printf 'extras: standalone tool "%s" must declare exactly one executable\n' "${tool}" >&2
            return 1
        fi
        if [ "${filename}" != "$(jq -r '.files | keys[0]' <<<"${entry}")" ]; then
            printf 'extras: standalone artifact does not match tool "%s"\n' "${tool}" >&2
            return 1
        fi
    fi

    return 0
}

function extras_validate_selected_tools {
    local tool target existing_target entry
    local -A selected_targets=()

    for tool in "$@"; do
        if ! extras_validate_manifest_entry "${tool}" "${EXTRAS_ARCHITECTURE}"; then
            return 1
        fi

        entry=$(extras_manifest_entry "${tool}" "${EXTRAS_ARCHITECTURE}")
        while IFS= read -r target; do
            existing_target="${selected_targets[${target}]:-}"
            if [ -n "${existing_target}" ]; then
                printf 'extras: tools "%s" and "%s" deploy the same command "%s"\n' \
                    "${existing_target}" "${tool}" "${target}" >&2
                return 1
            fi
            selected_targets["${target}"]="${tool}"
        done < <(jq -r '.files | to_entries[].value' <<<"${entry}")
    done
}

function download_extras_tool {
    local tool="${1}"
    local entry url checksum archive_type version filename
    local download_directory destination partial actual_checksum

    if [ -z "${EXTRAS_WORKSPACE:-}" ] || [ ! -d "${EXTRAS_WORKSPACE}" ]; then
        printf 'extras: download workspace is not initialized\n' >&2
        return 1
    fi

    if ! entry=$(extras_manifest_entry "${tool}" "${EXTRAS_ARCHITECTURE}"); then
        printf 'extras: no manifest entry for tool "%s"\n' "${tool}" >&2
        return 1
    fi

    if ! extras_validate_manifest_entry "${tool}" "${EXTRAS_ARCHITECTURE}"; then
        return 1
    fi

    url=$(jq -r '.url' <<<"${entry}")
    checksum=$(jq -r '.sha256' <<<"${entry}")
    archive_type=$(jq -r '.type' <<<"${entry}")
    version=$(extras_manifest_version "${tool}")
    filename=$(basename -- "${url}")

    if [ -n "${EXTRAS_DOWNLOADED_ASSETS[${tool}]:-}" ]; then
        printf 'extras: tool "%s" was downloaded more than once\n' "${tool}" >&2
        return 1
    fi

    download_directory="${EXTRAS_WORKSPACE}/downloads/${tool}"
    destination="${download_directory}/${filename}"
    partial="${destination}.part"

    if ! mkdir -p "${download_directory}"; then
        printf 'extras: unable to create download directory for tool "%s"\n' "${tool}" >&2
        return 1
    fi

    rm -f -- "${partial}"

    info "Downloading ${tool} ${version} (${EXTRAS_ARCHITECTURE})."
    if ! curl \
        --fail \
        --location \
        --silent \
        --show-error \
        --retry 3 \
        --retry-delay 2 \
        --connect-timeout 20 \
        --max-time 900 \
        --proto '=https' \
        --tlsv1.2 \
        --output "${partial}" \
        "${url}"; then
        rm -f -- "${partial}"
        printf 'extras: download failed for tool "%s"\n' "${tool}" >&2
        return 1
    fi

    actual_checksum=$(sha256sum -- "${partial}")
    actual_checksum="${actual_checksum%% *}"
    if [ "${actual_checksum}" != "${checksum}" ]; then
        rm -f -- "${partial}"
        printf 'extras: checksum verification failed for tool "%s"\n' "${tool}" >&2
        printf 'extras: expected %s, got %s\n' "${checksum}" "${actual_checksum}" >&2
        return 1
    fi

    if ! mv -f -- "${partial}" "${destination}"; then
        rm -f -- "${partial}"
        printf 'extras: unable to store downloaded artifact for tool "%s"\n' "${tool}" >&2
        return 1
    fi

    EXTRAS_DOWNLOADED_ASSETS["${tool}"]="${destination}"
    EXTRAS_DOWNLOADED_TYPES["${tool}"]="${archive_type}"
    EXTRAS_DOWNLOADED_FILENAMES["${tool}"]="${filename}"
    if ! printf '%s\t%s\t%s\t%s\n' \
        "${tool}" "${archive_type}" "${destination}" "${checksum}" \
        >>"${EXTRAS_ARTIFACT_LEDGER}"; then
        printf 'extras: unable to update the artifact ledger for tool "%s"\n' "${tool}" >&2
        return 1
    fi

    info "Verified SHA-256 checksum for ${tool}."
    return 0
}
