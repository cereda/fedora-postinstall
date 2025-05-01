section "Colour configuration for the terminal"

description "vivid is a generator for the LS_COLORS environment \
variable that controls the colorized output of ls, tree, fd, \
bfs, dust and many other tools."

echo

question "Do you want to have custom terminal colours?"

if [ $? = 0 ]; then

    info "Generating custom colors file."
    tee "${ROOT_DIRECTORY_STRUCTURE}/scripts/colors.sh" <<EOF
if [ -x "\$(command -v vivid)" ]; then
    export LS_COLORS="\$(vivid generate dracula)"
fi
EOF

fi
