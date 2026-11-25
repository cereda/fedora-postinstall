#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

ui_section "Neovim installation and configuration"

ui_description "Install Neovim and apply a managed configuration."

if ui_confirm "Install and configure Neovim?" "Install" "Skip"; then
    ui_step "Installing Neovim in the toolbox."
    toolbox --container "${TOOLBOX_NAME}" run sudo dnf install neovim

    if NEOVIM_FLAVOR=$(ui_choose_one "Select a Neovim configuration" "Classic" "Modern"); then
        NEOVIM_FLAVOR_STATUS=0
    else
        NEOVIM_FLAVOR_STATUS="${?}"
    fi
    if [ "${NEOVIM_FLAVOR_STATUS}" -ne 0 ]; then
        return "${NEOVIM_FLAVOR_STATUS}"
    fi

    if [ -z "${NEOVIM_FLAVOR}" ]; then
        NEOVIM_FLAVOR="Classic"
    fi

    # The classic profile has no external runtime dependency.
    if [ "${NEOVIM_FLAVOR}" = "Classic" ]; then

        ui_step "Installing vim-plug and writing the Classic Neovim configuration."
        curl -fLo "${HOME}/.local/share/nvim/site/autoload/plug.vim" --create-dirs https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

        mkdir -p "${HOME}/.config/nvim"

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

        ui_step "Preparing the Modern Neovim configuration."
        git clone https://github.com/LazyVim/starter "${HOME}/.config/nvim"

        rm -rf "${HOME}/.config/nvim/.git"

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

    ui_success "Neovim and its configuration are ready."
else
    ui_skip "Neovim was not installed."
fi
