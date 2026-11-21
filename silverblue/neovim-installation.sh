#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "neovim installation and configuration"

description "Install and configure Neovim."
echo

if question "Do you want to install and configure neovim?"; then
    info "Installing neovim as an RPM package."
    toolbox --container "${TOOLBOX_NAME}" run sudo dnf install neovim

    text "Which configuration do you want to apply?"

    echo

    NEOVIM_FLAVOUR=$("${GUM}" choose "Classic" "Modern")

    if [ -z "${NEOVIM_FLAVOUR}" ]; then
        NEOVIM_FLAVOUR="Classic"
    fi

    # The classic profile has no external runtime dependency.
    if [ "${NEOVIM_FLAVOUR}" = "Classic" ]; then

        info "Installing the plug-in manager for neovim (classic)."
        curl -fLo "${HOME}/.local/share/nvim/site/autoload/plug.vim" --create-dirs https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

        info "Creating configuration directory for neovim."
        mkdir -p "${HOME}/.config/nvim"

        info "Creating configuration file for neovim (classic)."
        cat >"${HOME}/.config/nvim/init.vim" <<'VIM'
call plug#begin('~/.local/share/nvim/plugged')

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
VIM

    else

        # LazyVim requires external command-line tools.

        info "Cloning the starter template (modern)."
        git clone https://github.com/LazyVim/starter "${HOME}/.config/nvim"

        info "Cleaning the starter template (modern)."
        rm -rf "${HOME}/.config/nvim/.git"

        info "Adding custom options to the starter template."
        cat >>"${HOME}/.config/nvim/lua/config/options.lua" <<'LUA'

-- ****************************************
-- Paulo's personal configuration
-- ****************************************
local opt = vim.opt
local global = vim.g

opt.autoindent = true
opt.expandtab = true
opt.softtabstop = 4
opt.shiftwidth = 4
opt.shiftround = true

global.autoformat = false

-- Disable auto pairs
-- global.minipairs_disable = true
-- ****************************************
LUA

        info "Adding custom plugin configuration."
        cat >"${HOME}/.config/nvim/lua/plugins/logo.lua" <<'LUA'
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
LUA

        info "Adding custom plugin configuration [2]."
        cat >"${HOME}/.config/nvim/lua/plugins/blink.lua" <<'LUA'
-- ****************************************
-- Paulo's personal configuration
-- ****************************************
return {
    {
        "saghen/blink.cmp",
        enabled = false,
    },
}
-- ****************************************
LUA

    fi
fi
