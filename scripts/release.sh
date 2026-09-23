#!/bin/bash
# The whole release, in one command:
#
#   DEVELOPER_ID_APPLICATION="Developer ID Application: You (TEAM12345)" \
#   TEAM_ID=TEAM12345 scripts/release.sh
#
# Without those, it still produces a DMG — unsigned and un-notarized, for
# testing on this Mac only.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

VERSION="$(dockyard_version)"
IDENTITY="$(signing_identity)"

log "Releasing $APP_NAME $VERSION"

"$REPO_ROOT/scripts/build-app.sh"

if [[ -n "$IDENTITY" ]]; then
    # The app is notarized before it goes into the image so that the copy a
    # user drags to /Applications carries its own ticket, and then the image is
    # notarized too so the download itself opens without a warning.
    "$REPO_ROOT/scripts/notarize.sh" "$APP_PATH"
fi

DMG_PATH="$("$REPO_ROOT/scripts/make-dmg.sh" | tail -1)"

if [[ -n "$IDENTITY" ]]; then
    "$REPO_ROOT/scripts/notarize.sh" "$DMG_PATH"
else
    warn "Skipped notarization: no DEVELOPER_ID_APPLICATION."
    warn "$(basename "$DMG_PATH") will be refused by Gatekeeper on any other Mac."
fi

log "Done: $DMG_PATH"
