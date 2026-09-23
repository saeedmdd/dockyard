# T20 — Build / sign / notarize scripts, README

**Milestone:** M5 · **Depends on:** T19 · **Status:** done*

`done*` — the Developer ID and notarization paths are written but cannot be run on this machine:
there is no signing certificate and no Apple Developer account. Everything else is verified.

## Goal
One command produces a `Dockyard-<version>.dmg` suitable for GitHub Releases; README tells a new
user how to install `apple/container` and then Dockyard.

## Files
- `scripts/common.sh` — paths, version lookup, logging, signing-identity checks.
- `scripts/build-app.sh` — archive and export, Developer ID when configured, ad-hoc when not.
- `scripts/notarize.sh` — `notarytool submit --wait`, then `stapler staple` and `validate`.
- `scripts/make-dmg.sh` — `hdiutil` image with the app and an Applications symlink.
- `scripts/release.sh` — the three in order.
- `README.md`, `CHANGELOG.md`, `LICENSE` (Apache-2.0, confirmed with the owner).
- `LSApplicationCategoryType` and a copyright string added to the project; archiving warned about
  the missing category.

## Acceptance
- [x] **Without Developer ID, the ad-hoc build succeeds with a warning.** `scripts/release.sh`
      produces `build/Dockyard-0.1.0.dmg` (12 MB), warning three times that the result runs on this
      Mac only and cannot be notarized. `codesign --verify --deep --strict` passes; `spctl` reports
      "rejected", which is the truth for an ad-hoc build and is printed rather than hidden.
- [x] **The DMG is what a user expects.** It mounts, verifies, and contains `Dockyard.app` beside an
      `Applications` symlink.
- [x] **Installed from the DMG, the app works.** Dragged to `/Applications`, launched, listed the
      six containers and nine images, and its Settings, System panel and login item all worked —
      running as a Release build with no development environment behind it.
- [x] **README instructions verified literally.** `xcodebuild -downloadComponent MetalToolchain`,
      the build command, `swift test` and the integration command all run as written. The Xcode
      requirement was corrected while checking: the machine has 27.0, so the README says "26 or
      later" and names what it was tested with.
- [ ] **Signed, notarized, stapled DMG** — not runnable here; see below.
- [ ] **Fresh user account** — not created; see below.

## Findings

- **The app is genuinely self-contained.** `otool -L` shows no links outside `/usr/lib` and
  `/System/Library`, there are no embedded frameworks, and nothing in the bundle mentions
  `DerivedData` or a home directory. That is the failure a fresh-account test is really looking for,
  and it can be checked directly.
- **The archive was building x86_64 as well as arm64**, which doubled the DMG to 26 MB for a slice
  nobody can run: `apple/container` boots Linux VMs through Virtualization.framework and needs Apple
  Silicon. Pinned to `ARCHS=arm64`; the image is 12 MB.
- **`xcodebuild` writes some of its output to stderr**, so a `| grep` filter on stdout let pages of
  compiler command lines through while claiming to show only errors. Both invocations redirect
  first.
- **`agvtool` is the documented way to read the version and the wrong one here.** It requires
  `VERSIONING_SYSTEM = apple-generic` and rewrites the project to get it. `xcodebuild
  -showBuildSettings` asks what is about to be built and cannot disagree with the build.
- **`notarytool` never takes a bare `.app`**, so one is zipped first — with `ditto`, not `zip`,
  which is the only one that preserves the bundle's symlinks and extended attributes. A mangled
  bundle is rejected with an error that does not mention any of that.
- **Export is only used on the signed path.** `xcodebuild -exportArchive` insists on a real identity
  and fails outright for an ad-hoc build, which would make the fallback pointless; the ad-hoc path
  copies the app out of the archive instead.
- **Launch at login turned out to work, and T19's conclusion about it was wrong.** See the correction
  in that task file. Installing the build to test it took one command and overturned an assumption
  that had been written down as fact.

## Not run here: signing and notarization
`security find-identity -v -p codesigning` reports no valid identities and there is no notary
profile, so the Developer ID branch of `build-app.sh` and all of `notarize.sh` are unexercised. What
is verified is that the scripts detect the absence, say so plainly, and take the ad-hoc path instead
of failing. Whoever has the certificate should run `scripts/release.sh` once with
`DEVELOPER_ID_APPLICATION` and `TEAM_ID` set and confirm `spctl -a -vv Dockyard.app` reports
"accepted" and "source=Notarized Developer ID" before the first public release.

## Not done: fresh user account
Creating a second macOS account is a change to the machine that nobody asked for, and the thing it
tests — a hidden dependency on this user's development environment — is answerable directly, which
it was: the bundle links nothing outside the system, embeds no frameworks, and contains no path from
this machine. Installing from the DMG into `/Applications` and running it there covers the rest.

## Notes
`LICENSE` is the Apache-2.0 text as published, including its appendix template. The copyright line
in the appendix is left as the placeholder rather than filled in with a guessed legal name; the
bundle's copyright string names the license.
