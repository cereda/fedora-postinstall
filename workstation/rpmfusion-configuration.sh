#!/usr/bin/env bash

section "RPMFusion installation and configuration"

description "RPMFusion is an open-source project that provides a repository \
of additional software packages for various Linux distributions that use \
the RPM package management system, such as Fedora and CentOS. It offers \
access to a wide range of multimedia codecs, drivers, and other software \
that are not included in the official distribution repositories."

echo

question "Do you want to install and configure the RPMFusion repositories?"

if [ $? = 0 ]; then

    info "Configuring the free repository."
    sudo dnf install https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VERSION}.noarch.rpm -y

    info "Configuring the non-free repository."
    sudo dnf install https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VERSION}.noarch.rpm -y

    if rpm -qa | grep -i ffmpeg >/dev/null 2>&1; then

        section "ffmpeg configuration"

        description "The RPMFusion repository provides an alternative version \
of the ffmpeg multimedia framework that may offer additional features, codecs, \
or functionality not available in Fedora's default ffmpeg package. Replacing \
Fedora's ffmpeg with the RPMFusion version can be useful for users who require \
access to a more comprehensive set of multimedia capabilities or who need to \
work with a wider range of media formats."

        echo

        question "Do you want to replace Fedora's ffmpeg by RPMFusion's?"

        if [ $? = 0 ]; then
            
            info "Replacing Fedora's ffmpeg."
            sudo dnf swap ffmpeg-free ffmpeg --allowerasing -y
        fi
    fi   
fi
