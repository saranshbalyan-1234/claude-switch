#!/bin/bash
# Makes dist/claude-switch-<version>.zip: the prebuilt app plus what setup needs.
# On another Mac: unzip it, then run ./run.sh inside. No Xcode tools needed there, only jq.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
bash "$root/scripts/test.sh"

stage=$(mktemp -d)/claude-switch
mkdir -p "$stage/scripts" "$stage/src"
echo "Building the app..."
bash "$root/scripts/build.sh" "$stage"
cp "$root/run.sh" "$stage/"
cp "$root/scripts/setup.sh" "$stage/scripts/"
cp "$root/src/claude-switch" "$stage/src/"

version=$(plutil -extract CFBundleVersion raw "$stage/Claude Switch.app/Contents/Info.plist")
mkdir -p "$root/dist"
zip="$root/dist/claude-switch-$version.zip"
ditto -c -k --norsrc --noextattr --keepParent "$stage" "$zip"  # keeps the app bundle intact, without macOS ._ metadata files
rm -rf "$(dirname "$stage")"
echo "Packaged: $zip"
