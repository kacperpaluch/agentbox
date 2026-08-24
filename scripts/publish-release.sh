#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
version="${1:?Użycie: ./scripts/publish-release.sh <wersja> <plik-notatek>}"
notes_file="${2:?Użycie: ./scripts/publish-release.sh <wersja> <plik-notatek>}"
dmg_path="$project_dir/dist/Agentbox-$version.dmg"
tag="v$version"

[[ -f "$dmg_path" ]] || { echo "Brak $dmg_path" >&2; exit 1; }
[[ -f "$notes_file" ]] || { echo "Brak pliku notatek: $notes_file" >&2; exit 1; }

gh release create "$tag" "$dmg_path" --title "Agentbox $version" --notes-file "$notes_file" --latest
uploaded="$(gh release view "$tag" --json assets --jq ".assets[] | select(.name == \"Agentbox-$version.dmg\") | .state")"
[[ "$uploaded" == "uploaded" ]] || { echo "GitHub nie potwierdził uploadu DMG; dist pozostaje bez zmian." >&2; exit 1; }

"$project_dir/scripts/clean-dist.sh"
