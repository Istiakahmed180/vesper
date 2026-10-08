#!/usr/bin/env bash
# Regenerates every app icon from scripts/icons/render_icon.swift:
#   macOS  → macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_*.png
#   Windows → windows/runner/resources/app_icon.ico (also used by the installer)
# Requires macOS (Swift/AppKit) and ImageMagick (`brew install imagemagick`).
set -euo pipefail
cd "$(dirname "$0")/../.."

command -v magick >/dev/null || { echo "ImageMagick is required: brew install imagemagick" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
render() { swift scripts/icons/render_icon.swift "$@"; }

# 16 and 32 px use the simplified mark (no braces) so they stay crisp.
mac_dir=macos/Runner/Assets.xcassets/AppIcon.appiconset
for size in 16 32 64 128 256 512 1024; do
  variant=full; [ "$size" -le 32 ] && variant=small
  render "$mac_dir/app_icon_$size.png" "$size" mac "$variant"
done

win_sizes=(16 24 32 48 64 128 256)
win_pngs=()
for size in "${win_sizes[@]}"; do
  variant=full; [ "$size" -le 32 ] && variant=small
  render "$tmp/win_$size.png" "$size" win "$variant"
  win_pngs+=("$tmp/win_$size.png")
done
magick "${win_pngs[@]}" windows/runner/resources/app_icon.ico

echo "Icons written to $mac_dir and windows/runner/resources/app_icon.ico"
