#!/bin/bash
#
# Build a distributable ReviewBar.app and zip it for a GitHub release.
#
#   scripts/package-release.sh [version]
#
# `version` defaults to the current git tag (or 0.0.0-dev when untagged) and is
# stamped into CFBundleShortVersionString.
#
# Signing is tiered, so the script works before a Developer ID exists:
#
#   1. Developer ID + notarization — when MACOS_SIGN_IDENTITY is set and the
#      notarytool credentials are present. This is the only tier that produces
#      a build macOS opens without a Gatekeeper warning.
#   2. Developer ID only — signed and stapled-less; still warns on first open.
#   3. Ad-hoc ("-") — the fallback. Users must strip the quarantine attribute.
#
# See docs/RELEASING.md for how to obtain a Developer ID and which repository
# secrets to set.
set -euo pipefail

VERSION="${1:-$(git describe --tags --exact-match 2>/dev/null || echo 0.0.0-dev)}"
VERSION="${VERSION#v}"                       # tags are v1.2.3, plists are 1.2.3
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
DIST="dist"
APP="$DIST/ReviewBar.app"
ZIP="$DIST/ReviewBar-$VERSION.zip"

echo "==> Building ReviewBar $VERSION (build $BUILD_NUMBER)"
rm -rf "$DIST" build
mkdir -p "$DIST"
xcodegen generate

# Release, not Debug: Debug carries com.apple.security.get-task-allow, which
# notarization rejects outright.
IDENTITY="${MACOS_SIGN_IDENTITY:--}"
xcodebuild -project ReviewBar.xcodeproj -target ReviewBar -configuration Release \
	SYMROOT=build ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
	MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
	CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" \
	CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
	build

cp -R build/Release/ReviewBar.app "$APP"

if [ "$IDENTITY" != "-" ]; then
	echo "==> Signing with Developer ID: $IDENTITY"
	# ReviewBarKit is a static library, so there is nothing nested to sign —
	# hence a plain signature rather than the discouraged --deep.
	codesign --force --options runtime --timestamp \
		--sign "$IDENTITY" "$APP"
else
	echo "==> No MACOS_SIGN_IDENTITY set; keeping the ad-hoc signature"
fi
codesign --verify --strict --verbose=2 "$APP"

# Notarization rejects com.apple.security.get-task-allow, and Xcode injects it
# for any ad-hoc or development identity unless told not to. Fail loudly here
# rather than at the notarization step, minutes later.
if codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "get-task-allow"; then
	echo "error: $APP carries com.apple.security.get-task-allow." >&2
	echo "       Check CODE_SIGN_INJECT_BASE_ENTITLEMENTS in project.yml." >&2
	exit 1
fi

echo "==> Zipping to $ZIP"
# ditto, not `zip`: it preserves the symlinks and extended attributes that make
# up a code signature. A `zip`-made archive fails signature verification.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [ "$IDENTITY" != "-" ] && [ -n "${NOTARY_KEY_ID:-}" ]; then
	echo "==> Submitting for notarization (this takes a few minutes)"
	xcrun notarytool submit "$ZIP" \
		--key "${NOTARY_KEY_PATH:?NOTARY_KEY_PATH is required to notarize}" \
		--key-id "$NOTARY_KEY_ID" \
		--issuer "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID is required to notarize}" \
		--wait

	# Staple the ticket onto the .app, then re-zip: stapling a zip is not a
	# thing, and an unstapled app needs the network to pass Gatekeeper.
	xcrun stapler staple "$APP"
	rm -f "$ZIP"
	ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
	echo "==> Notarized and stapled"
	spctl --assess --type execute --verbose=2 "$APP" || true
else
	echo "==> Skipping notarization (no notarytool credentials)"
fi

echo "==> Done: $ZIP"
