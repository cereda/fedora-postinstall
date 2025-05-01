#!/usr/bin/env bash

section "TeX Live configuration"

description "TeX Live is a comprehensive distribution of the TeX typesetting \
system, which is widely used for creating high-quality technical and \
scientific documents. It includes a collection of TeX-related programs, \
fonts, and packages, providing a complete and cross-platform solution for \
document preparation and publishing."

echo

question "Do you want to configure TeX Live?"

if [ $? = 0 ]; then

    info "Creating script for TeX Live."
    sudo tee "/etc/profile.d/texlive.sh" <<EOF
#!/bin/bash
pathmunge () {
    if ! echo \$PATH | /bin/grep -E -q "(^|:)\$1($|:)" ; then
        if [ "\$2" = "after" ] ; then
            PATH=\$PATH:\$1
        else
            PATH=\$1:\$PATH
        fi
    fi
}
pathmunge /opt/texbin
unset pathmunge
EOF

fi
