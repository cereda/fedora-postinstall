#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Fedora Flatpak runtime updates"

ui_description "Unpin the Fedora platform runtimes for this release and architecture so they can update automatically."

ui_warning "If this fails, remove any remaining pin with: flatpak pin <runtime> --remove"

if ui_confirm "Unpin the Fedora platform runtimes now?" "Unpin runtimes" "Leave unchanged"; then

    # unpin only the Fedora platform runtimes for the current architecture and
    # release; other pins may have been created intentionally by the user
    FLATPAK_ARCH=$(runtime_selected_architecture)
    FEDORA_RUNTIME_PINS=(
        "runtime/org.fedoraproject.Platform/${FLATPAK_ARCH}/f${FEDORA_VERSION}"
        "runtime/org.fedoraproject.Platform.GL.default/${FLATPAK_ARCH}/f${FEDORA_VERSION}"
    )

    ui_step "Unpinning the Fedora platform runtimes."
    for FEDORA_RUNTIME_PIN in "${FEDORA_RUNTIME_PINS[@]}"; do
        flatpak pin --remove "${FEDORA_RUNTIME_PIN}"
    done

    ui_success "The Fedora platform runtimes are unpinned."
else
    ui_skip "No changes were made to the Fedora runtime pins."
fi
