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

tool-section "Unpacking stage"

info "Creating temporary directory for unpacking (#1)."
rm -f archives
mkdir -p archives

info "Moving archive files to the temporary directory (#1)."
find . -mindepth 1 -maxdepth 1 '(' -name "*.zip" -o -name "*.tar.gz" -o -name "*.tgz" ')' -exec mv {} archives/ \;

info "Unpacking archive files."
(cd archives && find -type f -name "*.tar.gz" -exec tar xzf {} \;)
(cd archives && find -type f -name "*.tgz" -exec tar xzf {} \;)
(cd archives && find -type f -name "*.zip" -exec unzip -q -n {} \;)

info "Creating temporary directory for deployment (#2)."
rm -f deploys
mkdir -p deploys

info "Moving executable files to the temporary directory (#2)."
find archives -type f -executable -exec mv {} deploys/ \;
