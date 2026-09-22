# T20 — Build / sign / notarize scripts, README

**Milestone:** M5 · **Depends on:** T19 · **Status:** todo

## Goal
One command produces a signed, notarized `Dockyard-<version>.dmg` suitable for GitHub Releases; README
tells a new user how to install `apple/container` then Dockyard.

## Files
- `scripts/build-app.sh` — `xcodebuild archive` (Release) → `xcodebuild -exportArchive` with `ExportOptions.plist` (method `developer-id`). Reads `DEVELOPER_ID_APPLICATION`, `TEAM_ID` from env; falls back to ad-hoc (`-`) signing with a warning when unset.
- `scripts/notarize.sh` — `xcrun notarytool submit --wait` using keychain profile `DOCKYARD_NOTARY` (documented `store-credentials` step), then `xcrun stapler staple`.
- `scripts/make-dmg.sh` — `hdiutil` DMG with app + Applications symlink.
- `scripts/release.sh` — runs the three above; version from `MARKETING_VERSION` in project (`agvtool`).
- `README.md` — what it is, screenshots placeholder, requirements (macOS 26, Apple Silicon, `apple/container` 1.0.0 pkg), install, first launch (daemon start), building from source (Xcode 26), architecture summary (link `docs/PLAN.md`), contributing (link `docs/WORKFLOW.md`), version compatibility table (Dockyard ↔ container).
- `CHANGELOG.md` — 0.1.0.
- `LICENSE` — Apache-2.0 (matches upstream; confirm with owner).

## Acceptance
- [ ] `scripts/release.sh` with Developer ID env set produces a stapled DMG; `spctl -a -vv Dockyard.app` reports accepted, notarized.
- [ ] Without env: ad-hoc build succeeds with warning.
- [ ] Fresh user account on this Mac: install pkg + drag Dockyard → onboarding → Start → pull → run flow works end to end.
- [ ] README instructions verified by following them literally.

## Notes
