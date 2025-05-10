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

section "yt-dlp installation and configuration"

description "yt-dlp is an open-source command-line tool that allows \
users to download videos and audio from a wide range of online \
platforms, including YouTube, Vimeo, and many others. It is a \
fork of the popular youtube-dl project, with additional features \
and improvements to enhance the download experience."

echo

question "Do you want to install and configure yt-dlp?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then

    # Note: GitHub may apply rate limits to the API endpoint, which could
    # cause this section to fail (been there, done that)

    info "Downloading the latest version of yt-dlp from GitHub."
    wget -q https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp

    info "Moving script to the local directory."
    mv yt-dlp "${HOME}/.local/bin"

    info "Changing permissions to make it executable."
    chmod +x "${HOME}/.local/bin/yt-dlp"
fi
