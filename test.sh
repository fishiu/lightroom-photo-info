#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/lightroom-info-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc \
  "$project_dir/Sources/MessagePack.swift" \
  "$project_dir/Sources/MetadataStore.swift" \
  "$project_dir/Sources/CameraPresentation.swift" \
  "$project_dir/Tests/MetadataStoreTests.swift" \
  -lsqlite3 -o "$test_dir/metadata-tests"

"$test_dir/metadata-tests" "$test_dir"

xcrun swiftc \
  "$project_dir/Sources/MessagePack.swift" \
  "$project_dir/Sources/MetadataStore.swift" \
  "$project_dir/Sources/CameraPresentation.swift" \
  "$project_dir/Tests/CameraPresentationTests.swift" \
  -lsqlite3 -o "$test_dir/camera-tests"

"$test_dir/camera-tests"

app_sources=()
for source in "$project_dir"/Sources/*.swift; do
  if [[ "$source" != */main.swift ]]; then app_sources+=("$source"); fi
done
xcrun swiftc "${app_sources[@]}" "$project_dir/Tests/DisplayTransitionTests.swift" \
  -lsqlite3 -o "$test_dir/display-tests"
"$test_dir/display-tests"

xcrun swiftc -target "$(uname -m)-apple-macosx13.0" "$project_dir/Sources/LightroomSelection.swift" "$project_dir/Sources/AlbumTokenReader.swift" \
  "$project_dir/Sources/MetadataRefreshSchedule.swift" "$project_dir/Tests/MetadataRefreshTests.swift" \
  -o "$test_dir/refresh-tests"
"$test_dir/refresh-tests"

xcrun swiftc -target "$(uname -m)-apple-macosx13.0" "$project_dir/Sources/LightroomSelection.swift" "$project_dir/Sources/AlbumTokenReader.swift" "$project_dir/Tests/SelectionClassificationTests.swift" \
  -o "$test_dir/selection-tests"
"$test_dir/selection-tests"
xcrun swiftc "$project_dir/Sources/AppearanceSettings.swift" "$project_dir/Tests/AppearanceSettingsTests.swift" \
  -o "$test_dir/appearance-tests"
"$test_dir/appearance-tests"
xcrun swiftc "${app_sources[@]}" "$project_dir/Tests/TransientPresentationTests.swift" \
  -lsqlite3 -o "$test_dir/presentation-tests"
"$test_dir/presentation-tests"
