#!/usr/bin/env bash
# Baut Duskmode.app und legt sie nach /Programme (oder in den Ordner aus $1, z. B. „dist“).
# Mit --zip zusätzlich ein Zip für ein GitHub-Release daneben (dist/Duskmode-<version>.zip).
# Braucht nur die Apple-Werkzeuge (swiftc, iconutil, sips, codesign, ditto).
set -euo pipefail
cd "$(dirname "$0")"

VERSION=1.0.0
ZIP=false
[ "${1:-}" = "--zip" ] && { ZIP=true; shift; }
ZIEL="${1:-/Applications}"
$ZIP && [ -z "${1:-}" ] && ZIEL=dist
mkdir -p "$ZIEL"
APP="$ZIEL/Duskmode.app"
ID=de.jakobbirkner.duskmode

# Swift der Apple-Werkzeuge passt nicht immer zum neuesten SDK: dann das 26er nehmen
baue() { swiftc -O -swift-version 5 -target arm64-apple-macos14.0 "$@" Duskmode.swift -o "$bau/Duskmode"; }

if [ ! -f Duskmode.icns ]; then
  tmp="$(mktemp -d)"
  swift icon.swift "$tmp/icon.png"
  mkdir "$tmp/Duskmode.iconset"
  for g in 16 32 128 256 512; do
    sips -z $g $g "$tmp/icon.png" --out "$tmp/Duskmode.iconset/icon_${g}x${g}.png" >/dev/null
    sips -z $((g * 2)) $((g * 2)) "$tmp/icon.png" \
      --out "$tmp/Duskmode.iconset/icon_${g}x${g}@2x.png" >/dev/null
  done
  iconutil -c icns "$tmp/Duskmode.iconset" -o Duskmode.icns
  rm -rf "$tmp"
fi

bau="$(mktemp -d)"
baue 2>/dev/null || baue -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk

# nur die eigene App ersetzen
if [ -d "$APP" ]; then
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null)" = "$ID" ] \
    || { echo "$APP gehört nicht zu dieser App – Abbruch"; exit 1; }
  if [ "$ZIEL" = /Applications ]; then
    osascript -e "quit app id \"$ID\"" 2>/dev/null || true
    pkill -x Duskmode 2>/dev/null || true
  fi
  rm -rf "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/de.lproj"
mv "$bau/Duskmode" "$APP/Contents/MacOS/"
rm -rf "$bau"
cp Duskmode.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Duskmode</string>
  <key>CFBundleDisplayName</key><string>Duskmode</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleExecutable</key><string>Duskmode</string>
  <key>CFBundleIconFile</key><string>Duskmode</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>de</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Jakob Birkner · MIT License</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Only if the direct way is missing: Duskmode uses System Events to switch between light and dark.</string>
</dict>
</plist>
EOF
# die eine Systemrückfrage auch auf Deutsch
printf '"NSAppleEventsUsageDescription" = "Nur falls der direkte Weg fehlt: Duskmode stellt über die Systemereignisse hell oder dunkel ein.";\n' \
  > "$APP/Contents/Resources/de.lproj/InfoPlist.strings"

codesign --force --sign - "$APP" >/dev/null 2>&1
touch "$APP"
echo "fertig: $APP"

if $ZIP; then
  zip="$ZIEL/Duskmode-$VERSION.zip"
  rm -f "$zip"
  # ohne Metadaten-Anhängsel (sonst liegt „._Contents“ im Zip)
  ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP" "$zip"
  echo "zip: $zip ($(du -h "$zip" | cut -f1))"
fi
