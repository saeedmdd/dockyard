#!/bin/bash
# Shared settings and helpers for the release scripts. Sourced, never run.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/Dockyard.xcodeproj"
SCHEME="Dockyard"
APP_NAME="Dockyard"
BUILD_DIR="$REPO_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/$APP_NAME.app"

# SwiftTerm ships a build plugin, which xcodebuild refuses to run unattended
# without this. In Xcode you get a one-time "Trust & Enable" prompt instead.
XCODEBUILD_FLAGS=(-skipPackagePluginValidation)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# The version the app actually reports, read from the build settings rather
# than parsed out of project.pbxproj.
#
# `agvtool` is the usual answer and the wrong one here: it insists on
# VERSIONING_SYSTEM = apple-generic and rewrites the project file to get it.
# Asking xcodebuild what it is about to build cannot disagree with the build.
dockyard_version() {
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
        "${XCODEBUILD_FLAGS[@]}" -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/ MARKETING_VERSION = /{print $2; exit}'
}

# The Developer ID identity to sign with, or empty for an ad-hoc build.
#
# Set DEVELOPER_ID_APPLICATION to the full certificate name, e.g.
# "Developer ID Application: Your Name (ABCDE12345)", and TEAM_ID to the team.
signing_identity() {
    printf '%s' "${DEVELOPER_ID_APPLICATION:-}"
}

require_signing_identity() {
    local identity
    identity="$(signing_identity)"
    [[ -n "$identity" ]] || die "$1 needs DEVELOPER_ID_APPLICATION set. See README.md."
    security find-identity -v -p codesigning 2>/dev/null | grep -qF "$identity" \
        || die "no codesigning identity named '$identity' in the keychain."
}
