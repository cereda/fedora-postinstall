section "Starship installation and configuration"

description "The starship project is an open-source, cross-platform, \
and highly customizable shell prompt that aims to provide a \
modern, feature-rich, and efficient user experience for the \
command line. It is designed to enhance productivity and \
workflow by offering a wide range of customization options, \
integration with various tools and services, and a visually \
appealing display of relevant information."

echo

question "Do you want to install starship?"

if [ $? = 0 ]; then
    
    info "Preparing the installation directory."
    mkdir -p "${HOME}/.local/bin"
    
    info "Installing starship."
    sh -c "$(curl -fsSL https://starship.rs/install.sh)" -- -b "${HOME}/.local/bin" -y

    info "Preparing the configuration directory."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/config/starship"

    info "Creating the configuration file."
    tee "${ROOT_DIRECTORY_STRUCTURE}/config/starship/starship.toml" <<EOF
[character]
success_symbol = "[➜](bold green)"
error_symbol = "[➜](bold red)"

[username]
show_always = true
format = "[\$user](\$style) at "
style_root = "bold red"
style_user = "bold yellow"

[hostname]
ssh_only = false
style = "bold blue"

[java]
style = "bold green"

[status]
disabled = false
symbol = "🔴"
format = "[\$symbol \$status](\$style) "
EOF

fi
