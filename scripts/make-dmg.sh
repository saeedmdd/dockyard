#!/bin/bash
# Packs Dockyard.app into a DMG with the usual drag-to-Applications layout.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

VERSION="$(dockyard_version)"
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
STAGING="$BUILD_DIR/dmg-staging"

[[ -d "$APP_PATH" ]] || die "no app at $APP_PATH — run scripts/build-app.sh first."

rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING"

cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

log "Building $(basename "$DMG_PATH")"
# UDZO is the compressed read-only format every macOS release can mount, and
# the one `stapler` will attach a ticket to.
hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH" \
    | sed 's/^/    /'

rm -rf "$STAGING"

log "Verifying the image mounts"
hdiutil verify "$DMG_PATH" >/dev/null || die "the disk image did not verify."

log "Built $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
printf '%s\n' "$DMG_PATH"
