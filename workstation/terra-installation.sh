#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Terra configuration"

ui_description "Add the Terra rolling RPM repository for Fedora."

if ui_confirm "Add the Terra RPM repository?" "Add" "Skip"; then

    ui_step "Adding the Terra RPM repository."
    sudo dnf install --nogpgcheck --repofrompath "terra,https://repos.fyralabs.com/terra${FEDORA_VERSION}" terra-release

    ui_success "Terra repository added."
else
    ui_skip "Terra repository was not added."
fi
