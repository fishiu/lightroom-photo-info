#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/public-assets docs/images
xcrun swift Tools/GenerateIcon.swift build/public-assets/AppIcon.iconset
cp build/public-assets/AppIcon.iconset/icon_256x256@2x.png docs/images/icon.png
xcrun swiftc -swift-version 5 Sources/MetadataStore.swift Sources/MessagePack.swift \
  Sources/CameraPresentation.swift Sources/InfoPanel.swift Tools/PreviewUI.swift \
  -lsqlite3 -o build/public-assets/preview-ui
build/public-assets/preview-ui build/public-assets/ui
cp build/public-assets/ui/gr4.png docs/images/compact.png
cp build/public-assets/ui/gr4-expanded.png docs/images/expanded.png
xcrun swiftc Sources/AppearanceSettings.swift Tools/PreviewAppearanceSettings.swift \
  -o build/public-assets/preview-settings
build/public-assets/preview-settings docs/images/settings.png
xcrun swift Tools/GenerateShowcase.swift docs/images
