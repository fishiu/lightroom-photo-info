#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail

# Usage: ARCH=arm64 ./scripts/package-release.sh [output-directory]
# Set SKIP_BUILD=1 to package an existing app in BUILD_DIR instead.
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
if [[ "$#" -gt 1 ]]; then
  printf 'Usage: %s [output-directory]\n' "$0" >&2
  exit 1
fi
build_dir="${BUILD_DIR:-build}"
output_dir="${1:-$build_dir/releases}"
app="$build_dir/Lightroom Photo Info.app"
if [[ "${SKIP_BUILD:-0}" != 1 ]]; then
  ./build.sh
fi

plist="$app/Contents/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"
architecture="$(lipo -archs "$app/Contents/MacOS/$executable")"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'Unsupported release version: %s\n' "$version" >&2
  exit 1
fi
case "$architecture" in
  arm64|x86_64) ;;
  *) printf 'Expected one supported architecture, got: %s\n' "$architecture" >&2; exit 1 ;;
esac
codesign --verify --strict "$app"
mkdir -p "$output_dir"
archive_name="Lightroom-Photo-Info-v${version}-macos-${architecture}.zip"
archive="$output_dir/$archive_name"
if [[ -e "$archive" || -e "$archive.sha256" ]]; then
  printf 'Release files already exist; choose a fresh output directory: %s\n' "$output_dir" >&2
  exit 1
fi

# Include the license and exact corresponding-source link with every binary distribution.
stage_dir="$(mktemp -d "$build_dir/release-stage.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
ditto "$app" "$stage_dir/Lightroom Photo Info.app"
cp LICENSE "$stage_dir/LICENSE"
cat > "$stage_dir/Read Me.txt" <<NOTES
Lightroom Photo Info v$version ($architecture)

将 Lightroom Photo Info.app 移入“应用程序”，打开后按提示授予辅助功能权限。
Move the app to Applications, then grant Accessibility permission when prompted.

此安装包为 ad-hoc 签名，尚未经过 Apple 公证。首次打开说明：
This build is ad-hoc signed and is not notarized. Installation instructions:
https://github.com/fishiu/lightroom-photo-info#安装

Copyright (C) 2026 fishiu. GNU GPL v3.0 only. See LICENSE.
Corresponding source code / 对应源码:
https://github.com/fishiu/lightroom-photo-info/tree/v$version
https://github.com/fishiu/lightroom-photo-info/archive/refs/tags/v$version.zip
NOTES
# Preserve the macOS app bundle and its signature; do not alter Gatekeeper state.
ditto -c -k --sequesterRsrc "$stage_dir" "$archive"
unzip -tq "$archive"
(cd "$output_dir" && shasum -a 256 "$archive_name" > "$archive_name.sha256")
printf 'Packaged %s\nChecksum %s.sha256\n' "$archive" "$archive"
printf 'This build is ad-hoc signed and has not been notarized by Apple.\n'
