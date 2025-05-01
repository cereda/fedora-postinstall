#!/usr/bin/env bash

section "Profile photo"

description "Having a custom profile photo for a Linux machine can provide \
a visual identifier that makes it easier to recognize the system at a \
glance, especially in a multi-machine environment. This can be a convenient \
way to quickly distinguish one machine from another and associate it with a \
specific purpose or user."

echo

question "Do you want to generate and copy the profile photo?"

if [ $? = 0 ]; then

    info "Generating profile photo."
    bash common/generate-cat.sh

    info "Copying profile photo."
    cp cat.png "${ROOT_DIRECTORY_STRUCTURE}/profile/cat.png"
fi
