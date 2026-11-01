# Changelog

## 0.4.1 — 2026-11-02

- Resolve album scope when Lightroom renders it as inaccessible search pills, with or without flag filters.
- Optional, local text recognition restricted to the search-token region; no screenshot files or uploads.
- Keep exact album matching and reject ambiguous scopes instead of using stale saved selections.
- Add an album-recognition permission menu and a specific message for unresolved duplicates.

## 0.4.0 — 2026-10-28

First public release.

- Native macOS overlay for Lightroom cloud desktop photos and albums.
- Automatic camera, lens, exposure, capture-time and original-dimension display.
- Actual / 35mm-equivalent focal-length toggle and compact camera labels.
- Borderless layout, inline details and saved background transparency.
- Bounded metadata caches, revision checks and reduced background polling.
- Separate transient accessibility failures from confirmed hidden/grid states to reduce flicker.
- Apple Silicon download, build/packaging scripts, CI and GPL-3.0-only license.

Known limitations: default catalog location only; Local tab and Lightroom Classic are unsupported. The first release is ad-hoc signed and has not been notarized by Apple.
