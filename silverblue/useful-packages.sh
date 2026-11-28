#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Useful packages"

ui_description "Install selected packages inside the toolbox."

SELECTED_PACKAGES=()
TOOLBOX_PACKAGE_LIST_DIRECTORY="${ROOT_DIRECTORY_STRUCTURE}/data/toolbox"
TOOLBOX_PACKAGE_LIST_FILE="${TOOLBOX_PACKAGE_LIST_DIRECTORY}/packages.txt"

function save_toolbox_package_list {
    mkdir -p "${TOOLBOX_PACKAGE_LIST_DIRECTORY}" || return $?
    (
        TOOLBOX_PACKAGE_LIST_TEMPORARY=$(mktemp \
            "${TOOLBOX_PACKAGE_LIST_FILE}.tmp.XXXXXX") || exit 1
        trap 'rm -f -- "${TOOLBOX_PACKAGE_LIST_TEMPORARY}" 2>/dev/null || true' EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM

        if [ "${#SELECTED_PACKAGES[@]}" -gt 0 ]; then
            printf '%s\n' "${SELECTED_PACKAGES[@]}" \
                >"${TOOLBOX_PACKAGE_LIST_TEMPORARY}" || exit $?
        else
            : >"${TOOLBOX_PACKAGE_LIST_TEMPORARY}" || exit $?
        fi
        chmod 0644 "${TOOLBOX_PACKAGE_LIST_TEMPORARY}" || exit $?
        mv -fT -- "${TOOLBOX_PACKAGE_LIST_TEMPORARY}" \
            "${TOOLBOX_PACKAGE_LIST_FILE}" || exit $?
        trap - EXIT HUP INT TERM
        exit 0
    )
}

if ui_confirm "Choose packages to install in the ${TOOLBOX_NAME} toolbox?" \
    "Select packages" "Skip"; then

    runtime_capture_output PACKAGES_SELECTION \
        ui_choose_many "Select packages to install" "" \
        "${PACKAGES_TO_INSTALL[@]}" || return $?
    if [ -n "${PACKAGES_SELECTION}" ]; then
        mapfile -t SELECTED_PACKAGES <<<"${PACKAGES_SELECTION}"
    fi

    if [ "${#SELECTED_PACKAGES[@]}" -eq 0 ] ||
        [ -z "${SELECTED_PACKAGES[0]:-}" ]; then
        ui_skip "No packages selected for installation."
    else
        ui_text "Selected packages: ${SELECTED_PACKAGES[*]}"
        ui_step "Saving the package list for reproducibility."
        save_toolbox_package_list || return $?
        ui_success "Package list saved to ${TOOLBOX_PACKAGE_LIST_FILE}."

        runtime_capture_output PACKAGE_INSTALL_ACTION \
            ui_choose_one "What should happen with the selected packages?" \
            "Save for later" "Install now" || return $?

        case "${PACKAGE_INSTALL_ACTION}" in
        "Install now")
            ui_step "Installing the selected packages in the ${TOOLBOX_NAME} toolbox."
            toolbox --container "${TOOLBOX_NAME}" run sudo dnf install \
                "${SELECTED_PACKAGES[@]}" || return $?
            ui_success "Selected packages installed."
            ;;
        "Save for later")
            ui_skip "Package installation was deferred."
            ;;
        *)
            ui_error "No deferred package installation action was selected."
            return 1
            ;;
        esac
    fi
else
    ui_skip "No packages were selected."
fi

if [ ! -f "${TOOLBOX_PACKAGE_LIST_FILE}" ]; then
    ui_step "Saving the package list for reproducibility."
    save_toolbox_package_list || return $?
    ui_success "Package list saved to ${TOOLBOX_PACKAGE_LIST_FILE}."
fi
return 0
