# GitHub integration

## Connecting (OAuth Device Flow)

Vesper uses the [OAuth Device Flow](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow). It needs only a **public client ID**, so no client secret ships with the app or needs a backend.

1. Vesper requests a device code (`POST https://github.com/login/device/code`).
2. The user sees a one-time code. **Copy code and open GitHub** opens `github.com/login/device`.
3. Vesper polls `POST https://github.com/login/oauth/access_token`, honouring `interval` and `slow_down`, until it's authorized, denied or expired.
4. The token and profile are stored in the OS vault (`vesper.auth.github.session`).

### Setup

1. GitHub → Settings → Developer settings → **OAuth Apps** → New OAuth App. The callback URL is unused by the device flow but required by the form; any URL works.
2. Tick **Enable Device Flow**.
3. Put the Client ID in `.env` as `GITHUB_CLIENT_ID`.
4. Choose scopes with `GITHUB_SCOPES`:
   - `read:user repo` (default): read your profile and read/write private and public repositories.
   - `read:user public_repo`: public repositories only, which is the minimum for public sync.

A **GitHub App** with Device Flow enabled also works, and gives finer-grained, per-repository permissions (Contents: read & write). Its user tokens expire. Vesper detects that and asks you to reconnect, because refreshing GitHub App tokens requires a client secret.

### Token lifecycle

- At startup the stored token is checked with `GET /user`. A `401` (revoked or expired) disconnects the account; network errors keep it for offline use.
- Any API call returning `401` triggers the same disconnect, with the message "GitHub authorization expired."
- **Disconnect** deletes the local token. Revoking the grant on GitHub's side requires the client secret, so the UI links to GitHub → Settings → Applications.

## Repository selection

Settings → Accounts → GitHub, or **Sync with GitHub** in the sidebar, lists repositories from `GET /user/repos` (owner, collaborator and organization member, paginated). You choose the repository, branch and folder (default `api-client`). The choice is stored in the settings table.

## Collection sync

```
<repo>/<folder>/
  collections/
    users-api.json      ← Vesper collection format v1, no secrets
    payments.json
```

Sync never runs automatically. The sync dialog shows a plan and every write needs an explicit click plus a confirmation that says what will be overwritten.

### Change detection (three-way)

For each collection, Vesper compares three things:
- the local content hash (deterministic JSON, no timestamps);
- the remote file's blob SHA and content;
- the last synced state: path, remote SHA and content hash, stored in the `sync_states` table.

| Local changed | Remote changed | Status | Actions |
| --- | --- | --- | --- |
| – | – | Up to date | – |
| ✓ | – | Local changes | Push |
| – | ✓ | Changed on GitHub | Pull (overwrites local) |
| ✓ | ✓ | Conflict | Keep local (overwrite GitHub) or Keep GitHub (overwrite local) |
| new | missing | Not on GitHub | Push (creates file) |
| synced | deleted | Deleted on GitHub | Push to recreate |
| missing | exists | Only on GitHub | Import |

Pushes send the expected blob SHA, so GitHub rejects the write with `409` if the file changed in the meantime and nothing is overwritten silently. Each push is one commit made through the Contents API (`Vesper: update <name>`).

### Future work

Environment sync (non-secret variables), batching several collections into one commit via the Git Data API, and field-level merges in the conflict view. The `RemoteFileStore` interface makes adding other back ends (GitLab, a Vesper cloud) a data-layer change only.
