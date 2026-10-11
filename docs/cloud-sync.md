# Cloud sync

Signed in with Google, Vesper keeps workspaces, collections (with folders,
requests and collection auth/variables), environments and history in sync on
every computer through a [Supabase](https://supabase.com) project.

Secrets never leave the computer: request and collection auth secrets, secret
variable values and sessions stay in the OS vault. Synced items carry empty
values in their place, so a new computer needs tokens to be entered again.

## Setup

1. Create a Supabase project (the free plan is enough).
2. **Authentication → Sign In / Providers → Google:** enable it. Under
   **Client IDs** add the Google desktop client ID used for `GOOGLE_CLIENT_ID`,
   and enter that client's secret.
3. **SQL Editor:** run `supabase/migrations/0001_vesper_sync.sql`. It creates
   the `sync_items` table, Row Level Security policies (each user only sees
   their own rows), the last-write-wins trigger and the realtime publication.
4. **Project Settings → API Keys:** put the project URL and the anon /
   publishable key in `.env`:
   ```
   SUPABASE_URL=https://<project>.supabase.co
   SUPABASE_ANON_KEY=<anon or publishable key>
   ```
   For CI builds add the same values as the repository secrets `SUPABASE_URL`
   and `SUPABASE_ANON_KEY`. Never use the `service_role` / secret key.

Without these values the app runs local-only and Settings explains why.

## How it works

```
local edit ─► SQLite trigger ─► sync_outbox ─► push (upsert sync_items)
                                                   │
other device ◄─ realtime ping ◄─ Supabase ◄────────┘
     └─► pull (server_updated_at > cursor) ─► apply (triggers silenced)
```

- **Sign-in.** The Google ID token from Vesper's own PKCE sign-in is
  exchanged for a Supabase session (`signInWithIdToken`). The session is
  stored in the vault and refreshed by the client.
- **Change tracking.** Triggers on the synced tables record `(kind, id,
  time)` in `sync_outbox` (schema v4). Rows that every device creates by
  itself (the default workspace, empty Globals) are not recorded on insert,
  and Globals have a deterministic id (`globals-<workspaceId>`), so a new
  computer never overwrites cloud data with blanks.
- **Push** uploads the current version of each outbox item (or a deletion)
  and removes the outbox rows that did not change meanwhile.
- **Pull** fetches items changed after a cursor (with a 5 s overlap) and
  applies them inside `withoutChangeTracking`, so nothing is echoed back.
- **Conflicts: last write wins.** A pulled item is skipped while the device
  has a newer local change, and the server ignores uploads older than the
  stored version.
- **Triggers for syncing:** 1.5 s after local changes, on realtime pings from
  other devices, every 60 s, and from "Sync now".
- **Signing out** first uploads pending changes (warning if some cannot be
  uploaded), then removes the account's workspaces, collections,
  environments and history from the computer, leaving an empty
  "My Workspace". Vault secrets stay: they are keyed by item id, so tokens
  reattach when the next sign-in downloads the items again. Another account
  signing in on a cleared computer takes over silently and the previous
  account's secrets are removed.
- **GitHub sign-in** goes through Supabase as well (browser, PKCE, loopback
  redirect `http://127.0.0.1:*/**`); the GitHub token Supabase returns also
  powers repository sync. Builds without a Supabase project keep the Device
  Flow.
- **First sign-in** on a computer uploads its existing data into the account.
  Signing in with a different account than the one whose data is on the
  computer pauses sync and asks: replace the local data with the account's,
  add it to the account, or sign out.
- "Clear local database" does not delete cloud data; the next sync downloads
  it again.

Code: `lib/features/cloud_sync/` (engine and models in `domain`, Drift and
Supabase in `data`, controller and widgets in `presentation`). Tests:
`test/data/cloud_sync_test.dart` runs two devices against an in-memory cloud.
