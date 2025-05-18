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

tool-section "ttyd"

description "ttyd enables users to share their terminal sessions over the \
web. It creates a web-based terminal that can be accessed by multiple users \
simultaneously, allowing for remote collaboration or remote access to a \
terminal environment."

echo

# Note: GitHub may apply rate limits to the API endpoint, which could
# cause this section to fail (been there, done that)

info "Getting latest version of ttyd from GitHub."
test -f ttyd.json || wget -q -O ttyd.json https://api.github.com/repos/tsl0922/ttyd/releases/latest

info "Downloading ttyd from GitHub."
wget -q $(jq -r '.assets[] | select(.name | contains("x86_64")).browser_download_url' ttyd.json)
