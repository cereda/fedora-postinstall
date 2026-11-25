#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Go installation and configuration"

ui_description "Install the Go toolchain."

if ui_confirm "Install Go?" "Install" "Skip"; then

    ui_step "Resolving the latest Go release."
    case "$(runtime_selected_architecture)" in
    x86_64) GO_ARCHITECTURE="linux-amd64" ;;
    aarch64) GO_ARCHITECTURE="linux-arm64" ;;
    *)
        ui_error "Unsupported architecture for Go: $(runtime_selected_architecture)."
        return 1
        ;;
    esac
    if ! GO_LATEST_VERSION=$(wget -q -O - https://go.dev/dl/ |
        runtime_select_latest_go_release "${GO_ARCHITECTURE}"); then
        ui_error "Unable to select a Go release for ${GO_ARCHITECTURE}."
        return 1
    fi

    ui_step "Downloading Go."
    wget -q "https://go.dev/${GO_LATEST_VERSION}" -O go.tar.gz

    ui_step "Extracting Go."
    tar xzf go.tar.gz

    ui_step "Installing Go."
    mv go "${ROOT_DIRECTORY_STRUCTURE}/applications/"

    ui_step "Configuring the Go environment."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/environments/go"

    # Resolve managed paths now; escaped values remain runtime shell expressions.
    cat >"${ROOT_DIRECTORY_STRUCTURE}/scripts/go.sh" <<SH
#!/bin/bash

# this is my personal variable and not related to GOROOT or any other
# environment variable used by Go (also, setting GOROOT is discouraged
# according to the documentation)
export GO_HOME="${ROOT_DIRECTORY_STRUCTURE}/applications/go"

# while the use of GOPATH is not mandatory since the introduction of Go
# modules, it's still relevant in certain contexts and can be useful for
# specific workflows
export GOPATH="${ROOT_DIRECTORY_STRUCTURE}/environments/go"

pathmunge () {
    if ! echo \$PATH | /bin/grep -E -q "(^|:)\$1($|:)" ; then
        if [ "\$2" = "after" ] ; then
            PATH=\$PATH:\$1
        else
            PATH=\$1:\$PATH
        fi
    fi
}
pathmunge \${GO_HOME}/bin after
unset pathmunge
SH

    rm -f go*.tar.gz

else
    CONFIRM_STATUS="${?}"
    if [ "${CONFIRM_STATUS}" -eq 1 ]; then
        ui_skip "Go was not installed."
    else
        return "${CONFIRM_STATUS}"
    fi
fi
