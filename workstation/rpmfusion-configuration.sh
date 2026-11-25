#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "RPM Fusion configuration"

ui_description "Enable RPM Fusion repositories and optionally replace Fedora's ffmpeg."

if ui_confirm "Enable the RPM Fusion free and non-free repositories?" "Enable" "Skip"; then

    ui_step "Enabling the RPM Fusion free and non-free repositories."
    sudo dnf install https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VERSION}.noarch.rpm -y
    sudo dnf install https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VERSION}.noarch.rpm -y

    ui_success "RPM Fusion repositories enabled."

    if [ "$(rpm -qa | grep -i ffmpeg)" ]; then

        ui_subsection "ffmpeg configuration"

        ui_description "RPM Fusion's ffmpeg may provide additional codecs and media formats."
        ui_warning "Replacing Fedora's ffmpeg removes the ffmpeg-free package and changes the installed codec set."

        if ui_confirm "Replace Fedora's ffmpeg with the RPM Fusion version?" "Replace" "Keep"; then

            ui_step "Replacing Fedora's ffmpeg with the RPM Fusion version."
            sudo dnf swap ffmpeg-free ffmpeg --allowerasing -y

            ui_success "Fedora's ffmpeg replaced with the RPM Fusion version."
        else
            ui_skip "Keeping Fedora's ffmpeg."
        fi
    else
        ui_skip "Fedora's ffmpeg is not installed, so no replacement was needed."
    fi
else
    ui_skip "RPM Fusion repositories were not enabled."
fi
