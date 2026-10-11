# Vesper

Vesper is a desktop API client for **macOS and Windows**, built with Flutter. It works offline: collections, requests and history are stored locally, and credentials go into the operating system's keychain.

It's a Postman alternative with its own design, code and assets. It can import Postman Collection v2.x and environment files so you can bring existing work with you.

## Features

| Area | What you get |
| --- | --- |
| Requests | GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS · query params synced with the URL · headers (with bulk edit) · cancel · per-request timeout and redirect overrides |
| Bodies | None, JSON (highlighting, validation, Beautify), Raw (Text/JSON/XML/HTML/JS), form-data with multipart file upload, x-www-form-urlencoded, binary file (drag & drop) |
| Authorization | Bearer, Basic, API key (header or query), OAuth 2.0 (Authorization Code + PKCE via loopback, Client Credentials, refresh) |
| Responses | Status, time, size; virtualized Pretty/Raw viewer with syntax highlighting, collapsible JSON/XML blocks, search, copy, save to file; image preview; open HTML in the browser; headers, cookies and redirect details |
| Workspaces | Separate workspaces (e.g. per project or client), each with its own collections, environments, Globals, history, open tabs and GitHub sync target; switch from the sidebar header, move collections between workspaces |
| Collection auth & variables | Each collection has its own authorization (any auth type) and variables; requests choose **Inherit auth from parent** (the default for new requests) to use it. Variables rank environment → collection → Globals. Postman collection/folder auth and collection variables are imported |
| Collections | Collections → nested folders → requests; create, rename, duplicate, delete (with confirmation), drag-and-drop move and reorder, search |
| Environments | Globals + environments, `{{variables}}` in URL/headers/body/auth, nested variables, `{{$guid}}`/`{{$timestamp}}`/`{{$isoTimestamp}}`/`{{$randomInt}}`, secret variables kept in the keychain, live variable preview |
| History | Every sent request (sanitized: no secrets), grouped by day, re-run, delete, clear, configurable retention |
| cURL | Paste a cURL command into the URL bar or use **Import cURL**; **Copy as cURL** for any request |
| Code snippets | **</>** next to Save: the request as cURL, raw HTTP, JavaScript (fetch), Node.js (Axios), Python (requests), Dart (http, Dio), Go, PHP, Swift, Java (OkHttp), C# (HttpClient) or PowerShell, with variables resolved and auth applied |
| Import / export | Versioned Vesper JSON format; Postman Collection v2.0/2.1 and Postman environments; secrets are excluded unless you opt in |
| Accounts | Sign in with Google (PKCE, optional backend exchange) or GitHub (Device Flow); one account at a time, and both are optional |
| GitHub sync | Push and pull collections as JSON files in a repository you choose, with three-way conflict detection and an explicit confirmation for every write |
| Desktop UX | Multiple tabs (reorder, middle-click close, duplicate), native macOS menu bar, Cmd/Ctrl shortcuts, context menus, resizable panes, dark/light themes, unsaved-change prompts |

### Keyboard shortcuts (⌘ on macOS, Ctrl on Windows)

