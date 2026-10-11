# Database

Vesper stores local data in SQLite through [Drift](https://drift.simonbinder.eu/). The database file `vesper.sqlite` is in the application support directory:
- macOS: `~/Library/Application Support/co.tdevs.vesper/`
- Windows: `%APPDATA%\tdevs\Vesper\`

Schema: `lib/core/storage/app_database.dart`. Generated code: `app_database.g.dart`, regenerated with `dart run build_runner build`. Dates are stored as ISO-8601 text, and foreign keys are enforced (`PRAGMA foreign_keys = ON`).

## Tables (schema v5)

| Table | Purpose | Notes |
| --- | --- | --- |
| `workspaces` | Workspaces | The `default` row ("My Workspace") always exists and cannot be deleted. `active_environment_id` is the environment selected in that workspace |
| `collections` | Collections | `workspace_id`; `sort_order` for manual ordering within the workspace; `auth_json` (collection auth without secrets) and `variables_json` (secret values empty) |
| `folders` | Nested folders | `collection_id` and `parent_id` cascade on delete |
| `requests` | Saved requests | Params/headers/body/auth/options as typed JSON columns. **Auth secrets are not stored here.** |
| `environments` | Environments and one `is_global` Globals row per workspace | `workspace_id` |
| `env_variables` | Variables | `value` is empty for secret variables (stored in the vault) |
| `history_entries` | Sent requests | `workspace_id`; sanitized request snapshot; response bodies are not stored |
| `settings_entries` | Key/value settings | `app_settings`, `workspaces.active`, `workspace.tabs.<workspaceId>` (open tabs), `github.sync_target.<workspaceId>` |
| `sync_states` | Last synced state per item and remote (GitHub sync) | Primary key `(item_key, remote)` |
| `sync_outbox` | Local changes waiting for cloud sync, filled by triggers | Primary key `(kind, item_id)` |
| `sync_flags` | Silences the change triggers while a row exists | Used when applying cloud changes and wiping |
| `sync_scopes` | Cloud space of each synced item (personal or a shared workspace) | Primary key `(kind, item_id)` |

Indexes: `requests(collection_id)`, `folders(collection_id)`, `history_entries(executed_at)`, `env_variables(environment_id)`, and `workspace_id` on `collections`, `environments` and `history_entries`.

Folders, requests and variables belong to a workspace through their collection or environment. `workspace_id` has no foreign key (SQLite cannot add one to an existing table); `WorkspaceRepository.delete` removes the workspace's rows and vault secrets itself. History retention (`prune`) applies to all workspaces together.

JSON columns are decoded defensively. Malformed or partial data falls back to defaults instead of crashing (`core/utils/json_read.dart`).

## Secrets

Secret fields are written to the OS vault under deterministic keys and deleted together with their rows:

| Key | Content |
| --- | --- |
| `vesper.request.<id>.auth.<field>` | token / password / value / clientSecret / accessToken / refreshToken |
| `vesper.env.<envId>.var.<varId>` | Secret variable value |
| `vesper.collection.<id>.auth.<field>` | Collection auth secret (same fields as request auth) |
| `vesper.collection.<id>.var.<varId>` | Secret collection variable value |
| `vesper.auth.google.session` | Google session JSON |
| `vesper.auth.github.session` | GitHub session JSON |
| `vesper.auth.cloud.session` | Supabase (cloud sync) session JSON |

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

**v1 → v2 (workspaces):** creates `workspaces` with the default row, adds `workspace_id` (default `'default'`) to collections, environments and history, moves the active environment from `app_settings` onto the default workspace, and renames the `workspace` and `github.sync_target` settings keys to their per-workspace form. Covered by `test/data/workspaces_test.dart`.

**v2 → v3 (collection settings):** adds `auth_json` (`'{}'`) and `variables_json` (`'[]'`) to `collections`.

**v3 → v4 (cloud sync):** creates `sync_outbox`, `sync_flags` and the change triggers (see cloud-sync.md), and renames Globals environments to `globals-<workspaceId>`. Their secret values move in the vault at the next start (`migrateEnvironmentVaultKeys`).

**v4 → v5 (team workspaces):** creates `sync_scopes`.

## Streams

Repositories expose Drift `watch()` streams. Drift shares stream queries by SQL text, not by the tables they read, so change-tick queries must use distinct SQL (`SELECT 1 AS collections_tick` and `SELECT 1 AS environments_tick`). A regression test covers this.

## Clearing data

Settings → Data → **Clear local database** deletes every row (`AppDatabase.wipe`), clears the vault entries and the cookie jar, and resets settings. History alone can be cleared from the History panel or Settings.
