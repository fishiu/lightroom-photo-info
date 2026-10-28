#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$project_dir"

# ARCH=x86_64 is available for source builds; published binaries use arm64.
architecture="${ARCH:-$(uname -m)}"
minimum_macos="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
build_dir="${BUILD_DIR:-build}"
case "$architecture" in
  arm64|x86_64) ;;
  *) printf 'Unsupported ARCH: %s (use arm64 or x86_64)\n' "$architecture" >&2; exit 1 ;;
esac
if [[ ! "$minimum_macos" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || [[ "${minimum_macos%%.*}" -lt 13 ]]; then
  printf 'MACOSX_DEPLOYMENT_TARGET must be a version of macOS 13.0 or later.\n' >&2
  exit 1
fi

app="$build_dir/Lightroom Photo Info.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun swift Tools/GenerateIcon.swift "$build_dir/AppIcon.iconset"
iconutil -c icns "$build_dir/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
xcrun swiftc -swift-version 5 -O \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -target "${architecture}-apple-macosx${minimum_macos}" \
  Sources/*.swift -lsqlite3 -o "$app/Contents/MacOS/LightroomPhotoInfo"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LightroomPhotoInfo</string>
<key>CFBundleIdentifier</key><string>com.leverest.lightroom-photo-info</string>
<key>CFBundleName</key><string>Lightroom Photo Info</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleDisplayName</key><string>Lightroom 拍摄信息</string>
<key>CFBundleVersion</key><string>4</string>
<key>CFBundleShortVersionString</key><string>0.4.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>${minimum_macos}</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAccessibilityUsageDescription</key><string>读取 Lightroom 当前照片，自动显示它的拍摄参数。</string>
</dict></plist>
PLIST
# Local ad-hoc signature only: this is not Developer ID signing or notarization.
codesign --force --sign - --identifier com.leverest.lightroom-photo-info "$app"
codesign --verify --strict "$app"
printf 'Built %s (%s, macOS %s+, ad-hoc signed; not notarized)\n' "$app" "$architecture" "$minimum_macos"
