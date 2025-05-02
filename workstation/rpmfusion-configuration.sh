#!/usr/bin/env bash

# MIT License
# 
# Copyright (c) 2025, Paulo Cereda
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

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
