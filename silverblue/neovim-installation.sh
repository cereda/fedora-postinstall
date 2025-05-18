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

section "neovim installation and configuration"

description "neovim is an open-source, community-driven, and highly \
customizable fork of the Vim text editor. It aims to improve upon the \
original vim by providing a modern, extensible, and efficient text \
editing experience, with a focus on developer productivity and the \
integration of various plugins and tools."

echo

question "Do you want to install and configure neovim?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then
    info "Installing neovim as an RPM package."
    toolbox --container ${TOOLBOX_NAME} run sudo dnf install neovim

    text "Which configuration do you want to apply?"

    echo

    NEOVIM_FLAVOUR=$(${GUM} choose "Classic" "Modern")

    # fallback in case the user does not select a configuration, based on
    # the -z check -- a test operator that checks if a string is null
    if [ -z "${NEOVIM_FLAVOUR}" ]; then
        NEOVIM_FLAVOUR="Classic"
    fi

    # the classic configuration does not require any external command line
    # tools, whereas the modern configuration relies on the LazyVim framework
    if [ "${NEOVIM_FLAVOUR}" = "Classic" ]; then

        info "Installing the plug-in manager for neovim (classic)."
        curl -fLo "${HOME}/.local/share/nvim/site/autoload/plug.vim" --create-dirs https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

        info "Creating configuration directory for neovim."
        mkdir -p "${HOME}/.config/nvim"

        info "Creating configuration file for neovim (classic)."
        tee "${HOME}/.config/nvim/init.vim" <<EOF
call plug#begin('~/.vim/plugged')

Plug 'godlygeek/tabular'
Plug 'itchyny/lightline.vim'
Plug 'sheerun/vim-polyglot'
Plug 'sainnhe/edge'
Plug 'preservim/nerdtree'
Plug 'psliwka/vim-smoothie'
Plug 'mhinz/vim-startify'
Plug 'tpope/vim-surround'
Plug 'preservim/nerdcommenter'
Plug 'luochen1990/rainbow'
Plug 'teto/vim-listchars'
Plug 'cohama/lexima.vim'
Plug 'junegunn/vim-easy-align'

call plug#end()

set nocompatible

filetype plugin indent on
syntax on

set autoindent
set expandtab

set softtabstop=4
set shiftwidth=4
set shiftround

set backspace=indent,eol,start
set hidden

set incsearch
set nohlsearch

set ttyfast
set lazyredraw

set number
set ruler

set noshowmode
set laststatus=2

set background=dark
if has('termguicolors')
    set termguicolors
endif

let g:edge_style = 'aura'
let g:edge_enable_italic = 0
let g:edge_disable_italic_comment = 1

let g:lightline = {'colorscheme' : 'edge'}

colorscheme edge

let g:startify_fortune_use_unicode = 1
let g:startify_custom_footer =
    \ ['', "   ooh vim", '']

let g:rainbow_active = 0
set viminfo=""
EOF

    else

        # the modern configuration relies on the LazyVim framework and
        # requires external command lines tools

        info "Cloning the starter template (modern)." 
        git clone https://github.com/LazyVim/starter "${HOME}/.config/nvim"

        info "Cleaning the starter template (modern)."
        rm -rf "${HOME}/.config/nvim/.git"

        info "Adding custom options to the starter template."
        tee --append "${HOME}/.config/nvim/lua/config/options.lua" <<EOF

-- ****************************************
-- Paulo's personal configuration
-- ****************************************
local opt = vim.opt

opt.autoindent = true
opt.expandtab = true
opt.softtabstop = 4
opt.shiftwidth = 4
opt.shiftround = true
-- ****************************************
EOF

        info "Adding custom plugin configuration."
        tee "${HOME}/.config/nvim/lua/plugins/logo.lua" <<EOF
-- ****************************************
-- Paulo's personal configuration
-- ****************************************
return {
    "snacks.nvim",
    opts = {
        dashboard = {
            -- dashboard configuration
            preset = {
                header = [[
██████╗ ██╗   ██╗ ██████╗██╗  ██╗███████╗██╗
██╔══██╗██║   ██║██╔════╝██║ ██╔╝██╔════╝██║
██║  ██║██║   ██║██║     █████╔╝ ███████╗██║
██║  ██║██║   ██║██║     ██╔═██╗ ╚════██║╚═╝
██████╔╝╚██████╔╝╚██████╗██║  ██╗███████║██╗
╚═════╝  ╚═════╝  ╚═════╝╚═╝  ╚═╝╚══════╝╚═╝
                ]],
            },
        },
    },
}
-- ****************************************
EOF

    fi
fi
