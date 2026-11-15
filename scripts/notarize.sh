#!/bin/bash
# Notarizes and staples build/LyricAdder.app, then writes build/LyricAdder-<version>.zip for sharing.
# Credentials come from a notarytool keychain profile (create once with
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>
# ), passed as NOTARY_PROFILE (default: lyricadder-notary).
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/LyricAdder.app
PROFILE="${NOTARY_PROFILE:-lyricadder-notary}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"

codesign --verify --strict --deep "$APP"
SIG_INFO="$(codesign -dvv "$APP" 2>&1)"
[[ "$SIG_INFO" == *"Authority=Developer ID Application"* ]] || { echo "App is not Developer ID signed; run SIGN_IDENTITY=... scripts/build-app.sh" >&2; exit 1; }

SUBMIT=build/LyricAdder-submit.zip
rm -f "$SUBMIT"
ditto -c -k --keepParent "$APP" "$SUBMIT"
echo "==> Submitting to Apple notary service (profile: $PROFILE)"
xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" --wait --timeout 1h
rm -f "$SUBMIT"

echo "==> Stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

OUT="build/LyricAdder-$VERSION.zip"
rm -f "$OUT"
ditto -c -k --keepParent "$APP" "$OUT"
echo "Done: $OUT"
