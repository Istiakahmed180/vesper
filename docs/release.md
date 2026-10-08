# Release

## Checklist

- [ ] `flutter --version` reports 3.44.x stable
- [ ] `flutter pub get` and `dart run build_runner build --delete-conflicting-outputs`
- [ ] `flutter analyze` reports no issues
- [ ] `flutter test` passes
- [ ] `flutter test integration_test -d macos` passes (and `-d windows` on a Windows machine)
- [ ] Version bumped in `pubspec.yaml` and `AppConstants.appVersion`
- [ ] Database `schemaVersion` bumped with a migration step if the schema changed (see database.md)
- [ ] Release `.env` provides `GOOGLE_CLIENT_ID` / `GITHUB_CLIENT_ID` (public IDs only)
- [ ] macOS verification suites pass (see below)
- [ ] macOS build signed with Developer ID **with the hardened runtime** (`--options runtime`), notarized and stapled
- [ ] Windows build signed
- [ ] Smoke test on a clean machine: send a request, save it, restart (tabs reopen), set a secret variable, import a Postman collection, sign in, connect GitHub

## macOS

```bash
flutter build macos --release --dart-define-from-file=.env.release
# → build/macos/Build/Products/Release/Vesper.app
```

Distribution outside the App Store (Developer ID):

```bash
APP=build/macos/Build/Products/Release/Vesper.app
codesign --deep --force --options runtime --timestamp \
  --entitlements macos/Runner/Release.entitlements \
  --sign "Developer ID Application: <Your Name> (<TEAMID>)" "$APP"
ditto -c -k --keepParent "$APP" Vesper.zip
xcrun notarytool submit Vesper.zip --keychain-profile <profile> --wait
xcrun stapler staple "$APP"
```

Package as a DMG with `hdiutil create -volname Vesper -srcfolder "$APP" -ov -format UDZO Vesper.dmg`, then notarize and staple the DMG too.

Requirements: macOS 12+ deployment target (required by Xcode 26+), hardened runtime, and entitlements as described in security.md.

## Windows

Build on Windows (Flutter does not cross-compile):

```powershell
flutter build windows --release --dart-define-from-file=.env.release
# → build\windows\x64\runner\Release\  (Vesper.exe + DLLs + data\)
```

Package the whole `Release` folder, using one of:
- **MSIX:** add the `msix` dev dependency and run `dart run msix:create` (configure publisher and identity in `pubspec.yaml`).
- **Inno Setup / WiX installer** for a classic setup.exe.

Sign `Vesper.exe` and the installer with `signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /a <file>`.

Runtime requirements: Windows 10 1809+ x64 and the Visual C++ Redistributable, which MSIX and most installers bundle.

## Installers with GitHub Actions (manual)

Two workflows build installers on GitHub's machines. They **never run on push**; start them from **Actions → workflow → Run workflow**.

| Workflow | Runner | Output (artifact) | Install experience |
| --- | --- | --- | --- |
| `Build macOS (DMG)` | macOS 15 | `Vesper-<version>-macOS.dmg` | Open the DMG and drag Vesper onto Applications |
| `Build Windows (Installer)` | Windows | `Vesper-Setup-<version>.exe` | Setup wizard: install location, all users or just me, optional desktop shortcut, Start Menu entry, launch at finish; uninstall from Settings → Apps |

Inputs: **Run tests** (analyze and test first, default on) and **Create release** (attach the file to a draft GitHub Release `v<version>`). Download the result from the run page under **Artifacts**.

**Repository secrets** (Settings → Secrets and variables → Actions). GitHub does not allow secret names that start with `GITHUB_`, hence `OAUTH_`:

| Secret | Value |
| --- | --- |
| `GOOGLE_CLIENT_ID` | Google Desktop client ID |
| `GOOGLE_DESKTOP_CLIENT_SECRET` | Google Desktop client secret |
| `OAUTH_GITHUB_CLIENT_ID` | GitHub OAuth App client ID |

Without them the app still builds; sign-in just shows "not configured".

The version comes from `version:` in `pubspec.yaml`. Packaging files: `scripts/macos/create_dmg.sh` (also works locally) and `windows/installer/vesper.iss` (Inno Setup). The Windows installer bundles the Visual C++ runtime DLLs, so no separate redistributable is needed. It upgrades in place (stable AppId) and leaves user data in `%APPDATA%` on uninstall.

**Unsigned builds:** until code signing is set up, macOS shows "cannot be opened" (use System Settings → Privacy & Security → **Open Anyway**), and Windows SmartScreen shows "Windows protected your PC" (**More info → Run anyway**).

## macOS verification suites

Release-like (AOT, profile mode) end-to-end runs against the real Keychain and the real database of `co.tdevs.vesper`.

> **Warning:** these suites **wipe Vesper's local data and Keychain items** on the machine they run on. They are skipped unless `--dart-define=VESPER_E2E=1` is passed. Do not run them on a machine whose Vesper data you want to keep.

```bash
# Functional suite: HTTP, errors, 10 MB JSON, collections, environments,
# history, auth, cURL, import/export, uploads, Keychain, accounts, GitHub sync
# (local GitHub API simulator), window sizes, themes, tabs, native menus.
flutter drive --profile -d macos --driver test_driver/integration_test.dart \
  --target integration_test/macos_verification.dart \
  --dart-define=VESPER_E2E=1 \
  --dart-define=SHOT_DIR=/tmp/vesper-shots          # optional screenshots
#   --dart-define=ONLY=05+15                         # optional: run selected tests

# Restart / persistence: one binary launched three times, with the release
# binary opening the same data in between.
flutter build macos --profile -t integration_test/macos_persistence.dart --dart-define=VESPER_E2E=1
cp -R build/macos/Build/Products/Profile/Vesper.app /tmp/persist/
/tmp/persist/Vesper.app/Contents/MacOS/Vesper     # prints PHASE COMPLETE write
/tmp/persist/Vesper.app/Contents/MacOS/Vesper     # PHASE COMPLETE verify
open build/macos/Build/Products/Release/Vesper.app   # inspect, then quit
/tmp/persist/Vesper.app/Contents/MacOS/Vesper     # PHASE COMPLETE cleanup
```

## Verification status (this repository)

| Target | Status |
| --- | --- |
| macOS release build | Builds and launches (ad-hoc signed). Not Developer ID signed, not notarized |
| macOS verification + persistence suites | Pass (profile/AOT, real Keychain) |
| Windows build | Not verified |
