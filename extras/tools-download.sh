#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

declare -gA EXTRAS_DOWNLOADED_ASSETS=()
declare -gA EXTRAS_DOWNLOADED_TYPES=()
declare -gA EXTRAS_DOWNLOADED_FILENAMES=()
declare -g EXTRAS_INVALID_SELECTION_STATUS=69

# The manifest helpers are also used by the non-interactive plan command,
# which intentionally does not load the installer UI layer. Keep a plain
# diagnostic fallback for that path while using semantic UI messages during
# an interactive installation.
function extras_report_error {
    local extras_report_local_message="${1:-}"
    local extras_report_local_plain_message="${2:-${extras_report_local_message}}"

    if declare -F ui_error >/dev/null; then
        ui_error "${extras_report_local_message}"
        return $?
    fi
    printf 'extras: %s\n' "${extras_report_local_plain_message}" >&2
}

function extras_report_warning {
    local extras_report_local_message="${1:-}"
    local extras_report_local_plain_message="${2:-${extras_report_local_message}}"

    if declare -F ui_warning >/dev/null; then
        ui_warning "${extras_report_local_message}"
        return $?
    fi
    printf 'extras: %s\n' "${extras_report_local_plain_message}" >&2
}

function extras_report_step {
    local extras_report_local_message="${1:-}"

    if declare -F ui_step >/dev/null; then
        ui_step "${extras_report_local_message}"
        return $?
    fi
    printf '%s\n' "${extras_report_local_message}"
}

function extras_detect_architecture {
    if declare -F runtime_selected_architecture >/dev/null; then
        runtime_selected_architecture
        return $?
    fi

    local machine
    machine=$(uname -m) || return 1
    case "${machine}" in
    x86_64) printf '%s\n' "x86_64" ;;
    aarch64) printf '%s\n' "aarch64" ;;
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
        extras_report_error \
            "Unsupported canonical architecture key: ${architecture}." \
            "unsupported canonical architecture key: ${architecture}"
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
    extras_report_step "${label}: ${tool_description}" || return $?
    return 0
}

function extras_prune_stale_partials {
    local tool="${1}"
    local directory="${2}"

    if ! python3 "${SCRIPT_PATH}/common/runtime-file.py" prune-partials \
        "${directory}"; then
        extras_report_warning \
            "Could not prune stale partial artifacts for ${tool}; the download will continue." \
            "unable to prune stale partial artifacts for tool \"${tool}\""
    fi
    return 0
}

