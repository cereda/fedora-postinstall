section "Flatpak cleanup"

text "Fedora Silverblue comes with several applications installed \
as flatpaks. Would you like to remove some of them?"

mapfile -t INSTALLED_FLATPAKS < <(flatpak list --app --columns=application)
readarray -t FLATPAKS_TO_REMOVE <<< $(${GUM} choose --no-limit --height 15 "${INSTALLED_FLATPAKS[@]}")

if [ -z "${FLATPAKS_TO_REMOVE}" ]; then

    text "You haven't selected any items from the list. Moving on."
else
    text "You've selected ${#FLATPAKS_TO_REMOVE[@]} flatpak(s) to remove. Please wait."

    for FLATPAK_TO_REMOVE in "${FLATPAKS_TO_REMOVE[@]}"; do
        info "Removing ${FLATPAK_TO_REMOVE}."
        flatpak uninstall "${FLATPAK_TO_REMOVE}" -y
    done

    info "Removing unused framework(s)."
    flatpak uninstall --unused -y
fi