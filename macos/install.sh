#!/bin/bash
# Compile Post-it depuis les sources et l'installe dans /Applications
# (ou ~/Applications si /Applications n'est pas accessible en écriture).
set -e
cd "$(dirname "$0")"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Il faut d'abord les outils de développement d'Apple."
  echo "Une fenêtre va s'ouvrir : clique sur « Installer », puis relance ce script."
  xcode-select --install || true
  exit 1
fi

BUILD="$(mktemp -d /tmp/postit.XXXXXX)"
trap 'rm -rf "$BUILD"' EXIT
APP="$BUILD/Post-it.app"

echo "→ Compilation… (30 s environ)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" Sources/main.swift -o "$APP/Contents/MacOS/Post-it"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "→ Icône…"
mkdir -p "$BUILD/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$BUILD/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s*2)); sips -z $d $d Resources/AppIcon.png --out "$BUILD/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# Signature locale avec « runtime renforcé » (bloque l'injection de code)
if ! codesign --force -s - -o runtime --entitlements Resources/entitlements.plist "$APP" >/dev/null 2>&1; then
  echo "  (signature renforcée impossible, signature simple)"
  codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
fi

DEST="/Applications"
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
killall Post-it 2>/dev/null && sleep 1 || true
rm -rf "$DEST/Post-it.app"
cp -R "$APP" "$DEST/"
echo "✓ Installée dans $DEST/Post-it.app"
open "$DEST/Post-it.app"