function extras_evict_superseded_versions {
    local tool="${1}"
    local directory="${2}"
    local keep_name="${3}"

    if ! python3 "${SCRIPT_PATH}/common/runtime-file.py" prune-versions \
        "${directory}" "${keep_name}"; then
        extras_report_warning \
            "Could not evict superseded cached versions for ${tool}; the current version remains available." \
            "unable to evict superseded cached versions for tool \"${tool}\""
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
        extras_report_error \
            "Could not update the artifact ledger for ${tool}. Deployment will stop before any command is replaced." \
            "unable to update the artifact ledger for tool \"${tool}\""
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
        extras_report_error \
            "Unsupported canonical architecture key: ${extras_local_architecture}." \
            "unsupported canonical architecture key: ${extras_local_architecture}"
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
        extras_report_error \
            "The command-line tool manifest is not a regular file: ${EXTRAS_MANIFEST_FILE}." \
            "manifest is not a regular file: ${EXTRAS_MANIFEST_FILE}"
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
        extras_report_error \
            "Invalid command-line tool manifest: ${EXTRAS_MANIFEST_FILE}." \
            "invalid command line tool manifest: ${EXTRAS_MANIFEST_FILE}"
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
        extras_report_error \
            "Invalid command-line tool identifier: ${tool}." \
            "invalid tool identifier: ${tool}"
        return 1
    fi

    if ! entry=$(extras_manifest_entry "${tool}" "${architecture}"); then
        extras_report_error \
            "Command-line tool ${tool} is not available for architecture ${architecture}." \
            "tool \"${tool}\" is not available for architecture ${architecture}"
        return 1
    fi

    url=$(jq -r '.url // empty' <<<"${entry}")
    checksum=$(jq -r '.sha256 // empty' <<<"${entry}")
    archive_type=$(jq -r '.type // empty' <<<"${entry}")
    version=$(extras_manifest_version "${tool}")

    if ! [[ "${url}" =~ ${url_regex} ]]; then
        extras_report_error \
            "Invalid download URL for command-line tool ${tool}." \
            "invalid download URL for tool \"${tool}\""
        return 1
    fi

    case "/${url}/" in
    */latest/* | */master/* | */main/* | */HEAD/*)
        extras_report_error \
            "The download URL for command-line tool ${tool} is not pinned." \
            "download URL for tool \"${tool}\" is not pinned"
        return 1
        ;;
    esac

    if ! [[ "${checksum}" =~ ^[0-9a-f]{64}$ ]]; then
        extras_report_error \
            "Invalid SHA-256 checksum for command-line tool ${tool}." \
            "invalid SHA-256 checksum for tool \"${tool}\""
        return 1
    fi

    if ! [[ "${archive_type}" =~ ^(tar\.gz|zip|none)$ ]]; then
        extras_report_error \
            "Invalid archive type for command-line tool ${tool}." \
            "invalid archive type for tool \"${tool}\""
        return 1
    fi

    if [ -z "${version}" ] || [ "${version}" = "latest" ]; then
        extras_report_error \
            "Invalid version for command-line tool ${tool}." \
            "invalid version for tool \"${tool}\""
        return 1
    fi

    if [[ "${url}" != *"${version}"* ]]; then
        extras_report_error \
            "The download URL for command-line tool ${tool} does not match its pinned version." \
            "download URL for tool \"${tool}\" does not match its pinned version"
        return 1
    fi

    if ! jq -e '.files | type == "object" and length > 0' <<<"${entry}" >/dev/null; then
        extras_report_error \
            "No command is declared for command-line tool ${tool}." \
            "no executable declared for tool \"${tool}\""
        return 1
    fi

    while IFS=$'\t' read -r source target; do
        if ! [[ "${target}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
            extras_report_error \
                "Invalid command target for command-line tool ${tool}." \
                "invalid executable target for tool \"${tool}\""
            return 1
        fi

        if [ "${archive_type}" = "none" ]; then
            if ! [[ "${source}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
                extras_report_error \
                    "Invalid standalone command for command-line tool ${tool}." \
                    "invalid standalone executable for tool \"${tool}\""
                return 1
            fi
        else
            if ! extras_archive_path_is_safe "${source}"; then
                extras_report_error \
                    "Unsafe command member for command-line tool ${tool}." \
                    "unsafe executable member for tool \"${tool}\""
                return 1
            fi
            normalized_source="${source#./}"
            IFS='/' read -r -a path_components <<<"${normalized_source}"
            for component in "${path_components[@]}"; do
                if [ -z "${component}" ] || [ "${component}" = "." ] || [ "${component}" = ".." ]; then
                    extras_report_error \
                        "Unsafe command member for command-line tool ${tool}." \
                        "unsafe executable member for tool \"${tool}\""
                    return 1
                fi
            done
        fi
    done < <(jq -r '.files | to_entries[] | [.key, .value] | @tsv' <<<"${entry}")

    if [ "$(jq '.files | to_entries | map(.value) | unique | length' <<<"${entry}")" -ne \
        "$(jq '.files | length' <<<"${entry}")" ]; then
        extras_report_error \
            "Duplicate command target for command-line tool ${tool}." \
            "duplicate executable target for tool \"${tool}\""
        return 1
    fi

    filename=$(basename -- "${url}")
    if [ -z "${filename}" ] || [ "${filename}" = "." ] || [ "${filename}" = ".." ]; then
        extras_report_error \
            "Invalid artifact filename for command-line tool ${tool}." \
            "invalid artifact filename for tool \"${tool}\""
        return 1
    fi

    if [ "${archive_type}" = "none" ]; then
        if [ "$(jq '.files | length' <<<"${entry}")" -ne 1 ]; then
            extras_report_error \
                "Standalone command-line tool ${tool} must declare exactly one command." \
                "standalone tool \"${tool}\" must declare exactly one executable"
            return 1
        fi
        if [ "${filename}" != "$(jq -r '.files | keys[0]' <<<"${entry}")" ]; then
            extras_report_error \
                "The standalone artifact does not match command-line tool ${tool}." \
                "standalone artifact does not match tool \"${tool}\""
            return 1
        fi
    fi

    return 0
}

function extras_validate_selected_tools {
    local tool target existing_target entry registered candidate targets
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
            extras_report_error \
                "Unknown command-line tool identifier: ${tool}." \
                "unknown tool identifier \"${tool}\""
            return "${EXTRAS_INVALID_SELECTION_STATUS}"
        fi
        if ! extras_validate_manifest_entry "${tool}" "${EXTRAS_ARCHITECTURE}"; then
            return 1
        fi

        entry=$(extras_manifest_entry "${tool}" "${EXTRAS_ARCHITECTURE}") ||
            return 1
        targets=$(jq -r '.files | to_entries[].value' <<<"${entry}") ||
            return 1
        while IFS= read -r target; do
            [ -n "${target}" ] || continue
            existing_target="${selected_targets[${target}]:-}"
            if [ -n "${existing_target}" ]; then
                extras_report_error \
                    "Command-line tools ${existing_target} and ${tool} deploy the same command ${target}." \
                    "tools \"${existing_target}\" and \"${tool}\" deploy the same command \"${target}\""
                return "${EXTRAS_INVALID_SELECTION_STATUS}"
            fi
            selected_targets["${target}"]="${tool}"
        done <<<"${targets}"
    done
}

function download_extras_tool {
    local tool="${1}"
    local entry url checksum archive_type version filename
    local download_directory destination snapshot partial actual_checksum
    local copy_result copy_status download_result download_status publish_result
    local recovered_partial recovered_status recovered

    if [ -z "${EXTRAS_WORKSPACE:-}" ] || [ ! -d "${EXTRAS_WORKSPACE}" ]; then
        extras_report_error \
            "The command-line tool download workspace is not initialized." \
            "download workspace is not initialized"
        return 1
    fi

    if ! entry=$(extras_manifest_entry "${tool}" "${EXTRAS_ARCHITECTURE}"); then
        extras_report_error \
            "No command-line tool manifest entry was found for ${tool}." \
            "no manifest entry for tool \"${tool}\""
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
        extras_report_error \
            "Command-line tool ${tool} was downloaded more than once." \
            "tool \"${tool}\" was downloaded more than once"
        return 1
    fi

    if [ -z "${EXTRAS_CACHE_DIRECTORY:-}" ]; then
        extras_report_error \
            "The command-line tool cache directory is not initialized." \
            "cache directory is not initialized"
        return 1
    fi

    download_directory="${EXTRAS_CACHE_DIRECTORY}/${EXTRAS_ARCHITECTURE}/${tool}"
    destination="${download_directory}/${filename}"
    snapshot="${EXTRAS_WORKSPACE}/artifacts/${tool}/${filename}"
    partial=""

    if ! python3 "${SCRIPT_PATH}/common/runtime-file.py" ensure-directory \
        "${download_directory}"; then
        extras_report_error \
            "Could not create the download directory for ${tool}. No command-line tools were deployed." \
            "unable to create download directory for tool \"${tool}\""
        return 1
    fi

    if [ -L "${destination}" ] ||
        { [ -e "${destination}" ] && [ ! -f "${destination}" ]; }; then
        extras_report_error \
            "Unsafe cached artifact for command-line tool \"${tool}\"; it was not used." \
            "unsafe cached artifact for tool \"${tool}\""
        return 1
    fi

    if [ -f "${destination}" ]; then
        if ! python3 "${SCRIPT_PATH}/common/runtime-file.py" validate-file \
            "${destination}"; then
            extras_report_error \
                "Unsafe cached artifact for command-line tool \"${tool}\"; it was not used." \
                "unsafe cached artifact for tool \"${tool}\""
            return 1
        fi
        copy_status=0
        copy_result=$(python3 "${SCRIPT_PATH}/common/runtime-file.py" copy \
            "${destination}" "${snapshot}") || copy_status="${?}"
        if [ "${copy_status}" -ne 0 ]; then
            rm -f -- "${snapshot}" || true
            extras_report_warning \
                "Could not verify the cached artifact for ${tool}; downloading it again." \
                "unable to verify cached artifact for tool \"${tool}\"; downloading it again"
        else
            actual_checksum="${copy_result}"
            if [ "${actual_checksum}" = "${checksum}" ]; then
                if ! extras_record_downloaded_tool "${tool}" "${archive_type}" \
                    "${snapshot}" "${checksum}" "${filename}"; then
                    return 1
                fi
                extras_evict_superseded_versions "${tool}" \
                    "${download_directory}" "${filename}"
                extras_report_step "Using cached artifact for ${tool}; the SHA-256 checksum is verified." || return $?
                return 0
            fi
            if ! rm -f -- "${snapshot}"; then
                extras_report_error \
                    "Could not discard the invalid artifact snapshot for ${tool}. Deployment will stop before any command is replaced." \
                    "unable to discard an invalid artifact snapshot for tool \"${tool}\""
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
        extras_report_step "Recovering a verified interrupted download for ${tool}." || return $?
    else
        # Only prune stale partials after looking for a checksum-verified
        # recovery candidate. A complete older download remains recoverable.
        extras_prune_stale_partials "${tool}" "${download_directory}"
        extras_report_step "Downloading ${tool} ${version} (${EXTRAS_ARCHITECTURE})." || return $?
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
                extras_report_error \
                    "Download failed for command-line tool \"${tool}\"; the verified download was retained for retry." \
                    "download failed for tool \"${tool}\"; the verified download was retained for retry"
            else
                if [ -n "${partial}" ] && ! rm -f -- "${partial}"; then
                    extras_report_warning \
                        "Could not remove the incomplete download for ${tool}; it remains in the cache for inspection." \
                        "unable to remove an incomplete download for tool \"${tool}\""
                fi
                extras_report_error \
                    "Download failed for command-line tool \"${tool}\". Run the command again to retry." \
                    "download failed for tool \"${tool}\""
            fi
            return 1
        fi
        if [ "${actual_checksum}" != "${checksum}" ]; then
            if [ -n "${partial}" ] && ! rm -f -- "${partial}"; then
                extras_report_warning \
                    "Could not remove the invalid download for ${tool}; it remains in the cache for inspection." \
                    "unable to remove an invalid download for tool \"${tool}\""
            fi
            extras_report_error \
                "Checksum verification failed for command-line tool \"${tool}\". Expected ${checksum}, received ${actual_checksum}. The invalid artifact was not used; run the command again to retry." \
                "checksum verification failed for tool \"${tool}\"\nextras: expected ${checksum}, got ${actual_checksum}"
            return 1
        fi
    fi

    if ! copy_result=$(python3 "${SCRIPT_PATH}/common/runtime-file.py" copy \
        "${partial}" "${snapshot}"); then
        extras_report_error \
            "Could not create a verified artifact snapshot for ${tool}. Deployment will stop before any command is replaced." \
            "unable to create a verified artifact snapshot for tool \"${tool}\""
        return 1
    fi
    actual_checksum="${copy_result}"
    if [ "${actual_checksum}" != "${checksum}" ]; then
        rm -f -- "${snapshot}" "${partial}" || true
        extras_report_error \
            "Checksum verification failed for command-line tool \"${tool}\". Expected ${checksum}, received ${actual_checksum}. The invalid artifact was not used; run the command again to retry." \
            "checksum verification failed for tool \"${tool}\"\nextras: expected ${checksum}, got ${actual_checksum}"
        return 1
    fi

    if ! publish_result=$(python3 "${SCRIPT_PATH}/common/runtime-file.py" publish \
        "${partial}" "${destination}" "${checksum}"); then
        # Keep the verified partial file in the cache. A later run can recover
        # it by checksum and retry publication without downloading it again.
        extras_report_error \
            "Could not confirm publication of the downloaded artifact for ${tool}; the verified download was retained for retry." \
            "unable to store downloaded artifact for tool \"${tool}\"; the verified download was retained for retry"
        return 1
    fi
    actual_checksum="${publish_result}"
    if [ "${actual_checksum}" != "${checksum}" ]; then
        rm -f -- "${partial}" "${snapshot}" || true
        extras_report_error \
            "Checksum verification failed for command-line tool \"${tool}\". Expected ${checksum}, received ${actual_checksum}. The invalid artifact was not used; run the command again to retry." \
            "checksum verification failed for tool \"${tool}\"\nextras: expected ${checksum}, got ${actual_checksum}"
        return 1
    fi

    extras_evict_superseded_versions "${tool}" "${download_directory}" "${filename}"

    if ! extras_record_downloaded_tool "${tool}" "${archive_type}" \
        "${snapshot}" "${checksum}" "${filename}"; then
        return 1
    fi

    extras_report_step "Verified SHA-256 checksum for ${tool}." || return $?
    return 0
}
