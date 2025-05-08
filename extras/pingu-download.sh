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

tool-section "pingu"

description "pingu is a modern implementation of the classic ping utility, \
written in Go. It provides a colorful and visually appealing output, making \
it easier to interpret the results of network connectivity tests. It supports \
both IPv4 and IPv6 addresses, allowing users to check the reachability of a \
wide range of network endpoints."

echo

info "Getting latest version of pingu from GitHub."
test -f pingu.json || wget -q -O pingu.json https://api.github.com/repos/sheepla/pingu/releases/latest

info "Downloading pingu from GitHub."
wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("Linux") and endswith("tar.gz")).browser_download_url' pingu.json)
