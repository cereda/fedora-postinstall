#!/usr/bin/env bash

GUM_VERSION="0.16.0"

GUM_LINK="https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/gum_${GUM_VERSION}_Linux_x86_64.tar.gz"

SCRIPT_PATH=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

GUM=$(command -v gum || printf "${SCRIPT_PATH}/gum")

if [ ! -x "${GUM}" ]; then
    echo "This script relies on 'gum' -- a tool that provides ready-to-use"
    echo "utilities to help users write useful, interactive scripts. Please"
    echo "wait while the binary is downloaded from GitHub and extracted to"
    echo "the current directory."
    wget "${GUM_LINK}" -O gum.tar.gz
    tar xvzf gum.tar.gz --wildcards --no-anchored '*gum' && mv gum_*/gum . && rm -rf gum_*
fi