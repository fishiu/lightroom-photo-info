# Changelog

## 0.4.2 — 2026-11-02

- Read live album scope through Lightroom's built-in Accessibility mode, including normal album browsing and flag-filtered views.
- Resolve typed album identifiers directly, so matching does not depend on album labels being visually displayed or globally unique.
- Keep capture/OCR out of the application; no Screen Recording permission or manual search query is required.

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
