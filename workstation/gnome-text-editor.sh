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

section "GNOME text editor"

description "This section applies a set of tweaks to the GNOME text editor, \
including highlighting the current line, disabling session restoration, \
showing the grid, line numbers, and right margin, as well as disabling \
spellcheck, to customize the text editing experience."

echo

question "Do you want to configure the GNOME text editor?"

if [ $? = 0 ]; then

    info "Highlighting current line."
    gsettings set org.gnome.TextEditor highlight-current-line true

    info "Disabling restore session."
    gsettings set org.gnome.TextEditor restore-session false

    info "Showing grid."
    gsettings set org.gnome.TextEditor show-grid true

    info "Showing line numbers."
    gsettings set org.gnome.TextEditor show-line-numbers true

    info "Showing right margin."
    gsettings set org.gnome.TextEditor show-right-margin true

    info "Disabling spellcheck."
    gsettings set org.gnome.TextEditor spellcheck false  
fi
