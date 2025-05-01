#!/usr/bin/env bash

section "Useful packages"

description "This section will help you install a collection of useful \
packages. This includes tools like ack (a fast alternative to grep), \
hyperfine (a command-line benchmarking tool), delta (a syntax \
highlighting diff viewer), as well as the Java Development Kit (JDK) and \
various archiving utilities such as unrar and p7zip. These packages can \
provide additional functionality for your command line workflow. These \
packages will be installed inside a toolbox."

echo

question "Do you want to install some useful packages?"

if [ $? = 0 ]; then

    text "Select which packages you want to install."
    readarray -t SELECTED_PACKAGES <<< $(${GUM} choose --no-limit --height 15 "${PACKAGES_TO_INSTALL[@]}")

    if [ -z "${SELECTED_PACKAGES}" ]; then
        text "You haven't selected any items from the list. Moving on."
    else

        PACKAGE_INSTALL_LIST=$(printf " %s" "${SELECTED_PACKAGES[@]}")
        
        info "Installing packages inside the ${TOOLBOX_NAME} toolbox."
        toolbox --container ${TOOLBOX_NAME} run sudo dnf install ${PACKAGE_INSTALL_LIST:1}

        info "Adding package list to helper function (for reproducibility)."
        sed -i "s/TOOLBOX_INSTALLATION_LIST/${PACKAGE_INSTALL_LIST:1}/" "${ROOT_DIRECTORY_STRUCTURE}/scripts/aliases.sh"
    fi
fi
