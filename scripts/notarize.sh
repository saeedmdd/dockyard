#!/bin/bash
# Submits a built artifact to Apple's notary service and staples the ticket.
#
# One-time setup, which stores an app-specific password in the login keychain:
#
#   xcrun notarytool store-credentials DOCKYARD_NOTARY \
#       --apple-id you@example.com --team-id TEAM12345 --password <app-specific>
#
# Takes the path to notarize; defaults to the app that build-app.sh produced.
# A DMG can be passed instead, which is what release.sh does: stapling the disk
# image means the download works offline, and the app inside is already stapled.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

TARGET="${1:-$APP_PATH}"
PROFILE="${NOTARY_PROFILE:-DOCKYARD_NOTARY}"

[[ -e "$TARGET" ]] || die "nothing to notarize at $TARGET."
require_signing_identity "notarize.sh"

xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || die "no notary credentials named '$PROFILE'. See the store-credentials line in this script."

# notarytool takes a zip, a DMG or a pkg — never a bare .app — so an app is
# zipped first. ditto rather than zip: it is the only one that preserves the
# bundle's symlinks and extended attributes, and a mangled bundle fails
# notarization with an error that does not say that is what happened.
SUBMISSION="$TARGET"
CLEANUP=""
if [[ "$TARGET" == *.app ]]; then
    SUBMISSION="$BUILD_DIR/$(basename "$TARGET" .app).zip"
    CLEANUP="$SUBMISSION"
    log "Zipping the app for submission"
    rm -f "$SUBMISSION"
    ditto -c -k --keepParent "$TARGET" "$SUBMISSION"
fi

log "Submitting $(basename "$SUBMISSION") — this waits for Apple, and can take a few minutes"
if ! xcrun notarytool submit "$SUBMISSION" --keychain-profile "$PROFILE" --wait; then
    warn "Notarization failed. The log says why:"
    warn "  xcrun notarytool log <submission-id> --keychain-profile $PROFILE"
    [[ -n "$CLEANUP" ]] && rm -f "$CLEANUP"
    die "notarization rejected."
fi
[[ -n "$CLEANUP" ]] && rm -f "$CLEANUP"

# The ticket goes on the original, not on the zip that was submitted.
log "Stapling the ticket"
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"

log "Checking the result the way Gatekeeper will"
spctl --assess --type execute -vv "$TARGET" 2>&1 | sed 's/^/    /' || \
    spctl --assess --type open --context context:primary-signature -vv "$TARGET" 2>&1 | sed 's/^/    /'

log "Notarized $TARGET"
