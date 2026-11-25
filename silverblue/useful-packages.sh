#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

PACKAGE_INSTALL_LIST="No packages provided. This is a clean toolbox."

ui_section "Useful packages"

ui_description "Install selected packages inside the toolbox."

if ui_confirm "Choose packages to install in the ${TOOLBOX_NAME} toolbox?" \
    "Select packages" "Skip"; then

    runtime_capture_output PACKAGES_SELECTION \
        ui_choose_many "Select packages to install" "" \
        "${PACKAGES_TO_INSTALL[@]}" || return $?
    readarray -t SELECTED_PACKAGES <<<"${PACKAGES_SELECTION}"

    if [ -z "${SELECTED_PACKAGES}" ]; then

        ui_skip "No packages selected for installation."
    else

        PACKAGE_INSTALL_LIST=$(printf " %s" "${SELECTED_PACKAGES[@]}")
        PACKAGE_INSTALL_LIST="${PACKAGE_INSTALL_LIST:1}"

        runtime_capture_output PACKAGE_INSTALL_ACTION \
            ui_choose_one "What should happen with the selected packages?" \
            "Save for later" "Install now" || return $?

        case "${PACKAGE_INSTALL_ACTION}" in
        "Install now")
            ui_step "Installing the selected packages in the ${TOOLBOX_NAME} toolbox."
            toolbox --container "${TOOLBOX_NAME}" run sudo dnf install \
                "${SELECTED_PACKAGES[@]}"
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

ui_step "Saving the package list for reproducibility."
sed -i "s/TOOLBOX_INSTALLATION_LIST/${PACKAGE_INSTALL_LIST}/" \
    "${ROOT_DIRECTORY_STRUCTURE}/scripts/aliases.sh"

ui_success "Package list saved."
