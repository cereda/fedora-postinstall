#!/usr/bin/env bash

# MIT License
# 
# Copyright (c) 2025, Paulo Cereda
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

PACKAGE_INSTALL_LIST="No packages provided. This is a clean toolbox."

section "Useful packages"

description "This section will help you install a collection of useful \
packages. This includes tools like ack (a fast alternative to grep), \
hyperfine (a command line benchmarking tool), delta (a syntax \
highlighting diff viewer), as well as the Java Development Kit (JDK) and \
various archiving utilities such as unrar and p7zip. These packages can \
provide additional functionality for your command line workflow. These \
packages will be installed inside a toolbox."

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
    # set previously (see [silverblue/packages-to-install.sh] for reference) and
    # collect the selected entries into a new array
    readarray -t SELECTED_PACKAGES <<< $(${GUM} choose --no-limit --height 15 "${PACKAGES_TO_INSTALL[@]}")

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

        echo

        question "Should I install them now? It's advisable to do this later."

        echo

        # $? holds the exit status of the previous command execution; the logic
        # applied throughout the post installation is
        # +----+---------------+
        # | $? | Semantics     |
        # +----+---------------+
        # | 0  | yes / success |
        # | 1  | no / failure  |
        # +----+---------------+
        if [ $? = 0 ]; then

            # install packages
            info "Installing packages inside the ${TOOLBOX_NAME} toolbox."
            toolbox --container ${TOOLBOX_NAME} run sudo dnf install ${PACKAGE_INSTALL_LIST}
        fi
    fi
fi

# keep list of installed packages
info "Adding package list to helper function (for reproducibility)."
sed -i "s/TOOLBOX_INSTALLATION_LIST/${PACKAGE_INSTALL_LIST}/" "${ROOT_DIRECTORY_STRUCTURE}/scripts/aliases.sh"
