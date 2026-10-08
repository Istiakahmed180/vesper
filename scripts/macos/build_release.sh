#!/usr/bin/env bash
# Local macOS release build. Always builds from a clean Release folder:
# incremental release builds can replace App.framework after it was signed,
# leaving "nested code is modified or invalid".
set -euo pipefail
cd "$(dirname "$0")/../.."
APP=build/macos/Build/Products/Release/Vesper.app
[[ -f .env ]] || { echo "error: .env missing (cp .env.example .env)" >&2; exit 1; }
if pgrep -x Vesper >/dev/null; then
  echo "error: quit Vesper first" >&2
  exit 1
fi
rm -rf build/macos/Build/Products/Release
flutter build macos --release --dart-define-from-file=.env
codesign --verify --strict "$APP"
echo "Built and verified $APP"
