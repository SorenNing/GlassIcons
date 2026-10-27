# GlassIcons

SpringBoard-only tweak (iOS 15–17, RootHide): adds a subtle glass rim + top sheen over app icons (`SBIconImageView` layoutSubviews). Does not replace icon files, does not touch badges.

- Hook: `SBIconImageView -layoutSubviews` via ObjC method replacement; overlay created once per view, updated with `CATransaction` (no implicit animation), guarded by `@try`.
- Kill switch: create `/var/mobile/Library/local.glassicons.disabled` (read at load), then respring.
- Prefs (optional, CFPreferences domain `com.soren.glassicons`): `Enabled` (bool, default YES), `Intensity` (0–1, default 0.68).

## Build

Built by GitHub Actions on macOS (`.github/workflows/build.yml`): roothide Theos + iPhoneOS16.5 SDK, `THEOS_PACKAGE_SCHEME=roothide`, arm64e.

Local (Linux) builds are NOT viable for arm64e: `ld64.lld` refuses `-fixup_chains` for arm64e.

Manual build on macOS: `make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide TARGET=iphone:clang:16.5:15.0`

## Status

- arm64e object compiles clean locally (clang 19 + iPhoneOS16.5 SDK, `-fsyntax-only` clean).
- Runtime on device NOT yet verified.

