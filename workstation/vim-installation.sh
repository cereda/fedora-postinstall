#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

section "vim installation and configuration"

description "Install and configure Vim."
echo

if question "Do you want to install and configure vim?"; then

    info "Installing vim as an RPM package."
    sudo dnf install vim -y

    info "Installing the plug-in manager for vim (vim-plug)."
    curl -fLo "${HOME}/.config/vim/autoload/plug.vim" --create-dirs https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

    info "Creating the configuration file."
    cat >"${HOME}/.config/vim/vimrc" <<'VIM'
call plug#begin('~/.config/vim/plugged')

Plug 'godlygeek/tabular'
Plug 'itchyny/lightline.vim'
Plug 'sheerun/vim-polyglot'
" Plug 'sainnhe/edge'
Plug 'sainnhe/everforest'
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

" let g:lightline = {'colorscheme' : 'edge'}
" colorscheme edge

set background=dark
let g:everforest_background = 'medium' " hard, medium, soft
let g:everforest_better_performance = 1
let g:lightline = {'colorscheme' : 'everforest'}
colorscheme everforest

let g:startify_fortune_use_unicode = 1
let g:startify_custom_footer =
    \ ['', "   ooh vim", '']

let g:rainbow_active = 0
set viminfo=""
VIM

fi
