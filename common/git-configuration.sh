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

section "Git configuration"

description "Git is a distributed version control system used for tracking \
changes in source code during software development, allowing multiple \
developers to collaborate on a project."

echo

warning "This configuration uses 'git-delta' as pager and 'vim' as editor. \
Make sure you have these packages installed on your system, or edit the \
configuration to use your preferred settings."

echo

# ask for user input (name and e-mail address)
GIT_USERNAME=$(${GUM} input --prompt "Your full name: ")
GIT_EMAIL=$(${GUM} input --prompt "Your e-mail address: ")

info "Generating configuration file for Git."
tee "${HOME}/.gitconfig" <<EOF
[user]
	name = ${GIT_USERNAME}
	email = ${GIT_EMAIL}
[core]
	editor = vim
	pager = delta
[push]
	default = simple
[interactive]
	diffFilter = delta --color-only
[delta]
	side-by-side = true
	line-numbers = true
EOF
