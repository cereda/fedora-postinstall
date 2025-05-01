#!/usr/bin/env bash

section "yt-dlp installation and configuration"

description "yt-dlp is an open-source command-line tool that allows \
users to download videos and audio from a wide range of online \
platforms, including YouTube, Vimeo, and many others. It is a \
fork of the popular youtube-dl project, with additional features \
and improvements to enhance the download experience."

echo

question "Do you want to install and configure yt-dlp?"

if [ $? = 0 ]; then

    info "Downloading the latest version of yt-dlp from GitHub."
    wget https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp

    info "Moving script to the local installation directory."
    mv yt-dlp "${HOME}/.local/bin"

    info "Changing permissions to make it executable."
    chmod +x "${HOME}/.local/bin/yt-dlp"
fi
