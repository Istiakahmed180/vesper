#!/usr/bin/env bash
# Packages the macOS release build into a drag-to-install DMG:
#   dist/Vesper-<version>-macOS.dmg  (contains Vesper.app + an Applications link)
#
# Usage: scripts/macos/create_dmg.sh [path/to/Vesper.app] [output-dir]
# Uses `create-dmg` (brew install create-dmg) for a laid-out window when it is
# available, otherwise falls back to plain `hdiutil`.
set -euo pipefail

cd "$(dirname "$0")/../.."
APP="${1:-build/macos/Build/Products/Release/Vesper.app}"
OUT_DIR="${2:-dist}"
VERSION="$(sed -n 's/^version:[[:space:]]*\([^+[:space:]]*\).*/\1/p' pubspec.yaml)"
DMG="$OUT_DIR/Vesper-$VERSION-macOS.dmg"

if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found. Run: flutter build macos --release --dart-define-from-file=.env" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
rm -f "$DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Vesper.app"

made=false
if command -v create-dmg >/dev/null 2>&1; then
  # create-dmg adds the Applications drop link itself.
  if create-dmg \
      --volname "Vesper" \
      --window-pos 200 120 \
      --window-size 600 380 \
      --icon-size 128 \
      --icon "Vesper.app" 160 180 \
      --hide-extension "Vesper.app" \
      --app-drop-link 440 180 \
      --no-internet-enable \
      "$DMG" "$STAGE"; then
    made=true
  else
    echo "warning: create-dmg failed, falling back to hdiutil" >&2
    rm -f "$DMG"
  fi
fi

if [[ "$made" != true ]]; then
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Vesper" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
fi

hdiutil verify "$DMG" >/dev/null
echo "Created $DMG ($(du -h "$DMG" | cut -f1))"
shasum -a 256 "$DMG"
