#!/bin/bash
# Builds Claude Switch.app into the given folder, as one binary for Apple silicon and Intel, macOS 13+.
# The version is the build time (yyyyMMddHHmm), shown in the app's Settings.
set -euo pipefail
mkdir -p "${1:?usage: build.sh <folder>}"
out=$(cd "$1" && pwd)
src=$(cd "$(dirname "$0")/../src" && pwd)
command -v swiftc >/dev/null || { echo "swiftc is missing: xcode-select --install" >&2; exit 1; }

app="$out/Claude Switch.app" tmp=$(mktemp -d) version=$(date +%Y%m%d%H%M)
for arch in arm64 x86_64; do
  swiftc -swift-version 5 -O -target $arch-apple-macos13 -o "$tmp/$arch" "$src"/*.swift
done
rm -rf "$app"; mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lipo -create "$tmp/arm64" "$tmp/x86_64" -o "$app/Contents/MacOS/ClaudeSwitch"
rm -rf "$tmp"
cp "$src/AppIcon.icns" "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>ClaudeSwitch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>local.claude-switch</string>
  <key>CFBundleName</key><string>Claude Switch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Claude Switch brings the Terminal or iTerm tab where Claude is waiting to the front.</string>
</dict></plist>
PLIST
codesign --force -s - "$app" >/dev/null 2>&1
