#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

# Gum is the interaction backend. An installed Gum v2 binary is reused;
# otherwise the installer fetches the checksum-verified release declared in
# the authoritative tool manifest.

GUM_SETUP_EXPLICIT=0
GUM_SETUP_REQUESTED_BINARY=""
if [ "${GUM+x}" = "x" ]; then
    GUM_SETUP_EXPLICIT=1
    GUM_SETUP_REQUESTED_BINARY="${GUM:-}"
fi
declare -g GUM="${GUM:-}"
declare -g GUM_BOOTSTRAP_DIRECTORY=""

if ! declare -F ui_step >/dev/null; then
    GUM_SETUP_UI_DIRECTORY="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" &&
        pwd -P)" || return 1
    source "${GUM_SETUP_UI_DIRECTORY}/ui.sh" || return 1
fi

function cleanup_gum_bootstrap {
    if [ -n "${GUM_BOOTSTRAP_DIRECTORY:-}" ] &&
        [ -d "${GUM_BOOTSTRAP_DIRECTORY}" ]; then
        rm -rf -- "${GUM_BOOTSTRAP_DIRECTORY}"
    fi
}

function gum_setup_binary_has_features {
    local gum_setup_local_binary="${1:-}"
    local gum_setup_local_help=""

    gum_setup_local_help="$("${gum_setup_local_binary}" choose --help 2>/dev/null)" ||
        return 1
    printf '%s\n' "${gum_setup_local_help}" |
        grep -Eq '(^|[[:space:]])--no-limit([=[:space:]]|$)' || return 1
    printf '%s\n' "${gum_setup_local_help}" |
        grep -Eq '(^|[[:space:]])--header([=[:space:]]|$)' || return 1
    printf '%s\n' "${gum_setup_local_help}" |
        grep -Eq '(^|[[:space:]])--height([=[:space:]]|$)' || return 1
    printf '%s\n' "${gum_setup_local_help}" |
        grep -Eq '(^|[[:space:]])--selected([=[:space:]]|$)' || return 1

    gum_setup_local_help="$("${gum_setup_local_binary}" confirm --help 2>/dev/null)" ||
        return 1
    printf '%s\n' "${gum_setup_local_help}" |
        grep -Eq '(^|[[:space:]])--show-output([=[:space:]]|$)' || return 1
    printf '%s\n' "${gum_setup_local_help}" |
        grep -Eq '(^|[[:space:]])--affirmative([=[:space:]]|$)' || return 1
    printf '%s\n' "${gum_setup_local_help}" |
        grep -Eq '(^|[[:space:]])--negative([=[:space:]]|$)' || return 1
    printf '%s\n' "${gum_setup_local_help}" |
        grep -Eq '(^|[[:space:]])--prompt\.foreground([=[:space:]]|$)' || return 1
    printf '%s\n' "${gum_setup_local_help}" |
        grep -Eq '(^|[[:space:]])--selected\.background([=[:space:]]|$)' || return 1

    gum_setup_local_help="$("${gum_setup_local_binary}" input --help 2>/dev/null)" ||
        return 1
    printf '%s\n' "${gum_setup_local_help}" |
        grep -Eq '(^|[[:space:]])--value([=[:space:]]|$)' || return 1
    printf '%s\n' "${gum_setup_local_help}" |
        grep -Eq '(^|[[:space:]])--prompt([=[:space:]]|$)' || return 1

    gum_setup_local_help="$("${gum_setup_local_binary}" file --help 2>/dev/null)" ||
        return 1
    printf '%s\n' "${gum_setup_local_help}" |
        grep -Eq '(^|[[:space:]])--file([=[:space:]]|$)' || return 1
    printf '%s\n' "${gum_setup_local_help}" |
        grep -Eq '(^|[[:space:]])--directory([=[:space:]]|$)' || return 1
    printf '%s\n' "${gum_setup_local_help}" |
        grep -Eq '(^|[[:space:]])--all([=[:space:]]|$)' || return 1
    printf '%s\n' "${gum_setup_local_help}" |
        grep -Eq '(^|[[:space:]])--(\[no-\])?permissions([=[:space:]]|$)' || return 1

    return 0
}

