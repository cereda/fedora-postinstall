#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Useful packages"

description "This section will help you install a collection of useful \
packages. This includes tools like ack (a fast alternative to grep), \
hyperfine (a command line benchmarking tool), delta (a syntax \
highlighting diff viewer), as well as the Java Development Kit (JDK) and \
various archiving utilities such as unrar and p7zip. These packages can \
provide additional functionality for your command line workflow."

echo

question "Do you want to install some useful packages?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    text "Select which packages you want to install."

    echo

    # display a list of packages from the PACKAGES_TO_INSTALL environment variable
    # set previously (see [workstation/packages-to-install.sh] for reference) and
    # collect the selected entries into a new array
    runtime_capture_output PACKAGES_SELECTION "${GUM}" choose --no-limit --height 15 "${PACKAGES_TO_INSTALL[@]}" || return 1
    readarray -t SELECTED_PACKAGES <<<"${PACKAGES_SELECTION}"

    # no items were selected in the list based on the -z check -- a test operator
    # that checks if a string is null
    if [ -z "${SELECTED_PACKAGES}" ]; then

        # display a message to the user
        text "You haven't selected any items from the list. Moving on."
    else

        # at least one item was selected in the list (variable is not null),
        # so the script can install the chosen package(s)

        text "You've selected ${#SELECTED_PACKAGES[@]} package(s) to install. Please wait."

        # join all items into a string using space as separator
        PACKAGE_INSTALL_LIST=$(printf " %s" "${SELECTED_PACKAGES[@]}")
        PACKAGE_INSTALL_LIST="${PACKAGE_INSTALL_LIST:1}"

        # install packages
        info "Installing packages."
        sudo dnf install ${PACKAGE_INSTALL_LIST} -y
    fi
fi
