#!/bin/bash
# Builds build/LyricAdder.app (universal-ready release build, ad-hoc signed) and the CLI.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT="$ROOT/build"
APP="$OUT/LyricAdder.app"
VERSION="1.2.3"

echo "==> Validating Metal shaders with the offline compiler"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
python3 -I - "$ROOT/Sources/LyricRender/Shaders.swift" "$TMP/karaoke.metal" <<'PY'
import sys, re
src = open(sys.argv[1]).read()
body = re.search(r'"""\n(.*?)\n"""', src, re.S).group(1)
open(sys.argv[2], "w").write(body)
PY
if xcrun -f metal >/dev/null 2>&1; then
  xcrun metal -std=metal3.0 -c "$TMP/karaoke.metal" -o "$TMP/karaoke.air"
  echo "    shaders OK"
else
  echo "    (offline metal compiler not installed; shaders are compiled at runtime)"
fi

echo "==> swift build (release)"
ARCHS=(--arch arm64 --arch x86_64)   # universal: Apple silicon + Intel
swift build -c release "${ARCHS[@]}" --product LyricAdder
swift build -c release "${ARCHS[@]}" --product lyricadder-cli
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/LyricAdder" "$APP/Contents/MacOS/LyricAdder"
cp "$BIN/lyricadder-cli" "$OUT/lyricadder-cli"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>LyricAdder</string>
  <key>CFBundleDisplayName</key><string>Lyric Adder</string>
  <key>CFBundleIdentifier</key><string>com.darkangel2096.lyricadder.native</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>LyricAdder</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Clone Hero chart</string>
      <key>CFBundleTypeExtensions</key><array><string>chart</string></array>
      <key>CFBundleTypeRole</key><string>Editor</string>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>MIDI chart</string>
      <key>CFBundleTypeExtensions</key><array><string>mid</string><string>midi</string></array>
      <key>CFBundleTypeRole</key><string>Editor</string>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "==> Rendering app icon"
if swift "$ROOT/scripts/make-icon.swift" "$TMP/AppIcon.iconset" >/dev/null 2>&1 && iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"; then
  echo "    icon OK"
else
  echo "    (icon generation skipped)"
fi

# SIGN_IDENTITY="Developer ID Application: …" signs for distribution (hardened runtime + secure timestamp);
# otherwise the app is ad-hoc signed for local use. Notarize with scripts/notarize.sh.
if [ -n "${SIGN_IDENTITY:-}" ]; then
  echo "==> Signing with $SIGN_IDENTITY"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$OUT/lyricadder-cli"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  echo "==> Ad-hoc signing"
  codesign --force --sign - --timestamp=none "$APP" >/dev/null
fi
codesign --verify --strict --deep "$APP" && echo "    signature OK"

echo "Done: $APP"
echo "      $OUT/lyricadder-cli"
