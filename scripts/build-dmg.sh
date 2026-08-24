#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_path="$project_dir/dist/Agentbox.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Resources/Info.plist")"
dmg_path="$project_dir/dist/Agentbox-$version.dmg"
staging_dir="$(mktemp -d)"
trap 'rm -rf "$staging_dir"' EXIT

"$project_dir/scripts/build-app.sh"
setopt local_options null_glob
for old_dmg in "$project_dir"/dist/Agentbox-*.dmg; do
    rm -f "$old_dmg"
done
rm -f "$project_dir/dist/.DS_Store"
cp -R "$app_path" "$staging_dir/Agentbox.app"
ln -s /Applications "$staging_dir/Applications"
hdiutil create -volname "Agentbox" -srcfolder "$staging_dir" -ov -format UDZO "$dmg_path"

echo "$dmg_path"
