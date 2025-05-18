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

tool-section "hexyl"

description "hexyl provides a user-friendly hexadecimal viewer, allowing \
users to easily inspect and navigate binary data with color-coded output \
and customizable settings."

echo

# Note: GitHub may apply rate limits to the API endpoint, which could
# cause this section to fail (been there, done that)

info "Getting latest version of hexyl from GitHub."
test -f hexyl.json || wget -q -O hexyl.json https://api.github.com/repos/sharkdp/hexyl/releases/latest

info "Downloading hexyl from GitHub."
wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux-gnu") and endswith("tar.gz")).browser_download_url' hexyl.json)
