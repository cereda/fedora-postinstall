#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Unpinning Flatpak runtimes"

description "Allow Fedora Flatpak runtimes to update automatically."
echo

warning "In case this action fails, please run 'flatpak pin <runtime> \
--remove' to unpin the Flatpak runtimes."

echo

if question "Do you want to unpin the platform runtimes?"; then

    # unpin only the Fedora platform runtimes for the current architecture and
    # release; other pins may have been created intentionally by the user
    FLATPAK_ARCH=$(runtime_selected_architecture)
    FEDORA_RUNTIME_PINS=(
        "runtime/org.fedoraproject.Platform/${FLATPAK_ARCH}/f${FEDORA_VERSION}"
        "runtime/org.fedoraproject.Platform.GL.default/${FLATPAK_ARCH}/f${FEDORA_VERSION}"
    )

    info "Unpinning Fedora platform runtimes."
    for FEDORA_RUNTIME_PIN in "${FEDORA_RUNTIME_PINS[@]}"; do
        flatpak pin --remove "${FEDORA_RUNTIME_PIN}"
    done
fi
