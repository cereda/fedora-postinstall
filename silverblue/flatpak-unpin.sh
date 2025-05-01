#!/usr/bin/env bash

section "Unpinning Flatpak runtimes"

description "In Fedora Silverblue, unpinning is used to allow the automatic \
update of a Flatpak runtime. This ensures the runtime stays current with \
security patches and new features, improving the overall system security \
and stability."

echo

question "Do you want to unpin the platform runtimes?"

if [ $? = 0 ]; then

    info "Unpinning platform runtimes."
    flatpak pin runtime/org.fedoraproject.Platform/x86_64/f${FEDORA_VERSION} --remove
    flatpak pin runtime/org.fedoraproject.Platform.GL.default/x86_64/f${FEDORA_VERSION} --remove
fi
