# Database

Vesper stores local data in SQLite through [Drift](https://drift.simonbinder.eu/). The database file `vesper.sqlite` is in the application support directory:
- macOS: `~/Library/Application Support/co.tdevs.vesper/`
- Windows: `%APPDATA%\tdevs\Vesper\`

Schema: `lib/core/storage/app_database.dart`. Generated code: `app_database.g.dart`, regenerated with `dart run build_runner build`. Dates are stored as ISO-8601 text, and foreign keys are enforced (`PRAGMA foreign_keys = ON`).

## Tables (schema v1)

| Table | Purpose | Notes |
| --- | --- | --- |
| `collections` | Collections | `sort_order` for manual ordering |
| `folders` | Nested folders | `collection_id` and `parent_id` cascade on delete |
| `requests` | Saved requests | Params/headers/body/auth/options as typed JSON columns. **Auth secrets are not stored here.** |
| `environments` | Environments and the single `is_global` Globals row | |
| `env_variables` | Variables | `value` is empty for secret variables (stored in the vault) |
| `history_entries` | Sent requests | Sanitized request snapshot; response bodies are not stored |
| `settings_entries` | Key/value settings | `app_settings`, `workspace` (open tabs), `github.sync_target` |
| `sync_states` | Last synced state per item and remote | Primary key `(item_key, remote)` |

Indexes: `requests(collection_id)`, `folders(collection_id)`, `history_entries(executed_at)`, `env_variables(environment_id)`.

JSON columns are decoded defensively. Malformed or partial data falls back to defaults instead of crashing (`core/utils/json_read.dart`).

## Secrets

Secret fields are written to the OS vault under deterministic keys and deleted together with their rows:

| Key | Content |
| --- | --- |
| `vesper.request.<id>.auth.<field>` | token / password / value / clientSecret / accessToken / refreshToken |
| `vesper.env.<envId>.var.<varId>` | Secret variable value |
| `vesper.auth.google.session` | Google session JSON |
| `vesper.auth.github.session` | GitHub session JSON |

## Migrations

`schemaVersion` is defined in `AppDatabase`. To change the schema:

1. Edit the tables and bump `schemaVersion`.
2. Add a step in `onUpgrade`:
   ```dart
   if (from < 2) {
     await m.addColumn(requests, requests.someNewColumn);
   }
   ```
3. Regenerate code. Optionally export schemas for migration tests with `dart run drift_dev schema dump lib/core/storage/app_database.dart drift_schemas/`.

Steps run in order, so a user upgrading from v1 to v4 runs every step.

## Streams

Repositories expose Drift `watch()` streams. Drift shares stream queries by SQL text, not by the tables they read, so change-tick queries must use distinct SQL (`SELECT 1 AS collections_tick` and `SELECT 1 AS environments_tick`). A regression test covers this.

## Clearing data

Settings → Data → **Clear local database** deletes every row (`AppDatabase.wipe`), clears the vault entries and the cookie jar, and resets settings. History alone can be cleared from the History panel or Settings.
