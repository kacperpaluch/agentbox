#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
bundle_dir="$project_dir/dist/Agentbox.app"
contents_dir="$bundle_dir/Contents"

cd "$project_dir"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_dir/.build/ModuleCache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
swift build -c release --product AgentboxApp --disable-sandbox

rm -rf "$bundle_dir"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$project_dir/.build/release/AgentboxApp" "$contents_dir/MacOS/Agentbox"
cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$contents_dir/Resources/AppIcon.icns"
chmod 755 "$contents_dir/MacOS/Agentbox"
codesign --force --deep --sign - "$bundle_dir"

echo "$bundle_dir"
