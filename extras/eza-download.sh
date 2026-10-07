#!/usr/bin/env bash

# MIT License
#
# Copyright (c) 2026, Paulo Cereda
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

tool-section "eza"

description "eza is a modern alternative to the Linux ls command, listing \
files with clearer colors and useful details. It can show directory trees, \
file metadata, and Git status, making it easier to scan and navigate folders."

echo

# Note: GitHub may apply rate limits to the API endpoint, which could
# cause this section to fail (been there, done that)

info "Getting latest version of eza from GitHub."
test -f eza.json || wget -q -O eza.json https://api.github.com/repos/eza-community/eza/releases/latest

info "Downloading eza from GitHub."
wget -q $(jq -r '.assets[] | select(.name | contains("x86_64-unknown-linux-gnu") and endswith("tar.gz")).browser_download_url' eza.json)
