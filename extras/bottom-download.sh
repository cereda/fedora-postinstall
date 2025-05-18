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

tool-section "bottom"

description "bottom offers an enhanced system monitoring experience, \
providing a visually appealing and interactive interface for tracking \
real time resource utilization, process information, and other system \
metrics."

echo

# Note: GitHub may apply rate limits to the API endpoint, which could
# cause this section to fail (been there, done that)

info "Getting latest version of bottom from GitHub."
test -f bottom.json || wget -q -O bottom.json https://api.github.com/repos/ClementTsang/bottom/releases/latest

info "Downloading bottom from GitHub."
wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux") and endswith("gnu.tar.gz")).browser_download_url' bottom.json)
