#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
dist_dir="$project_dir/dist"

[[ -d "$dist_dir" ]] || exit 0
rm -rf "$dist_dir/Agentbox.app"
setopt local_options null_glob
for artifact in "$dist_dir"/Agentbox-*.dmg; do
    rm -f "$artifact"
done
rm -f "$dist_dir/.DS_Store"

echo "Wyczyszczono lokalne artefakty release w $dist_dir"
