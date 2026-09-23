#!/bin/bash
# Builds Dockyard.app for release, signed with a Developer ID when one is
# available and ad-hoc when it is not.
#
#   DEVELOPER_ID_APPLICATION="Developer ID Application: You (TEAM12345)" \
#   TEAM_ID=TEAM12345 scripts/build-app.sh
#
# With neither set the app still builds and runs on this Mac, but Gatekeeper
# will refuse it anywhere else.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

IDENTITY="$(signing_identity)"
VERSION="$(dockyard_version)"

rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR"
mkdir -p "$BUILD_DIR"

if [[ -n "$IDENTITY" ]]; then
    require_signing_identity "build-app.sh"
    [[ -n "${TEAM_ID:-}" ]] || die "DEVELOPER_ID_APPLICATION is set but TEAM_ID is not."
    log "Archiving $APP_NAME $VERSION for Developer ID ($IDENTITY)"
    SIGN_SETTINGS=(
        CODE_SIGN_STYLE=Manual
        CODE_SIGN_IDENTITY="$IDENTITY"
        DEVELOPMENT_TEAM="$TEAM_ID"
    )
else
    warn "DEVELOPER_ID_APPLICATION is not set — signing ad-hoc."
    warn "The result runs on this Mac only. Gatekeeper will reject it elsewhere,"
    warn "and it cannot be notarized."
    log "Archiving $APP_NAME $VERSION ad-hoc"
    SIGN_SETTINGS=(
        CODE_SIGN_STYLE=Manual
        CODE_SIGN_IDENTITY="-"
        DEVELOPMENT_TEAM=""
    )
fi

# arm64 only. `apple/container` needs Apple Silicon — its whole job is booting
# Linux VMs through Virtualization.framework on ARM — so an x86_64 slice is
# weight nobody can run. Building both took the DMG to 26 MB.
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    "${XCODEBUILD_FLAGS[@]}" \
    "${SIGN_SETTINGS[@]}" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    2>&1 | grep -E "^(\*\*|error:)|error: " || true

[[ -d "$ARCHIVE_PATH" ]] || die "the archive was not produced; re-run without the output filter to see why."

mkdir -p "$EXPORT_DIR"

if [[ -n "$IDENTITY" ]]; then
    # Only the Developer ID path goes through exportArchive: export insists on
    # a real identity and fails outright for an ad-hoc build, which would make
    # the fallback useless.
    EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
    cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>$IDENTITY</string>
    <key>destination</key><string>export</string>
</dict>
</plist>
PLIST
    log "Exporting"
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        -exportPath "$EXPORT_DIR" \
        2>&1 | grep -E "^(\*\*|error:)|error: " || true
else
    log "Copying the app out of the archive"
    cp -R "$ARCHIVE_PATH/Products/Applications/$APP_NAME.app" "$APP_PATH"
fi

[[ -d "$APP_PATH" ]] || die "no app at $APP_PATH."

log "Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | sed 's/^/    /'

# Says "accepted" only for a notarized build; for an ad-hoc one it reports
# rejection, which is the truth and worth seeing now rather than from a user.
spctl --assess --type execute -vv "$APP_PATH" 2>&1 | sed 's/^/    /' || true

log "Built $APP_PATH"
