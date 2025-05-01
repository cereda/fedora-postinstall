#!/usr/bin/env bash

GUM_TEXT_WIDTH=75

function chapter {
    ${GUM} style --border double \
        --align center \
        --width ${GUM_TEXT_WIDTH} \
        --padding "1 0" \
        --foreground 10 \
        --border-foreground 10 \
        "$1"
}

function section {
    ${GUM} style --width ${GUM_TEXT_WIDTH} \
        --border rounded \
        --align center \
        --foreground 12 \
        --border-foreground 12 \
        "$1"
}

function question {
    ${GUM} confirm \
        --prompt.foreground=6 \
        --selected.background=6 \
        "$1"
}

function text {
    ${GUM} style --width ${GUM_TEXT_WIDTH} \
    "$1"    
}

function description {
    ${GUM} style --width ${GUM_TEXT_WIDTH} \
    --italic \
    "$1"
}

function info {
    ${GUM} style --width ${GUM_TEXT_WIDTH} \
        --foreground 11 \
        "$1"
}
