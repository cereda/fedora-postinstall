#!/usr/bin/env bash

GUM_LINK="https://github.com/charmbracelet/gum/releases/download/v0.14.5/gum_0.14.5_Linux_x86_64.tar.gz"

SCRIPT_PATH=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

GUM=$(command -v gum || printf "${SCRIPT_PATH}/gum")

if [ ! -x "${GUM}" ]; then
    echo "gum is needed for this script, please wait."
    wget "${GUM_LINK}" -O gum.tar.gz
    tar xvzf gum.tar.gz --wildcards --no-anchored '*gum' && mv gum_*/gum . && rm -rf gum_*
fi

function section {
    ${GUM} style --width 60 \
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
    ${GUM} style --width 60 \
        --margin "1 0" \
    "$1"    
}

function info {
    ${GUM} style --width 60 \
        --foreground 11 \
        "$1"
}

section "Extra binaries"

question "Do you want to install extra binaries for your system?"

if [ $? = 0 ]; then

    if [ ! -x "$(command -v jq)" ]; then

        info "Installing jq."
        sudo dnf install jq
    fi
    
    text "The script will get the latest versions of a list of binaries from the GitHub API. Please wait."

    info "Getting latest version and downloading 'vivid'."
    test -f vivid.json || wget -q -O vivid.json https://api.github.com/repos/sharkdp/vivid/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux-gnu")).browser_download_url' vivid.json)

    info "Getting latest version and downloading 'gum'."
    test -f gum.json || wget -q -O gum.json https://api.github.com/repos/charmbracelet/gum/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("Linux") and endswith("tar.gz")).browser_download_url' gum.json)

    info "Getting latest version and downloading 'vhs'."
    test -f vhs.json || wget -q -O vhs.json https://api.github.com/repos/charmbracelet/vhs/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("Linux") and endswith("tar.gz")).browser_download_url' vhs.json)

    info "Getting latest version and downloading 'ttyd'."
    test -f ttyd.json || wget -q -O ttyd.json https://api.github.com/repos/tsl0922/ttyd/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("x86_64")).browser_download_url' ttyd.json)

    info "Getting latest version and downloading 'trivy'."
    test -f trivy.json || wget -q -O trivy.json https://api.github.com/repos/aquasecurity/trivy/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("Linux") and contains("64bit") and endswith("tar.gz")).browser_download_url' trivy.json)

    info "Getting latest version and downloading 'trippy'."
    test -f trippy.json || wget -q -O trippy.json https://api.github.com/repos/fujiapple852/trippy/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux-gnu") and endswith("tar.gz")).browser_download_url' trippy.json)

    info "Getting latest version and downloading 'trdsql'."
    test -f trdsql.json || wget -q -O trdsql.json https://api.github.com/repos/noborus/trdsql/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("linux_amd64")).browser_download_url' trdsql.json)

    info "Getting latest version and downloading 'yq'."
    test -f yq.json || wget -q -O yq.json https://api.github.com/repos/mikefarah/yq/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("linux_amd64") and endswith("tar.gz")).browser_download_url' yq.json)

    info "Getting latest version and downloading 'zellij'."
    test -f zellij.json || wget -q -O zellij.json https://api.github.com/repos/zellij-org/zellij/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux") and endswith("tar.gz")).browser_download_url' zellij.json)

    info "Getting latest version and downloading 'surreal'."
    test -f surreal.json || wget -q -O surreal.json https://api.github.com/repos/surrealdb/surrealdb/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("amd64") and contains("linux") and endswith("tgz")).browser_download_url' surreal.json)

    info "Getting latest version and downloading 'ripgrep'."
    test -f ripgrep.json || wget -q -O ripgrep.json https://api.github.com/repos/BurntSushi/ripgrep/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux-musl") and endswith("tar.gz")).browser_download_url' ripgrep.json)

    info "Getting latest version and downloading 'procs'."
    test -f procs.json || wget -q -O procs.json https://api.github.com/repos/dalance/procs/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux") and endswith("zip")).browser_download_url' procs.json)

    info "Getting latest version and downloading 'pingu'."
    test -f pingu.json || wget -q -O pingu.json https://api.github.com/repos/sheepla/pingu/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("Linux") and endswith("tar.gz")).browser_download_url' pingu.json)

    info "Getting latest version and downloading 'picocrypt'."
    test -f picocrypt.json || wget -q -O picocrypt.json https://api.github.com/repos/Picocrypt/CLI/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("amd64") and contains("linux")).browser_download_url' picocrypt.json)

    info "Getting latest version and downloading 'ouch'."
    test -f ouch.json || wget -q -O ouch.json https://api.github.com/repos/ouch-org/ouch/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux-gnu")).browser_download_url' ouch.json)

    info "Getting latest version and downloading 'lsd'."
    test -f lsd.json || wget -q -O lsd.json https://api.github.com/repos/lsd-rs/lsd/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux-gnu")).browser_download_url' lsd.json)

    info "Getting latest version and downloading 'lapce'."
    test -f lapce.json || wget -q -O lapce.json https://api.github.com/repos/lapce/lapce/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("amd64") and contains("linux")).browser_download_url' lapce.json)

    info "Getting latest version and downloading 'jless'."
    test -f jless.json || wget -q -O jless.json https://api.github.com/repos/PaulJuliusMartinez/jless/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux")).browser_download_url' jless.json)

    info "Getting latest version and downloading 'ipinfo'."
    test -f ipinfo.json || wget -q -O ipinfo.json https://api.github.com/repos/ipinfo/cli/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("amd64") and contains("linux") and endswith("tar.gz")).browser_download_url' ipinfo.json)

    info "Getting latest version and downloading 'hexyl'."
    test -f hexyl.json || wget -q -O hexyl.json https://api.github.com/repos/sharkdp/hexyl/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux-gnu") and endswith("tar.gz")).browser_download_url' hexyl.json)

    info "Getting latest version and downloading 'grex'."
    test -f grex.json || wget -q -O grex.json https://api.github.com/repos/pemistahl/grex/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux") and endswith("tar.gz")).browser_download_url' grex.json)

    info "Getting latest version and downloading 'gping'."
    test -f gping.json || wget -q -O gping.json https://api.github.com/repos/orf/gping/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("Linux") and endswith("tar.gz")).browser_download_url' gping.json)

    info "Getting latest version and downloading 'glow'."
    test -f glow.json || wget -q -O glow.json https://api.github.com/repos/charmbracelet/glow/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("Linux") and endswith("tar.gz")).browser_download_url' glow.json)

    info "Getting latest version and downloading 'fx'."
    test -f fx.json || wget -q -O fx.json https://api.github.com/repos/antonmedv/fx/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("amd64") and contains("linux")).browser_download_url' fx.json)

    info "Getting latest version and downloading 'freeze'."
    test -f freeze.json || wget -q -O freeze.json https://api.github.com/repos/charmbracelet/freeze/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("Linux") and endswith("tar.gz")).browser_download_url' freeze.json)

    info "Getting latest version and downloading 'fd'."
    test -f fd.json || wget -q -O fd.json https://api.github.com/repos/sharkdp/fd/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux-gnu") and endswith("tar.gz")).browser_download_url' fd.json)

    info "Getting latest version and downloading 'f2'."
    test -f f2.json || wget -q -O f2.json https://api.github.com/repos/ayoisaiah/f2/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("amd64") and contains("linux") and endswith("tar.gz")).browser_download_url' f2.json)

    info "Getting latest version and downloading 'duf'."
    test -f duf.json || wget -q -O duf.json https://api.github.com/repos/muesli/duf/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux") and endswith("tar.gz")).browser_download_url' duf.json)

    info "Getting latest version and downloading 'duckdb'."
    test -f duckdb.json || wget -q -O duckdb.json https://api.github.com/repos/duckdb/duckdb/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("amd64") and contains("linux") and contains("cli")).browser_download_url' duckdb.json)

    info "Getting latest version and downloading 'deno'."
    test -f deno.json || wget -q -O deno.json https://api.github.com/repos/denoland/deno/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux-gnu") and contains("deno-") and endswith("zip")).browser_download_url' deno.json)

    info "Getting latest version and downloading 'bun'."
    test -f bun.json || wget -q -O bun.json https://api.github.com/repos/oven-sh/bun/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("linux") and endswith("x64.zip")).browser_download_url' bun.json)

    info "Getting latest version and downloading 'bottom'."
    test -f bottom.json || wget -q -O bottom.json https://api.github.com/repos/ClementTsang/bottom/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux") and endswith("gnu.tar.gz")).browser_download_url' bottom.json)

    info "Getting latest version and downloading 'binsider'."
    test -f binsider.json || wget -q -O binsider.json https://api.github.com/repos/orhun/binsider/releases/latest
    wget -q $(jq -r '.assets[] | select(.name | contains("x86_64") and contains("linux-gnu") and endswith("tar.gz")).browser_download_url' binsider.json)

    text "Preparing to unpack binaries."

    info "Creating temporary directory."
    rm -f archives
    mkdir -p archives

    info "Moving files to temporary directory."
    find . -mindepth 1 -maxdepth 1 '(' -name "*.zip" -o -name "*.tar.gz" -o -name "*.tgz" ')' -exec mv {} archives/ \;

    info "Unpacking binaries."
    (cd archives && find -type f -name "*.tar.gz" -exec tar xzf {} \;)
    (cd archives && find -type f -name "*.tgz" -exec tar xzf {} \;)
    (cd archives && find -type f -name "*.zip" -exec unzip -q {} \;)

    info "Creating deployment directory."
    rm -f deploys
    mkdir -p deploys

    info "Moving binaries to the deployment directory."
    find archives -type f -executable -exec mv {} deploys/ \;

    info "Getting latest version and downloading 'vimv'."
    wget -q -O vimv https://raw.githubusercontent.com/thameera/vimv/master/vimv
    
    info "Making 'vimv' executable."
    chmod +x vimv

    info "Moving 'vimv' to the deployment directory."
    mv vimv deploys/

    info "Fixing 'yq' and moving to the deployment directory."
    mv deploys/yq_* deploys/yq

    info "Fixing 'ipinfo' and moving to the deployment directory."
    mv deploys/ipinfo_* deploys/ipinfo

    info "Fixing 'fx' and moving to the deployment directory."
    mv fx_* deploys/fx

    info "Fixing 'picocrypt' and moving to the deployment directory."
    mv picocrypt-* deploys/picocrypt

    info "Fixing 'ttyd' and moving to the deployment directory."
    mv ttyd.x* deploys/ttyd

    info "Removing unused files from the deployment directory."
    rm -f deploys/*.sh

    info "Moving binaries to the home directory."
    mkdir -p "${HOME}/.local/bin"
    (cd deploys && mv * "${HOME}/.local/bin/")
fi

text "That's all, folks!"
