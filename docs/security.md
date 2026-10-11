# Security

## Secret storage

| Secret | Where | Never in |
| --- | --- | --- |
| Request auth (bearer token, basic password, API key value, OAuth client secret / tokens) | OS vault | SQLite, logs, history, default exports, GitHub |
| Secret environment variables | OS vault | SQLite (empty value), logs, history, default exports |
| Collection auth secrets and secret collection variables | OS vault | SQLite, logs, history, default exports, GitHub |
| Google / GitHub sessions | OS vault | SQLite, logs |

The vault (`SecretVault`) is platform specific:

- **macOS: `FileSecretVault`.** An AES-256-GCM encrypted file (`secrets.vault`) in the app support directory, with its random key in `secrets.key`; both are mode `600`. Vesper is used internally and distributed with ad-hoc signatures, and the Keychain binds items to the code signature, so every rebuild or update asked "Vesper wants to use your confidential information…" for each item. The file vault never prompts. The trade-off: secrets are protected by the macOS user account and file permissions, not by the Keychain, so anyone who can read files as that user (or a backup of the support directory that includes both files) can read them. To go back to the Keychain, remove the `vaultProvider` override in `bootstrap.dart`; `SecureStorageVault` still implements the legacy-keychain index described below.
- **Windows: `SecureStorageVault`** (`flutter_secure_storage`), which keeps values in a DPAPI-encrypted file tied to the Windows user.

Secrets stored in the Keychain by earlier builds are not migrated (reading them would prompt again): sign in again and re-enter saved tokens. Old entries can be removed in Keychain Access by searching for `co.tdevs.vesper`.

`SecureStorageVault` notes for the macOS legacy keychain (`usesDataProtectionKeychain: false`): the plugin's `readAll()` fails with `errSecParam (-50)` once any item exists, so the vault keeps an index of stored keys (`vesper.__index__`, names only); and items are bound to the creating app's code signature, so ad-hoc rebuilds prompt for access.

## Where secrets could leak, and how Vesper prevents it

- **Logs:** structured logger (`core/logging`). Values whose key looks sensitive are masked, free text is scrubbed of Bearer/Basic credentials, `token=`/`password=` patterns, and GitHub and Google token prefixes. URLs are logged without userinfo, query or fragment. Stack traces are printed only in debug builds.
- **History:** `HistorySanitizer` removes literal values from sensitive headers, query params, form fields, URL userinfo and auth before the snapshot is written. `{{variable}}` references are kept so entries can be re-run.
- **Exports:** secrets are excluded unless the user ticks "Include secret values", which shows a warning.
- **GitHub sync:** files are always produced without secrets.
- **cURL copy:** includes resolved credentials by design. The toast states this.
- **UI:** tokens, passwords, API keys, secret variables, sensitive headers and cookie values are masked with an explicit reveal toggle.
- **Crash reports:** there is no third-party crash reporting. Uncaught errors go to the redacted local log (`<app support>/logs/vesper.log`, rotated at 2 MB).

## Network

- SSL verification is on by default. Turning it off asks for confirmation and shows a persistent warning.
- The proxy is configurable (host, port, bypass list). Proxy credentials are not supported yet, so none are stored.
- Cookies are kept in memory per session and follow the RFC 6265 domain, path, secure and expiry rules. Cookies for unrelated domains are rejected.
- HTML responses are never rendered or executed inside the app. **Open in browser** writes a temporary file and hands it to the default browser on explicit user action.

## Imports

- Files over 50 MB are rejected before parsing; large files are decoded on an isolate.
- Nesting depth (32), item count (20,000) and field sizes (10 MB) are bounded.
- Pre-request and test scripts in Postman files are dropped and reported. Vesper has no script engine and never executes imported content.
- Unknown fields and item types are ignored.

## OAuth

- PKCE (S256) for every authorization-code flow, with a random `state` checked on the loopback callback.
- The loopback listener binds to 127.0.0.1 only, accepts one callback and times out after 5 minutes.
- GitHub uses the Device Flow, so no client secret exists in the app. Google uses a backend exchange or Google's non-confidential installed-app secret from configuration. Nothing is hardcoded.

## macOS sandbox decision

The macOS build is **not sandboxed** (`com.apple.security.app-sandbox = false`). Saved requests reference upload files (form-data and binary bodies) by path. A sandboxed app can only reopen such files through security-scoped bookmarks, so saved uploads would silently break after a relaunch. Developer tools of this kind are typically distributed with Developer ID signing, the hardened runtime and notarization instead of the App Store sandbox. Re-enabling the sandbox requires implementing bookmark storage for file paths (tracked as future work). The entitlements still declare network client/server and user-selected file access explicitly.

Security implications of running unsandboxed: the app can read any file the user can, so upload paths are not confined to user-selected files, and a compromised app (for example through a malicious dependency) would not be contained by the sandbox. Mitigations: Vesper never executes imported content, never renders HTML in-process, keeps secrets in the Keychain, and only reads the upload files a request references.

## Signing configuration (verified)

| Setting | Debug / Profile | Release (as built by `flutter build macos --release`) |
| --- | --- | --- |
| Signature | Ad-hoc | Ad-hoc (no Team ID); not notarized; Gatekeeper rejects it on other Macs |
| `get-task-allow` | Present (debugging) | **Removed** (`CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`), so no debugger attach |
| Hardened runtime | Off | Off in the Xcode build. Turning it on for an ad-hoc build makes `dyld` refuse to load the plugin frameworks (library validation: "different Team IDs"). It must be applied when signing with a Developer ID (`codesign --options runtime`, see release.md), where every framework shares one Team ID |
| Sandbox | Off | Off (see above) |

## Configuration hygiene

`.env`, key files, provisioning profiles, `client_secret*.json` and Vesper export files are git-ignored. Only `.env.example` with empty placeholders is committed.
