#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

declare -gA EXTRAS_DOWNLOADED_ASSETS=()
declare -gA EXTRAS_DOWNLOADED_TYPES=()
declare -gA EXTRAS_DOWNLOADED_FILENAMES=()

function extras_detect_architecture {
    if declare -F runtime_selected_architecture >/dev/null; then
        runtime_selected_architecture
        return $?
    fi

    local machine
    machine=$(uname -m) || return 1
    case "${machine}" in
    x86_64 | amd64 | x64) printf '%s\n' "x86_64" ;;
    aarch64 | arm64) printf '%s\n' "aarch64" ;;
    *)
        return 1
        ;;
    esac
}

function extras_manifest_entry {
    local tool="${1}"
    local architecture="${2}"

    case "${architecture}" in
    x86_64 | aarch64) ;;
    *)
        printf 'extras: unsupported canonical architecture key: %s\n' \
            "${architecture}" >&2
        return 1
        ;;
    esac

    jq -ce --arg tool "${tool}" --arg architecture "${architecture}" \
        '.tools[$tool].assets[$architecture] // .tools[$tool].assets.any // empty' \
        "${EXTRAS_MANIFEST_FILE}"
}

function extras_tool_description {
    local tool="${1}"

    jq -r --arg tool "${tool}" '.tools[$tool].description // empty' \
        "${EXTRAS_MANIFEST_FILE}" || return 1
}

function extras_describe_tool {
    local tool="${1}"
    local label="${2:-${1}}"
    local tool_description

    tool_description=$(extras_tool_description "${tool}") || return 1
    tool-section "${label}" || return 1
    description "${tool_description}" || return 1
    echo || return 1
    return 0
}

function extras_prune_stale_partials {
    local tool="${1}"
    local directory="${2}"

    if ! python3 "${SCRIPT_PATH}/common/runtime-file.py" prune-partials \
        "${directory}"; then
        printf 'extras: unable to prune stale partial artifacts for tool "%s"\n' \
            "${tool}" >&2
    fi
    return 0
}

function extras_evict_obsolete_versions {
    local tool="${1}"
    local directory="${2}"
    local keep_name="${3}"

    if ! python3 "${SCRIPT_PATH}/common/runtime-file.py" prune-versions \
        "${directory}" "${keep_name}"; then
        printf 'extras: unable to evict obsolete cached versions for tool "%s"\n' \
            "${tool}" >&2
    fi
    return 0
}

function extras_record_downloaded_tool {
    local tool="${1}"
    local archive_type="${2}"
    local destination="${3}"
    local checksum="${4}"
    local filename="${5}"

    EXTRAS_DOWNLOADED_ASSETS["${tool}"]="${destination}"
    EXTRAS_DOWNLOADED_TYPES["${tool}"]="${archive_type}"
    EXTRAS_DOWNLOADED_FILENAMES["${tool}"]="${filename}"
    if ! printf '%s\t%s\t%s\t%s\n' \
        "${tool}" "${archive_type}" "${destination}" "${checksum}" \
        >>"${EXTRAS_ARTIFACT_LEDGER}"; then
        printf 'extras: unable to update the artifact ledger for tool "%s"\n' \
            "${tool}" >&2
        return 1
    fi
    return 0
}

