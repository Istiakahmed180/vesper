# Architecture

## Layers

Each feature in `lib/features/<feature>/` has three layers:

| Layer | Contains | Depends on |
| --- | --- | --- |
| `domain` | Immutable models, pure services (variable resolution, cURL, request preparation, sync logic), repository interfaces | Dart + `core` |
| `data` | Implementations: Drift repositories, Dio HTTP client, GitHub API, Google auth, vault-backed secrets | `domain`, packages |
| `presentation` | Riverpod providers/controllers and widgets | `domain` (and `data` only through providers) |

`lib/core/di/app_providers.dart` defines the providers. `bootstrap.dart` (called by `main.dart` and by the macOS verification suites) overrides the infrastructure providers (real database, logger, initial settings, native menus), and tests override them with in-memory versions.

## Request pipeline

```
ApiRequest (draft in a tab)
   │  RequestPreparer (domain, pure)
   │    • resolve {{variables}} (environment → globals → dynamic)
   │    • URL text is the source of truth for the query string
   │    • apply auth (Bearer / Basic / API key / OAuth 2.0)
   │    • build body (text / url-encoded / multipart / file) + implied Content-Type
   │    • validate URL (scheme, host, unresolved variables)
   ▼
PreparedRequest ──► CurlGenerator ("Copy as cURL")
   │
   │  HttpClientPort.send  (DioHttpClient)
   │    • proxy / SSL / redirect settings, session cookie jar
   │    • CancelHandle → Dio CancelToken
   │    • every failure mapped to NetworkFailure (human message)
   ▼
ApiResponse ──► SendRequestUseCase records sanitized HistoryEntry
   │
   ▼
ResponsePanel: body formatted in an isolate (formatResponseBody) → CodeView (virtualized)
```

## State management (Riverpod 3)

- `activeWorkspaceIdProvider` (`features/workspaces`) is the selected workspace. The collection, environment and history repository providers watch it, so every stream provider rescopes when the user switches. The active environment is stored per workspace (`activeEnvironmentIdProvider`).
- `workspaceProvider` (`WorkspaceController`, `features/workspace`) holds the tabs of the active workspace. On a switch the current tabs, unsaved drafts included, are parked in memory and the target workspace's parked tabs come back, or its saved tabs are reopened from settings. A tab is either a `RequestTab` (draft + saved baseline used for dirty tracking) or an `EnvironmentTab`. Widgets watch narrow `select`ions such as `requestTabProvider(tabId).select(...)`, so typing in one field doesn't rebuild the whole app.
- `responseProvider(tabId)` is a per-tab family holding idle/loading/success/failure. A generation counter discards responses that arrive after a cancel or a newer send.
- `collectionTreesProvider`, `environmentsProvider` and `historyProvider` stream from Drift, so the UI updates automatically after any write.
- `settingsProvider` persists `AppSettings` (theme, network, history retention, startup).
- `shellProvider` covers sidebar section, visibility and width.
- Focus requests (Cmd+L / Cmd+K) are counters in providers, not global mutable state.

Automatic provider retries are disabled (`retry: (_, _) => null`). Failures surface to the user instead of silently repeating disk or network operations.

## Performance

- Response bodies are always received as bytes. Bodies over 32 KB are decoded, pretty-printed and split into lines on a background isolate (`Isolate.run`), which also computes fold ranges.
- `CodeView` renders only the visible lines (`ListView.builder` with a fixed `itemExtent`), highlights each visible line lazily, and clips extremely long lines (the full text is still copied). A 10 MB JSON body (~720k lines) is received, formatted and rendered in about 1.6 s in the integration test, and scrolling, folding and search stay interactive.
- Bodies over 25 MB skip pretty-printing. Editor highlighting is skipped above 200 KB.
- Imports over 512 KB are JSON-decoded on an isolate.

## Desktop integration

- `window_manager`: initial size 1440×900, minimum 980×620, and a close guard that prompts before losing unsaved changes.
- macOS: `PlatformMenuBar` with File / Request / View / Window menus. Its key equivalents handle shortcuts, so the in-app `CallbackShortcuts` are only registered when native menus are off (Windows, tests).
- Native file dialogs via `file_picker`; drag & drop via `desktop_drop`.

## Decisions

| Decision | Reason |
| --- | --- |
| Hand-written immutable models instead of freezed | Fewer generated files; Drift is the only code generator. Models implement `==`, `copyWith` and JSON explicitly. |
| No go_router | A single-window desktop shell; navigation is the sidebar section plus workspace tabs. |
| URL text is the query source of truth | Lossless round trips and no divergence between the URL and the params table. |
| Cookies live in memory per session | Session cookies never touch disk; see security.md. |
| Unsaved drafts are not persisted across restarts | Drafts may contain literal secrets; only saved requests reopen. |
| Collection-level auth and variables are not implemented | Requests carry their own auth; Postman collection-level auth and variables produce import warnings. Future work. |
