section "SDKman installation and configuration"

description "SDKman is an open-source tool for managing multiple Software \
Development Kits (SDKs) on Unix-based systems, including macOS and \
Linux. It allows users to easily install, manage, and switch between \
different versions of Java Virtual Machines, Gradle, Maven, and other \
development tools, streamlining the setup and configuration of \
development environments."

echo

question "Do you want to install and configure SDKman?"

if [ $? = 0 ]; then
    info "Installing the SDKman binary."
    export SDKMAN_DIR="${ROOT_DIRECTORY_STRUCTURE}/applications/sdkman" && curl -s "https://get.sdkman.io?rcupdate=false" | bash

    info "Creating wrapper script."
    tee "${ROOT_DIRECTORY_STRUCTURE}/scripts/sdk.sh" <<EOF
# moving these lines to a single file to source it on demand
export SDKMAN_DIR="${ROOT_DIRECTORY_STRUCTURE}/applications/sdkman"
[[ -s "${ROOT_DIRECTORY_STRUCTURE}/applications/sdkman/bin/sdkman-init.sh" ]] && source "${ROOT_DIRECTORY_STRUCTURE}/applications/sdkman/bin/sdkman-init.sh"
EOF

fi
