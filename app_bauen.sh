#!/usr/bin/env bash
# Baut Dämmerung.app und legt sie nach /Programme (oder in den Ordner aus $1).
# Braucht nur die Apple-Werkzeuge (swiftc, iconutil, sips, codesign).
set -euo pipefail
cd "$(dirname "$0")"

ZIEL="${1:-/Applications}"
APP="$ZIEL/Dämmerung.app"
ID=local.programmentwicklung.daemmerung

# Swift der Apple-Werkzeuge passt nicht immer zum neuesten SDK: dann das 26er nehmen
baue() { swiftc -O -swift-version 5 -target arm64-apple-macos14.0 "$@" Daemmerung.swift -o "$bau/Daemmerung"; }

if [ ! -f Daemmerung.icns ]; then
  tmp="$(mktemp -d)"
  swift icon.swift "$tmp/icon.png"
  mkdir "$tmp/Daemmerung.iconset"
  for g in 16 32 128 256 512; do
    sips -z $g $g "$tmp/icon.png" --out "$tmp/Daemmerung.iconset/icon_${g}x${g}.png" >/dev/null
    sips -z $((g * 2)) $((g * 2)) "$tmp/icon.png" \
      --out "$tmp/Daemmerung.iconset/icon_${g}x${g}@2x.png" >/dev/null
  done
  iconutil -c icns "$tmp/Daemmerung.iconset" -o Daemmerung.icns
  rm -rf "$tmp"
fi

bau="$(mktemp -d)"
baue 2>/dev/null || baue -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk

# nur die eigene App ersetzen
if [ -d "$APP" ]; then
  [ "$(defaults read "$APP/Contents/Info" CFBundleIdentifier 2>/dev/null)" = "$ID" ] \
    || { echo "$APP gehört nicht zu dieser App – Abbruch"; exit 1; }
  osascript -e "quit app id \"$ID\"" 2>/dev/null || true
  pkill -x Daemmerung 2>/dev/null || true
  rm -rf "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$bau/Daemmerung" "$APP/Contents/MacOS/"
rm -rf "$bau"
cp Daemmerung.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Dämmerung</string>
  <key>CFBundleDisplayName</key><string>Dämmerung</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleExecutable</key><string>Daemmerung</string>
  <key>CFBundleIconFile</key><string>Daemmerung</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Nur falls der direkte Weg fehlt: Dämmerung stellt über die Systemereignisse hell oder dunkel ein.</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP" >/dev/null 2>&1
touch "$APP"
echo "fertig: $APP"
