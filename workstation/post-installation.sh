#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

if [ ${0##*/} == ${BASH_SOURCE[0]##*/} ]; then
    echo "╭──────────────────────────────────────────╮"
    echo "│ This script cannot be executed directly. │"
    echo "╰──────────────────────────────────────────╯"
    exit 1
fi

source "common/module-inventory.sh"
runtime_run_module_inventory "workstation"