function gum_setup_binary_is_supported {
    local gum_setup_local_binary="${1:-}"
    local gum_setup_local_version=""

    [ -n "${gum_setup_local_binary}" ] || return 1
    [ -f "${gum_setup_local_binary}" ] || return 1
    [ -x "${gum_setup_local_binary}" ] || return 1
    [ ! -d "${gum_setup_local_binary}" ] || return 1

    gum_setup_local_version="$("${gum_setup_local_binary}" --version 2>/dev/null)" ||
        return 1
    [[ " ${gum_setup_local_version} " =~ (^|[[:space:]])v2\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)([[:space:]]|$) ]]
}

function gum_setup_find_v2_binary {
    local gum_setup_local_candidate=""
    local gum_setup_local_resolved=""

    if [ "${GUM_SETUP_EXPLICIT}" -eq 1 ]; then
        gum_setup_local_candidate="${GUM_SETUP_REQUESTED_BINARY}"
    else
        gum_setup_local_candidate="gum"
    fi

    if [ -z "${gum_setup_local_candidate}" ]; then
        return 1
    fi

    if [[ "${gum_setup_local_candidate}" == */* ]]; then
        gum_setup_local_resolved="${gum_setup_local_candidate}"
    else
        gum_setup_local_resolved="$(command -v "${gum_setup_local_candidate}" || true)"
    fi

    if gum_setup_binary_is_supported "${gum_setup_local_resolved}" &&
        gum_setup_binary_has_features "${gum_setup_local_resolved}"; then
        GUM="${gum_setup_local_resolved}"
        return 0
    fi

    return 1
}

function gum_setup_read_manifest {
    local gum_setup_local_root="${SCRIPT_PATH:-}"
    local gum_setup_local_manifest=""
    local gum_setup_local_entry=""
    local gum_setup_local_file_count=""

    if [ -z "${gum_setup_local_root}" ]; then
        gum_setup_local_root="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &&
            pwd -P)" || return 1
    fi
    gum_setup_local_manifest="${gum_setup_local_root}/extras/tools-manifest.json"
    if [ ! -f "${gum_setup_local_manifest}" ] ||
        [ -L "${gum_setup_local_manifest}" ]; then
        ui_error "Unable to load the authoritative gum manifest."
        return 1
    fi

    if ! gum_setup_local_entry=$(jq -ce --arg architecture "${GUM_ARCHITECTURE:-}" \
        '.tools.gum.assets[$architecture] // .tools.gum.assets.any // empty' \
        "${gum_setup_local_manifest}"); then
        ui_error "Gum is not available for architecture ${GUM_ARCHITECTURE:-$(uname -m)}."
        return 1
    fi

    GUM_VERSION=$(jq -r '.tools.gum.version // empty' \
        "${gum_setup_local_manifest}")
    GUM_LINK=$(jq -r '.url // empty' <<<"${gum_setup_local_entry}")
    GUM_CHECKSUM=$(jq -r '.sha256 // empty' <<<"${gum_setup_local_entry}")
    GUM_ARCHIVE_TYPE=$(jq -r '.type // empty' <<<"${gum_setup_local_entry}")
    GUM_FILE_COUNT=$(jq -r '.files | length' <<<"${gum_setup_local_entry}")
    GUM_MEMBER=$(jq -r \
        '.files | to_entries | map(select(.value == "gum")) | if length == 1 then .[0].key else empty end' \
        <<<"${gum_setup_local_entry}")

    if [ -z "${GUM_VERSION}" ] ||
        [[ ! "${GUM_VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        [[ ! "${GUM_LINK}" =~ ^https:// ]] ||
        ! [[ "${GUM_CHECKSUM}" =~ ^[0-9a-f]{64}$ ]] ||
        [[ ! "${GUM_ARCHIVE_TYPE}" =~ ^(tar\.gz|zip)$ ]] ||
        [ "${GUM_FILE_COUNT}" != "1" ] ||
        [ -z "${GUM_MEMBER}" ]; then
        ui_error "The authoritative Gum manifest entry is invalid."
        return 1
    fi

    if [[ "${GUM_MEMBER}" == /* ]] ||
        [[ "${GUM_MEMBER}" == *\\* ]] ||
        [[ "${GUM_MEMBER}" == *..* ]]; then
        ui_error "The authoritative Gum manifest contains an unsafe member."
        return 1
    fi

    GUM_ARCHIVE=$(basename -- "${GUM_LINK}")
    if [ -z "${GUM_ARCHIVE}" ] || [ "${GUM_ARCHIVE}" = "." ] ||
        [ "${GUM_ARCHIVE}" = ".." ]; then
        ui_error "The authoritative Gum manifest contains an invalid archive name."
        return 1
    fi

    return 0
}

function gum_setup_binary_matches_version {
    local gum_setup_local_binary="${1:-}"
    local gum_setup_local_expected_version="${2:-}"
    local gum_setup_local_version=""

    [ -x "${gum_setup_local_binary}" ] || return 1
    [ -n "${gum_setup_local_expected_version}" ] || return 1
    gum_setup_local_version="$("${gum_setup_local_binary}" --version 2>/dev/null)" ||
        return 1
    case " ${gum_setup_local_version} " in
    *" ${gum_setup_local_expected_version} "*) return 0 ;;
    esac
    return 1
}

function gum_setup_fetch_binary {
    local gum_setup_local_actual_checksum=""
    local gum_setup_local_archive_path=""
    local gum_setup_local_archive_size=""
    local gum_setup_local_extracted_path=""
    local gum_setup_local_gum_path=""
    local gum_setup_local_staged_path=""
    local gum_setup_local_status=0
    local gum_setup_local_max_archive_bytes=67108864

    if ! command -v curl >/dev/null 2>&1 ||
        ! command -v sha256sum >/dev/null 2>&1; then
        ui_error "Gum is required, but curl and sha256sum are unavailable."
        return 1
    fi

    GUM_ARCHITECTURE=$(runtime_selected_architecture) || {
        gum_setup_local_status="${?}"
        ui_error "Gum does not publish a release for architecture ${POSTINSTALL_ARCHITECTURE:-$(uname -m)}."
        return "${gum_setup_local_status}"
    }

    gum_setup_read_manifest || {
        gum_setup_local_status="${?}"
        return "${gum_setup_local_status}"
    }

    GUM_BOOTSTRAP_DIRECTORY=$(mktemp -d \
        "${TMPDIR:-/tmp}/fedora-postinstall-gum.XXXXXXXX") || {
        gum_setup_local_status="${?}"
        ui_error "Unable to create a temporary directory for Gum."
        return "${gum_setup_local_status}"
    }
    runtime_register_cleanup "gum-bootstrap" cleanup_gum_bootstrap || {
        gum_setup_local_status="${?}"
        rm -rf -- "${GUM_BOOTSTRAP_DIRECTORY}"
        GUM_BOOTSTRAP_DIRECTORY=""
        ui_error "Unable to register the Gum bootstrap cleanup."
        return "${gum_setup_local_status}"
    }

    ui_step "Fetching Gum ${GUM_VERSION} for interactive prompts."
    gum_setup_local_archive_path="${GUM_BOOTSTRAP_DIRECTORY}/${GUM_ARCHIVE}"
    curl \
        --fail \
        --location \
        --silent \
        --show-error \
        --retry 3 \
        --retry-delay 2 \
        --connect-timeout 20 \
        --max-time 300 \
        --max-filesize "${gum_setup_local_max_archive_bytes}" \
        --proto '=https' \
        --tlsv1.2 \
        --output "${gum_setup_local_archive_path}" \
        "${GUM_LINK}" || {
        gum_setup_local_status="${?}"
        ui_error "Unable to download Gum ${GUM_VERSION}."
        return "${gum_setup_local_status}"
    }

    if [ ! -f "${gum_setup_local_archive_path}" ] ||
        [ -L "${gum_setup_local_archive_path}" ]; then
        ui_error "The downloaded Gum archive is not a regular file."
        return 1
    fi

    gum_setup_local_archive_size="$(wc -c <"${gum_setup_local_archive_path}")" || {
        gum_setup_local_status="${?}"
        ui_error "Unable to determine the size of the Gum archive."
        return "${gum_setup_local_status}"
    }
    if [ "${gum_setup_local_archive_size}" -gt \
        "${gum_setup_local_max_archive_bytes}" ]; then
        ui_error "The downloaded Gum archive exceeds the allowed size."
        return 1
    fi

    gum_setup_local_actual_checksum="$(sha256sum -- \
        "${gum_setup_local_archive_path}")" || {
        gum_setup_local_status="${?}"
        ui_error "Unable to verify the Gum archive checksum."
        return "${gum_setup_local_status}"
    }
    gum_setup_local_actual_checksum="${gum_setup_local_actual_checksum%% *}"
    if [ "${gum_setup_local_actual_checksum}" != "${GUM_CHECKSUM}" ]; then
        ui_error "Checksum verification failed for Gum ${GUM_VERSION}."
        return 1
    fi

    gum_setup_local_extracted_path="${GUM_BOOTSTRAP_DIRECTORY}/extracted"
    python3 "${SCRIPT_PATH}/extras/archive-extract.py" \
        --archive "${gum_setup_local_archive_path}" \
        --type "${GUM_ARCHIVE_TYPE}" \
        --destination "${gum_setup_local_extracted_path}" \
        --members "${GUM_MEMBER}" || {
        gum_setup_local_status="${?}"
        ui_error "Unable to extract Gum ${GUM_VERSION}."
        return "${gum_setup_local_status}"
    }

    gum_setup_local_gum_path="${gum_setup_local_extracted_path}/${GUM_MEMBER}"
    if [ ! -f "${gum_setup_local_gum_path}" ] ||
        [ -L "${gum_setup_local_gum_path}" ]; then
        ui_error "Unable to locate the Gum executable in the downloaded archive."
        return 1
    fi

    # Stage the executable separately from the archive. The staged file is
    # the only path exposed to the interaction adapter and is removed with
    # the bootstrap workspace at exit.
    gum_setup_local_staged_path="${GUM_BOOTSTRAP_DIRECTORY}/gum"
    install -m 0755 "${gum_setup_local_gum_path}" \
        "${gum_setup_local_staged_path}" || {
        gum_setup_local_status="${?}"
        ui_error "Unable to prepare the Gum executable."
        return "${gum_setup_local_status}"
    }
    if [ ! -x "${gum_setup_local_staged_path}" ]; then
        ui_error "The staged Gum executable is not runnable."
        return 1
    fi
    if ! gum_setup_binary_matches_version \
        "${gum_setup_local_staged_path}" "${GUM_VERSION}"; then
        ui_error "The staged Gum executable has an unexpected version."
        return 1
    fi
    if ! gum_setup_binary_has_features "${gum_setup_local_staged_path}"; then
        ui_error "The staged Gum executable does not provide the required controls."
        return 1
    fi

    GUM="${gum_setup_local_staged_path}"
    return 0
}

if gum_setup_find_v2_binary; then
    :
elif [ "${GUM_SETUP_EXPLICIT}" -eq 1 ]; then
    if [ -n "${GUM_SETUP_REQUESTED_BINARY}" ]; then
        ui_error "The configured Gum executable is unavailable or unsupported: ${GUM_SETUP_REQUESTED_BINARY}"
    else
        ui_error "The configured Gum executable path is empty."
    fi
    exit 1
else
    gum_setup_fetch_binary || exit $?
fi
