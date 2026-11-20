#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Go installation and configuration"

description "Go is a programming language developed by Google. It's designed \
for simplicity, efficiency, and strong support for concurrent programming, \
making it ideal for building scalable and high performance applications. \
Go features a statically typed syntax, garbage collection, and a rich \
standard library, which together facilitate rapid development and ease of \
maintenance."

echo

question "Do you want to install Go?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    # get the latest version
    info "Getting the latest version of Go."
    case "$(runtime_selected_architecture)" in
    x86_64) GO_ARCHITECTURE="linux-amd64" ;;
    aarch64) GO_ARCHITECTURE="linux-arm64" ;;
    *)
        text "Unsupported architecture for Go: $(runtime_selected_architecture)."
        return 1
        ;;
    esac
    if ! GO_LATEST_VERSION=$(wget -q -O - https://go.dev/dl/ |
        runtime_select_latest_go_release "${GO_ARCHITECTURE}"); then
        text "Unable to select a Go release for ${GO_ARCHITECTURE}."
        return 1
    fi

    info "Downloading Go."
    wget -q "https://go.dev/${GO_LATEST_VERSION}" -O go.tar.gz

    info "Extracting Go."
    tar xzf go.tar.gz

    info "Moving Go to the local applications directory."
    mv go "${ROOT_DIRECTORY_STRUCTURE}/applications/"

    info "Creating environment."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/environments/go"

    tee "${ROOT_DIRECTORY_STRUCTURE}/scripts/go.sh" <<EOF
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
EOF

    info "Removing archive file."
    rm -f go*.tar.gz

fi
