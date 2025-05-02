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

section "Unpinning Flatpak runtimes"

description "In Fedora Silverblue, unpinning is used to allow the automatic \
update of a Flatpak runtime. This ensures the runtime stays current with \
security patches and new features, improving the overall system security \
and stability."

echo

question "Do you want to unpin the platform runtimes?"

if [ $? = 0 ]; then

    info "Unpinning platform runtimes."
    flatpak pin runtime/org.fedoraproject.Platform/x86_64/f${FEDORA_VERSION} --remove
    flatpak pin runtime/org.fedoraproject.Platform.GL.default/x86_64/f${FEDORA_VERSION} --remove
fi