| Shortcut | Action | Shortcut | Action |
| --- | --- | --- | --- |
| ⌘ Enter | Send | ⌘ . | Cancel request |
| ⌘ S / ⌘ ⇧ S | Save / Save as | ⌘ T | New tab |
| ⌘ W | Close tab | ⌘ D | Duplicate tab |
| ⌘ L | Focus URL | ⌘ K | Search sidebar |
| ⌘ ⇧ ] / [ | Next / previous tab | ⌘ B | Toggle sidebar |
| ⌘ O | Import collection | ⌘ I | Import cURL |
| ⌘ ⇧ C | Copy as cURL | ⌘ , | Settings |
| ⌘ F | Find in response body | ⌘ ⇧ N / E | New collection / environment |

## Architecture

The code is organized by feature, and each feature is split into `domain` (pure Dart models, services and repository interfaces), `data` (Drift, Dio, keychain and GitHub implementations) and `presentation` (Riverpod providers and widgets). Widgets never talk to the database or the network directly. See [docs/architecture.md](docs/architecture.md).

```
lib/
  core/        config, constants, di, errors, logging, network, oauth, security, storage, theme, utils
  features/    api_client, auth, collections, environments, github, history,
               import_export, settings, sync,
               workspace (main window: tabs, sidebar, shell),
               workspaces (workspace list, switcher, active workspace)
  shared/      reusable widgets (code view/editor, key-value editor, split view, dialogs…)
  app.dart     MaterialApp + theme
  main.dart    composition root: window, logging, database, provider overrides
```

**Stack:** Flutter 3.44 / Dart 3.12 · Riverpod 3 · Dio 5 · Drift 2 + SQLite · flutter_secure_storage · window_manager · file_picker · desktop_drop · url_launcher.

## Setup

Requirements:
- Flutter **3.44.x** stable (Dart 3.12). Check with `flutter --version`.
- **macOS:** Xcode 26+ (macOS 12 or later deployment target) and CocoaPods.
- **Windows:** Visual Studio 2022 with the "Desktop development with C++" workload, Windows 10 or later.

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # regenerates Drift code
cp .env.example .env                                        # optional: OAuth client IDs
flutter run -d macos --dart-define-from-file=.env           # or -d windows
```

Vesper runs fully without `.env`. Google sign-in and GitHub then show "not configured" and explain what's missing.

### OAuth configuration

| Variable | Needed for | Where to get it |
| --- | --- | --- |
| `GOOGLE_CLIENT_ID` | Sign in with Google | Google Cloud Console → Credentials → OAuth client ID → **Desktop app** |
| `GOOGLE_DESKTOP_CLIENT_SECRET` | Direct exchange (optional) | Same client. Google treats installed-app secrets as non-confidential |
| `AUTH_BACKEND_URL` | Recommended: server-side code exchange | Your backend; contract in [docs/authentication.md](docs/authentication.md) |
| `GITHUB_CLIENT_ID` | GitHub connection and sync | GitHub → Settings → Developer settings → OAuth Apps → **Enable Device Flow** |
| `GITHUB_SCOPES` | GitHub permission level | Default `read:user repo`; use `read:user public_repo` for public repositories only |

Never put confidential server secrets in `.env`. See [docs/authentication.md](docs/authentication.md) and [docs/github-integration.md](docs/github-integration.md).

## Building

```bash
flutter build macos --release      # build/macos/Build/Products/Release/Vesper.app
flutter build windows --release    # build/windows/x64/runner/Release/ (run on Windows)
```

Signing, notarization and packaging are covered in [docs/release.md](docs/release.md).

## Testing

```bash
flutter analyze
flutter test                                    # unit, repository, HTTP and widget tests
flutter test integration_test -d macos          # end-to-end on a real window (or -d windows)
flutter test integration_test -d macos --dart-define=SHOT_DIR=/tmp/vesper-shots   # with screenshots
```

Full macOS verification (AOT build, real Keychain, restart persistence) is described in [docs/release.md](docs/release.md#macos-verification-suites).

The HTTP tests make real requests to a local server, covering every method, multipart upload, 10 MB bodies, redirects, cookies, cancellation, timeouts, refused connections and DNS failures. The integration tests drive the full app through sending, saving, environments, cURL paste, error states, a 10 MB JSON response, and layout at the minimum window size.

## Security

- Secrets (auth tokens, passwords, API keys, secret variables, Google/GitHub sessions) are stored in the macOS Keychain or Windows Credential Manager and never in SQLite.
- History stores sanitized snapshots; exports exclude secrets by default; GitHub sync never includes them.
- Logs are structured and redacted: no tokens, passwords or query-string values.
- Sensitive values are masked in the UI and can be revealed on demand.
- Imported files are validated and size-limited, and their scripts are never executed.

Details and trade-offs, including why the macOS build isn't sandboxed, are in [docs/security.md](docs/security.md). Database schema and migrations are in [docs/database.md](docs/database.md).
