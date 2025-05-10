section "Starship installation and configuration"

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

description "The starship project is an open source, cross-platform, \
and highly customizable shell prompt that aims to provide a modern, \
feature-rich, and efficient user experience for the command line. It \
is designed to enhance productivity and workflow by offering a wide \
range of customization options, integration with various tools and \
services, and a visually appealing display of relevant information."

echo

question "Do you want to install starship?"

# $? holds the exit status of the previous command execution; the logic applied
# throughout the post installation is
# +----+---------------+
# | $? | Semantics     |
# +----+---------------+
# | 0  | yes / success |
# | 1  | no / failure  |
# +----+---------------+
if [ $? = 0 ]; then
    
    info "Preparing the installation directory."
    mkdir -p "${HOME}/.local/bin"
    
    # starship has its own installation script, setting the target directory
    # and overriding existing installations via command line flags
    info "Installing starship."
    sh -c "$(curl -fsSL https://starship.rs/install.sh)" -- -b "${HOME}/.local/bin" -y

    info "Preparing the configuration directory."
    mkdir -p "${ROOT_DIRECTORY_STRUCTURE}/config/starship"

    info "Creating the configuration file for starship."
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
