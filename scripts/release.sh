#!/bin/bash
# Build Fader into a distributable .app + .dmg + Sparkle appcast for GitHub Releases.
#
# By default: AD-HOC signed (no Apple account needed; users "Open Anyway" once).
# Set SIGN_ID + NOTARY_PROFILE to Developer-ID-sign + notarize (warning-free):
#   SIGN_ID="Developer ID Application: <name> (ULHJAB7ZT3)" \
#   NOTARY_PROFILE="fader-notary" scripts/release.sh
# Auto-update works either way — Sparkle verifies the EdDSA-signed appcast.
#
# Usage:  scripts/release.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DEV="/Applications/Xcode.app/Contents/Developer"
DIST="$ROOT/dist"
SIGN_ID="${SIGN_ID:--}"            # default ad-hoc
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

echo "→ Generating project + building Release (universal)…"
xcodegen generate >/dev/null
DEVELOPER_DIR="$DEV" xcodebuild -project Fader.xcodeproj -scheme Fader \
  -configuration Release -derivedDataPath build \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build >/dev/null

APP_SRC="build/Build/Products/Release/Fader.app"
[ -d "$APP_SRC" ] || { echo "error: build product missing" >&2; exit 1; }
rm -rf "$DIST"; mkdir -p "$DIST"
APP="$DIST/Fader.app"
cp -R "$APP_SRC" "$APP"

echo "→ Signing inside-out ($([ "$SIGN_ID" = "-" ] && echo ad-hoc || echo "$SIGN_ID"))…"
HR=(); [ "$SIGN_ID" != "-" ] && HR=(--options runtime)
if [ -d "$APP/Contents/Frameworks" ]; then
  find "$APP/Contents/Frameworks" \( -name "*.xpc" -o -name "*.app" -o -name "Autoupdate" -o -name "*.dylib" \) -print0 \
    | while IFS= read -r -d '' n; do codesign --force ${HR[@]+"${HR[@]}"} --sign "$SIGN_ID" "$n"; done
  find "$APP/Contents/Frameworks" -maxdepth 1 -name "*.framework" -print0 \
    | while IFS= read -r -d '' fw; do codesign --force ${HR[@]+"${HR[@]}"} --sign "$SIGN_ID" "$fw"; done
fi
codesign --force ${HR[@]+"${HR[@]}"} --entitlements Fader/Fader.entitlements --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP" && echo "  signature ok"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

if [ -n "$NOTARY_PROFILE" ] && [ "$SIGN_ID" != "-" ]; then
  echo "→ Notarizing (profile $NOTARY_PROFILE)…"
  ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
  xcrun notarytool submit "$DIST/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$DIST/notarize.zip"
fi

echo "→ Zipping (Sparkle update artifact)…"
ZIP="$DIST/Fader.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "→ Building drag-to-Applications DMG…"
DMG="$DIST/Fader.dmg"
STAGING="$DIST/dmg-staging"; rm -rf "$STAGING"; mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/Fader.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Fader" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

# --- Sparkle appcast (EdDSA-signed; private key in your Keychain) -------------
GENAPPCAST="$ROOT/.sparkle-tools/bin/generate_appcast"
APPCAST="$DIST/appcast.xml"
if [ -x "$GENAPPCAST" ]; then
  echo "→ Generating signed appcast…"
  SRC="$DIST/appcast-src"; rm -rf "$SRC"; mkdir -p "$SRC"; cp "$ZIP" "$SRC/"
  "$GENAPPCAST" --download-url-prefix "https://github.com/hatimhtm/Fader/releases/download/v$VERSION/" "$SRC"
  mv "$SRC/appcast.xml" "$APPCAST"; rm -rf "$SRC"

  # Embed this version's CHANGELOG section as inline release notes in the prompt.
  CHANGELOG="$ROOT/CHANGELOG.md"
  if [ -f "$CHANGELOG" ]; then
    NOTES_MD="$DIST/RELEASE_NOTES.md"
    awk -v ver="$VERSION" '
      $0 ~ ("^## +" ver "([ \t]|$)") { grab=1; next }
      grab && /^## / { grab=0 }
      grab { print }
    ' "$CHANGELOG" | sed '/^[[:space:]]*$/d' > "$NOTES_MD"
    if [ -s "$NOTES_MD" ]; then
      HTML="$DIST/relnotes.html"
      {
        echo "<h3 style=\"margin:0 0 8px;font:600 14px -apple-system\">What&rsquo;s new in Fader $VERSION</h3>"
        echo "<ul style=\"margin:0;padding-left:20px;font:13px -apple-system;line-height:1.5\">"
        sed -E 's/^[[:space:]]*[-*][[:space:]]+//' "$NOTES_MD" \
          | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' \
          | while IFS= read -r line; do [ -n "$line" ] && echo "  <li>$line</li>"; done
        echo "</ul>"
      } > "$HTML"
      TMP="$APPCAST.tmp"
      awk -v notesfile="$HTML" '
        /<item>/ && !done { print; print "<description><![CDATA["; while ((getline l < notesfile) > 0) print l; print "]]></description>"; done=1; next }
        { print }
      ' "$APPCAST" > "$TMP" && mv "$TMP" "$APPCAST"; rm -f "$HTML"
      echo "→ Embedded v$VERSION changelog into the appcast."
    else
      echo "⚠ No '## $VERSION' section in CHANGELOG.md — update prompt will have no notes." >&2
    fi
  fi
else
  echo "⚠ generate_appcast missing (.sparkle-tools/bin) — skipping appcast." >&2
  APPCAST=""
fi

echo "✓ Done."
echo "  DMG (download): $DMG"
echo "  Zip (Sparkle):  $ZIP"
[ -n "$APPCAST" ] && echo "  Appcast:        $APPCAST"
echo
echo "Publish (tag MUST be v$VERSION so appcast URLs resolve):"
NOTES_ARG="--notes \"…\""
[ -f "$DIST/RELEASE_NOTES.md" ] && NOTES_ARG="--notes-file \"$DIST/RELEASE_NOTES.md\""
if [ -n "$APPCAST" ]; then
  echo "  gh release create v$VERSION \"$DMG\" \"$ZIP\" \"$APPCAST\" --title \"Fader v$VERSION\" $NOTES_ARG"
else
  echo "  gh release create v$VERSION \"$DMG\" \"$ZIP\" --title \"Fader v$VERSION\" $NOTES_ARG"
fi
echo "Bump MARKETING_VERSION + CURRENT_PROJECT_VERSION in project.yml before each release."
