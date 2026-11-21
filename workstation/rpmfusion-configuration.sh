#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "RPMFusion installation and configuration"

description "Configure RPM Fusion and optionally replace ffmpeg."
echo

if question "Do you want to install and configure the RPMFusion repositories?"; then

    info "Configuring the free repository."
    sudo dnf install https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VERSION}.noarch.rpm -y

    info "Configuring the non-free repository."
    sudo dnf install https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VERSION}.noarch.rpm -y

    if [ "$(rpm -qa | grep -i ffmpeg)" ]; then

        section "ffmpeg configuration"

        description "The RPMFusion repository provides an alternative version \
of the ffmpeg multimedia framework that may offer additional features, codecs, \
or functionality not available in Fedora's default ffmpeg package. Replacing \
Fedora's ffmpeg with the RPMFusion version can be useful for users who require \
access to a more comprehensive set of multimedia capabilities or who need to \
work with a wider range of media formats."

        echo

        if question "Do you want to replace Fedora's ffmpeg by RPMFusion's?"; then

            info "Replacing Fedora's ffmpeg."
            sudo dnf swap ffmpeg-free ffmpeg --allowerasing -y
        fi
    fi
fi
