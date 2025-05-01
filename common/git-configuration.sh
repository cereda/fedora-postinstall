#!/usr/bin/env bash

section "Git configuration"

description "Git is a distributed version control system used for tracking \
changes in source code during software development, allowing multiple \
developers to collaborate on a project."

echo

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