function extras_available_tools_for_architecture {
    local extras_local_architecture="${1:-}"
    local extras_local_tool

    case "${extras_local_architecture}" in
    x86_64 | aarch64) ;;
    *)
        printf 'extras: unsupported canonical architecture key: %s\n' \
            "${extras_local_architecture}" >&2
        return 1
        ;;
    esac

    for extras_local_tool in "${CLI_TOOLS_LIST[@]}"; do
        if extras_manifest_entry "${extras_local_tool}" "${extras_local_architecture}" >/dev/null; then
            printf '%s\n' "${extras_local_tool}"
        fi
    done
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

    if ! jq -e '
        .schema_version == 1 and
        (.tools | type == "object") and
        all(.tools | to_entries[];
            (.key | test("^[a-z0-9][a-z0-9-]*$")) and
            (.value | type == "object") and
            (.value.description | type == "string") and
            (.value.description | length > 0) and
            (.value.description | length <= 100) and
            (.value.description | contains("\n") | not) and
            (.value.description | contains("\r") | not) and
            (.value.assets | type == "object") and
            (.value.assets | length > 0) and
            (((.value.assets | keys) - ["x86_64", "aarch64", "any"]) | length == 0)
        )
    ' "${EXTRAS_MANIFEST_FILE}" >/dev/null; then
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
    local tool target existing_target entry registered candidate
    local -A selected_targets=()

    for tool in "$@"; do
        registered=0
        for candidate in "${CLI_TOOLS_LIST[@]}"; do
            if [ "${tool}" = "${candidate}" ]; then
                registered=1
                break
            fi
        done
        if [ "${registered}" -ne 1 ]; then
            printf 'extras: unknown tool identifier "%s"\n' "${tool}" >&2
            return 1
        fi
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
    local download_directory destination snapshot partial actual_checksum
    local copy_result copy_status download_result download_status publish_result
    local recovered_partial recovered_status recovered

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

    url=$(jq -r '.url' <<<"${entry}") || return 1
    checksum=$(jq -r '.sha256' <<<"${entry}") || return 1
    archive_type=$(jq -r '.type' <<<"${entry}") || return 1
    version=$(extras_manifest_version "${tool}") || return 1
    filename=$(basename -- "${url}") || return 1

    if [ -n "${EXTRAS_DOWNLOADED_ASSETS[${tool}]:-}" ]; then
        printf 'extras: tool "%s" was downloaded more than once\n' "${tool}" >&2
        return 1
    fi

    if [ -z "${EXTRAS_CACHE_DIRECTORY:-}" ]; then
        printf 'extras: cache directory is not initialized\n' >&2
        return 1
    fi

    download_directory="${EXTRAS_CACHE_DIRECTORY}/${EXTRAS_ARCHITECTURE}/${tool}"
    destination="${download_directory}/${filename}"
    snapshot="${EXTRAS_WORKSPACE}/artifacts/${tool}/${filename}"
    partial=""

    if ! python3 "${SCRIPT_PATH}/common/runtime-file.py" ensure-directory \
        "${download_directory}"; then
        printf 'extras: unable to create download directory for tool "%s"\n' "${tool}" >&2
        return 1
    fi

    if [ -L "${destination}" ] ||
        { [ -e "${destination}" ] && [ ! -f "${destination}" ]; }; then
        printf 'extras: unsafe cached artifact for tool "%s"\n' "${tool}" >&2
        return 1
    fi

    if [ -f "${destination}" ]; then
        if ! python3 "${SCRIPT_PATH}/common/runtime-file.py" validate-file \
            "${destination}"; then
            printf 'extras: unsafe cached artifact for tool "%s"\n' "${tool}" >&2
            return 1
        fi
        copy_status=0
        copy_result=$(python3 "${SCRIPT_PATH}/common/runtime-file.py" copy \
            "${destination}" "${snapshot}") || copy_status="${?}"
        if [ "${copy_status}" -ne 0 ]; then
            rm -f -- "${snapshot}" || true
            printf 'extras: unable to verify cached artifact for tool "%s"; downloading it again\n' \
                "${tool}" >&2
        else
            actual_checksum="${copy_result}"
            if [ "${actual_checksum}" = "${checksum}" ]; then
                if ! extras_record_downloaded_tool "${tool}" "${archive_type}" \
                    "${snapshot}" "${checksum}" "${filename}"; then
                    return 1
                fi
                extras_evict_obsolete_versions "${tool}" \
                    "${download_directory}" "${filename}"
                info "Using cached artifact for ${tool}." || return 1
                return 0
            fi
            if ! rm -f -- "${snapshot}"; then
                printf 'extras: unable to discard an invalid artifact snapshot for tool "%s"\n' \
                    "${tool}" >&2
                return 1
            fi
            # Keep the existing entry until the replacement has been fully
            # downloaded, verified, and published. A failed update must not
            # discard the last cache artifact.
        fi
    fi

    recovered_partial=""
    recovered_status=0
    recovered=0
    download_result=""
    download_status=0
    recovered_partial=$(python3 "${SCRIPT_PATH}/common/runtime-file.py" \
        find-verified "${download_directory}" "${checksum}") || recovered_status="${?}"
    if [ "${recovered_status}" -eq 0 ] && [ -n "${recovered_partial}" ]; then
        partial="${recovered_partial}"
        recovered=1
        info "Recovering a verified interrupted download for ${tool}." || return 1
    else
        # Only prune stale partials after looking for a checksum-verified
        # recovery candidate. A complete older download remains recoverable.
        extras_prune_stale_partials "${tool}" "${download_directory}"
        info "Downloading ${tool} ${version} (${EXTRAS_ARCHITECTURE})." || return 1
        download_result=$(
            curl \
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
                --output - \
                "${url}" |
                python3 "${SCRIPT_PATH}/common/runtime-file.py" write \
                    "${download_directory}"
        ) || download_status="${?}"
    fi

    if [ "${recovered}" -eq 0 ]; then
        if [[ "${download_result}" == *$'\t'* ]]; then
            actual_checksum="${download_result%%$'\t'*}"
            partial="${download_result#*$'\t'}"
        else
            actual_checksum=""
            partial=""
        fi

        if [ "${download_status}" -ne 0 ]; then
            if [ -n "${partial}" ] && [ "${actual_checksum}" = "${checksum}" ]; then
                printf 'extras: download failed for tool "%s"; the verified download was retained for retry\n' \
                    "${tool}" >&2
            else
                if [ -n "${partial}" ] && ! rm -f -- "${partial}"; then
                    printf 'extras: unable to remove an incomplete download for tool "%s"\n' \
                        "${tool}" >&2
                fi
                printf 'extras: download failed for tool "%s"\n' "${tool}" >&2
            fi
            return 1
        fi
        if [ "${actual_checksum}" != "${checksum}" ]; then
            if [ -n "${partial}" ] && ! rm -f -- "${partial}"; then
                printf 'extras: unable to remove an invalid download for tool "%s"\n' \
                    "${tool}" >&2
            fi
            printf 'extras: checksum verification failed for tool "%s"\n' "${tool}" >&2
            printf 'extras: expected %s, got %s\n' "${checksum}" "${actual_checksum}" >&2
            return 1
        fi
    fi

    if ! copy_result=$(python3 "${SCRIPT_PATH}/common/runtime-file.py" copy \
        "${partial}" "${snapshot}"); then
        printf 'extras: unable to create a verified artifact snapshot for tool "%s"\n' \
            "${tool}" >&2
        return 1
    fi
    actual_checksum="${copy_result}"
    if [ "${actual_checksum}" != "${checksum}" ]; then
        rm -f -- "${snapshot}" "${partial}" || true
        printf 'extras: checksum verification failed for tool "%s"\n' "${tool}" >&2
        printf 'extras: expected %s, got %s\n' "${checksum}" "${actual_checksum}" >&2
        return 1
    fi

    if ! publish_result=$(python3 "${SCRIPT_PATH}/common/runtime-file.py" publish \
        "${partial}" "${destination}" "${checksum}"); then
        # Keep the verified partial file in the cache. A later run can recover
        # it by checksum and retry publication without downloading it again.
        printf 'extras: unable to store downloaded artifact for tool "%s"; the verified download was retained for retry\n' \
            "${tool}" >&2
        return 1
    fi
    actual_checksum="${publish_result}"
    if [ "${actual_checksum}" != "${checksum}" ]; then
        rm -f -- "${partial}" "${snapshot}" || true
        printf 'extras: checksum verification failed for tool "%s"\n' "${tool}" >&2
        printf 'extras: expected %s, got %s\n' "${checksum}" "${actual_checksum}" >&2
        return 1
    fi

    extras_evict_obsolete_versions "${tool}" "${download_directory}" "${filename}"

    if ! extras_record_downloaded_tool "${tool}" "${archive_type}" \
        "${snapshot}" "${checksum}" "${filename}"; then
        return 1
    fi

    info "Verified SHA-256 checksum for ${tool}." || return 1
    return 0
}
