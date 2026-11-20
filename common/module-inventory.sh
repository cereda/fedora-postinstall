#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

function runtime_module_inventory_path {
    local runtime_local_flavor="${1:-}"

    case "${runtime_local_flavor}" in
    workstation)
        printf '%s\n' "${SCRIPT_PATH}/common/workstation-modules.psv"
        ;;
    silverblue)
        printf '%s\n' "${SCRIPT_PATH}/common/silverblue-modules.psv"
        ;;
    *)
        printf 'runtime: unsupported module inventory: %s\n' \
            "${runtime_local_flavor}" >&2
        return 1
        ;;
    esac
}

function runtime_validate_module_inventory {
    local runtime_local_path="${1}"
    local runtime_local_module
    local runtime_local_effect
    local runtime_local_states
    local runtime_local_state
    local -a runtime_local_seen=()
    local -a runtime_local_ignored=()

    if [ ! -f "${runtime_local_path}" ] || [ -L "${runtime_local_path}" ]; then
        printf 'runtime: module inventory is not a regular file: %s\n' \
            "${runtime_local_path}" >&2
        return 1
    fi

    while IFS='|' read -r runtime_local_module runtime_local_effect \
        runtime_local_states; do
        if [ -z "${runtime_local_module}" ]; then
            continue
        fi
        if [[ "${runtime_local_module}" == \#* ]]; then
            continue
        fi
        if [[ "${runtime_local_module}" == /* ]] ||
            [[ "${runtime_local_module}" == *\\* ]] ||
            [[ "${runtime_local_module}" == *..* ]] ||
            [[ "${runtime_local_module}" =~ [[:cntrl:]] ]]; then
            printf 'runtime: invalid module in inventory: %s\n' \
                "${runtime_local_module}" >&2
            return 1
        fi
        if [[ " ${runtime_local_seen[*]} " == *" ${runtime_local_module} "* ]]; then
            printf 'runtime: duplicate module in inventory: %s\n' \
                "${runtime_local_module}" >&2
            return 1
        fi
        runtime_local_seen+=("${runtime_local_module}")
        if [ ! -f "${SCRIPT_PATH}/${runtime_local_module}" ] ||
            [ -L "${SCRIPT_PATH}/${runtime_local_module}" ]; then
            printf 'runtime: inventory module is not a regular file: %s\n' \
                "${runtime_local_module}" >&2
            return 1
        fi
        case "${runtime_local_effect}" in
        mutating | read-only | orchestrator) ;;
        *)
            printf 'runtime: invalid module effect in inventory: %s\n' \
                "${runtime_local_effect}" >&2
            return 1
            ;;
        esac
        if [ -n "${runtime_local_states}" ]; then
            IFS=',' read -r -a runtime_local_ignored <<<"${runtime_local_states}"
            for runtime_local_state in "${runtime_local_ignored[@]}"; do
                if ! [[ "${runtime_local_state}" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
                    printf 'runtime: invalid state variable in inventory: %s\n' \
                        "${runtime_local_state}" >&2
                    return 1
                fi
            done
        fi
    done <"${runtime_local_path}"

    return 0
}

function runtime_module_inventory_rows {
    local runtime_local_flavor="${1:-}"
    local runtime_local_path

    runtime_local_path=$(runtime_module_inventory_path "${runtime_local_flavor}") || return 1
    runtime_validate_module_inventory "${runtime_local_path}" || return 1
    cat -- "${runtime_local_path}"
}

function runtime_module_inventory_modules {
    local runtime_local_flavor="${1:-}"
    local runtime_local_module
    local runtime_local_effect
    local runtime_local_states

    while IFS='|' read -r runtime_local_module runtime_local_effect runtime_local_states; do
        [ -n "${runtime_local_module}" ] && printf '%s\n' "${runtime_local_module}"
    done < <(runtime_module_inventory_rows "${runtime_local_flavor}")
}

function runtime_run_module_inventory {
    local runtime_local_flavor="${1:-}"
    local runtime_local_path
    local runtime_local_module
    local runtime_local_effect
    local runtime_local_states
    local runtime_local_state
    local -a runtime_local_state_names=()

    runtime_local_path=$(runtime_module_inventory_path "${runtime_local_flavor}") || return 1
    runtime_validate_module_inventory "${runtime_local_path}" || return 1

    while IFS='|' read -r runtime_local_module runtime_local_effect \
        runtime_local_states; do
        if [ -z "${runtime_local_module}" ] ||
            [[ "${runtime_local_module}" == \#* ]]; then
            continue
        fi

        runtime_local_state_names=()
        if [ -n "${runtime_local_states}" ]; then
            IFS=',' read -r -a runtime_local_state_names <<<"${runtime_local_states}"
        fi
        runtime_run_module "${runtime_local_module}" "${runtime_local_effect}" \
            "${runtime_local_state_names[@]}"
    done <"${runtime_local_path}"
}

function runtime_module_provider_for_state {
    local runtime_local_flavor="${1:-}"
    local runtime_local_state="${2:-}"

    case "${runtime_local_state}" in
    SUGGESTED_FLATPAKS)
        printf '%s\n' "common/flatpaks-to-install.sh"
        ;;
    NERD_FONTS)
        printf '%s\n' "common/fonts-to-install.sh"
        ;;
    COLOR_THEMES)
        printf '%s\n' "common/color-themes.sh"
        ;;
    EXISTING_PACKAGES)
        printf '%s\n' "workstation/packages-to-remove.sh"
        ;;
    PACKAGES_TO_INSTALL)
        case "${runtime_local_flavor}" in
        workstation)
            printf '%s\n' "workstation/packages-to-install.sh"
            ;;
        silverblue)
            printf '%s\n' "silverblue/packages-to-install.sh"
            ;;
        *)
            return 1
            ;;
        esac
        ;;
    MACHINE_NAME)
        printf '%s\n' "common/hostname-configuration.sh"
        ;;
    ROOT_DIRECTORY_STRUCTURE | COMMAND_NAME)
        case "${runtime_local_flavor}" in
        workstation)
            printf '%s\n' "workstation/home-configuration.sh"
            ;;
        silverblue)
            printf '%s\n' "silverblue/home-configuration.sh"
            ;;
        *)
            return 1
            ;;
        esac
        ;;
    TOOLBOX_NAME)
        printf '%s\n' "silverblue/toolbox-configuration.sh"
        ;;
    *)
        return 1
        ;;
    esac
}

function runtime_module_references_state {
    local runtime_local_path="${1}"
    local runtime_local_state="${2}"
    local runtime_local_direct
    local runtime_local_indexed
    local runtime_local_indirect

    printf -v runtime_local_direct '${%s}' "${runtime_local_state}"
    printf -v runtime_local_indexed '${%s[' "${runtime_local_state}"
    printf -v runtime_local_indirect '${!%s[@]}' "${runtime_local_state}"

    # Match braced scalar references, indexed array references (including
    # nested indexes), indirect array expansion, and ordinary shell
    # references such as "$STATE". Prefix matching for indexed arrays avoids
    # trying to parse arbitrary shell expressions inside the brackets.
    if grep -Fq -- "${runtime_local_direct}" "${runtime_local_path}" ||
        grep -Fq -- "${runtime_local_indexed}" "${runtime_local_path}" ||
        grep -Fq -- "${runtime_local_indirect}" "${runtime_local_path}" ||
        grep -Eq -- '\$'"${runtime_local_state}"'([^A-Za-z0-9_]|$)' \
            "${runtime_local_path}"; then
        return 0
    fi

    return 1
}

function runtime_module_dependency_records {
    local runtime_local_flavor="${1:-}"
    local runtime_local_module="${2:-}"
    local runtime_local_path="${SCRIPT_PATH}/${runtime_local_module}"
    local runtime_local_state
    local runtime_local_provider

    local -a runtime_local_states=(
        SUGGESTED_FLATPAKS
        NERD_FONTS
        COLOR_THEMES
        EXISTING_PACKAGES
        PACKAGES_TO_INSTALL
        MACHINE_NAME
        ROOT_DIRECTORY_STRUCTURE
        COMMAND_NAME
        TOOLBOX_NAME
    )

    for runtime_local_state in "${runtime_local_states[@]}"; do
        if ! runtime_module_references_state \
            "${runtime_local_path}" "${runtime_local_state}"; then
            continue
        fi
        runtime_local_provider=$(runtime_module_provider_for_state \
            "${runtime_local_flavor}" "${runtime_local_state}") || continue
        if [ "${runtime_local_provider}" = "${runtime_local_module}" ]; then
            continue
        fi
        printf '%s\t%s\n' "${runtime_local_provider}" "${runtime_local_state}"
    done
}

function runtime_module_dependencies {
    local runtime_local_provider
    local runtime_local_state

    while IFS=$'\t' read -r runtime_local_provider runtime_local_state; do
        [ -n "${runtime_local_provider}" ] && printf '%s\n' "${runtime_local_provider}"
    done < <(
        runtime_module_dependency_records "${1:-}" "${2:-}"
    )
}

function runtime_module_dependency_closure {
    local runtime_local_flavor="${1:-}"
    local runtime_local_module="${2:-}"
    local runtime_local_current
    local runtime_local_dependency
    local -A runtime_local_seen=()
    local -a runtime_local_worklist=("${runtime_local_module}")
    local -a runtime_local_closure=()

    while [ "${#runtime_local_worklist[@]}" -gt 0 ]; do
        runtime_local_current="${runtime_local_worklist[0]}"
        runtime_local_worklist=("${runtime_local_worklist[@]:1}")
        while IFS= read -r runtime_local_dependency; do
            [ -n "${runtime_local_dependency}" ] || continue
            if [ "${runtime_local_dependency}" = "${runtime_local_module}" ]; then
                continue
            fi
            if [ -n "${runtime_local_seen[${runtime_local_dependency}]:-}" ]; then
                continue
            fi
            runtime_local_seen["${runtime_local_dependency}"]=1
            runtime_local_closure+=("${runtime_local_dependency}")
            runtime_local_worklist+=("${runtime_local_dependency}")
        done < <(
            runtime_module_dependencies "${runtime_local_flavor}" "${runtime_local_current}"
        )
    done

    if [ "${#runtime_local_closure[@]}" -gt 0 ]; then
        printf '%s\n' "${runtime_local_closure[@]}" | LC_ALL=C sort
    fi
}

function runtime_module_pattern_matches {
    local runtime_local_module="${1:-}"
    local runtime_local_pattern="${2:-}"

    [[ "${runtime_local_module}" == ${runtime_local_pattern} ]]
}
