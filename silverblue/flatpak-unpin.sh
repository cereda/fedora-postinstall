#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "Unpinning Flatpak runtimes"

description "In Fedora Silverblue, unpinning is used to allow the automatic \
update of a Flatpak runtime. This ensures the runtime stays current with \
security patches and new features, improving the overall system security \
and stability."

echo

warning "In case this action fails, please run 'flatpak pin <runtime> \
--remove' to unpin the Flatpak runtimes."

echo

question "Do you want to unpin the platform runtimes?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

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
