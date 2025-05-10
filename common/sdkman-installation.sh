section "SDKman installation and configuration"

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

description "SDKman is an open-source tool for managing multiple Software \
Development Kits (SDKs) on Unix-based systems, including macOS and \
Linux. It allows users to easily install, manage, and switch between \
different versions of Java Virtual Machines, Gradle, Maven, and other \
development tools, streamlining the setup and configuration of \
development environments."

echo

question "Do you want to install and configure SDKman?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    # SDKman has its own installation script, setting the target directory
    # via environment variable (as described in the documentation); there's
    # also a URL request parameter that disables modification of shell
    # configuration files (.bashrc, .zshrc, etc)
    info "Installing the SDKman binary."
    export SDKMAN_DIR="${ROOT_DIRECTORY_STRUCTURE}/applications/sdkman" && curl -s "https://get.sdkman.io?rcupdate=false" | bash

    info "Creating wrapper script."
    tee "${ROOT_DIRECTORY_STRUCTURE}/scripts/sdk.sh" <<EOF
# moving these lines to a single file to source it on demand
export SDKMAN_DIR="${ROOT_DIRECTORY_STRUCTURE}/applications/sdkman"
[[ -s "${ROOT_DIRECTORY_STRUCTURE}/applications/sdkman/bin/sdkman-init.sh" ]] && source "${ROOT_DIRECTORY_STRUCTURE}/applications/sdkman/bin/sdkman-init.sh"
EOF

fi
