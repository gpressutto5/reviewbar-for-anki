#!/bin/bash
#
# Install (or update) ReviewBar from the latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/gpressutto5/reviewbar-for-anki/main/scripts/install.sh | bash
#
# This exists because ReviewBar is not notarized: Apple's notarization requires
# a paid Developer Program membership, and without it macOS quarantines the
# download and refuses to open it. Installing from a script rather than from
# Finder avoids the quarantine flag entirely, so there is no warning to click
# through.
#
# Nothing here needs root. It only touches /Applications/ReviewBar.app.
set -euo pipefail

REPO="gpressutto5/reviewbar-for-anki"
BUNDLE_ID="com.reviewbar.app"
APP="/Applications/ReviewBar.app"

fail() { echo "error: $*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "ReviewBar is a macOS app."

major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 15 ] || fail "ReviewBar needs macOS 15 or later (found $(sw_vers -productVersion))."

echo "==> Finding the latest release"
api="https://api.github.com/repos/$REPO/releases/latest"
# Pull the .zip asset's download URL out of the release payload without
# assuming jq is installed.
url=$(curl -fsSL -H "Accept: application/vnd.github+json" "$api" \
	| grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*ReviewBar[^"]*\.zip"' \
	| head -1 | sed 's/.*"\(https[^"]*\)"$/\1/')
[ -n "$url" ] || fail "No .zip asset found in the latest release of $REPO."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "==> Downloading $(basename "$url")"
curl -fsSL "$url" -o "$work/ReviewBar.zip"

echo "==> Unpacking"
# ditto, not unzip: it restores the symlinks and extended attributes that make
# up the app's code signature.
ditto -x -k "$work/ReviewBar.zip" "$work/unpacked"
new=$(find "$work/unpacked" -maxdepth 2 -name "ReviewBar.app" -type d | head -1)
[ -n "$new" ] || fail "The release archive did not contain ReviewBar.app."

# Refuse to touch anything at that path that isn't actually ReviewBar.
if [ -e "$APP" ]; then
	existing=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
		"$APP/Contents/Info.plist" 2>/dev/null || echo "")
	[ "$existing" = "$BUNDLE_ID" ] || \
		fail "$APP exists but is not ReviewBar (id: ${existing:-unknown}). Refusing to replace it."

	if pgrep -f "$APP/Contents/MacOS/ReviewBar" > /dev/null; then
		echo "==> Quitting the running copy"
		osascript -e 'quit app id "'"$BUNDLE_ID"'"' 2>/dev/null || true
		for _ in $(seq 1 10); do
			pgrep -f "$APP/Contents/MacOS/ReviewBar" > /dev/null || break
			sleep 0.5
		done
	fi
	echo "==> Replacing the existing install"
	rm -rf "$APP"
fi

echo "==> Installing to $APP"
ditto "$new" "$APP" || fail "Could not write to /Applications. Are you an admin user?"

# The download carried a quarantine flag; the copy inherits it. Clearing it is
# what makes the app open without the "Apple could not verify" dialog. This is
# the same thing the Finder instructions in the README have you do by hand.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

# Makes notifications and "Open at Login" work — both identify the app through
# Launch Services.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
	-f "$APP" 2>/dev/null || true

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
	"$APP/Contents/Info.plist" 2>/dev/null || echo "?")
echo "==> Installed ReviewBar $version"
echo
echo "Starting it now — look for ReviewBar's icon in the menu bar."
echo "Make sure Anki is running with the AnkiConnect add-on installed."
open "$APP"
