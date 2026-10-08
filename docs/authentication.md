# Authentication (Google sign-in)

An account is optional. Vesper is fully usable offline without one. Sign-in goes through the `AuthRepository` interface (`lib/features/auth/domain/auth_repository.dart`), so another identity provider can replace Google without touching the UI.

## Flow

1. Vesper starts a one-shot HTTP listener on `127.0.0.1` with an OS-assigned port (RFC 8252 loopback redirect).
2. It opens the system browser at Google's authorization endpoint with `response_type=code`, PKCE (`S256`), a random `state`, `scope=openid email profile`, `access_type=offline`.
3. Google redirects to `http://127.0.0.1:<port>/callback?code=…&state=…`. The `state` is verified and the listener closes.
4. The code is exchanged for tokens by a `GoogleTokenExchanger` (see below).
5. The profile is loaded from the OpenID Connect userinfo endpoint.
6. `{account, tokens}` is stored as one entry in the OS vault (`vesper.auth.google.session`).

**Restore:** at startup, a non-expired session is used as-is. An expired one is refreshed. If the refresh is rejected, the user is signed out. If the network is unreachable, the cached session is kept and marked *offline*.

**Sign out:** the vault entry is deleted, then the refresh token is revoked (best effort).

## Configuration

Create a Google Cloud OAuth client of type **Desktop app**. Desktop clients accept loopback redirects on any port, so no redirect URI registration is needed.

```
GOOGLE_CLIENT_ID=1234567890-abc.apps.googleusercontent.com
```

Choose one exchange strategy.

### A. Backend exchange (recommended)

Set `AUTH_BACKEND_URL`. The client secret then lives only on your server. The backend must implement:

| Endpoint | Request (JSON) | Response |
| --- | --- | --- |
| `POST /auth/google/exchange` | `{"code", "code_verifier", "redirect_uri"}` | `200 {"access_token", "expires_in", "refresh_token"?, "id_token"?, "token_type"}` |
| `POST /auth/google/refresh` | `{"refresh_token"}` | same as above (`refresh_token` optional) |
| `POST /auth/google/revoke` | `{"token"}` | `204` |

`400` or `401` means the grant is invalid or expired, and Vesper signs the user out. The backend should forward to `https://oauth2.googleapis.com/token` with its `client_secret`. It may also mint its own session token, as long as the returned `access_token` is accepted by the userinfo endpoint, or the backend can proxy userinfo.

### B. Direct exchange

Leave `AUTH_BACKEND_URL` empty. Vesper exchanges the code directly with PKCE. Google currently requires the Desktop client's secret in this exchange, but documents it as **not confidential** for installed apps, so it can be supplied through `GOOGLE_DESKTOP_CLIENT_SECRET`. It's read from build-time configuration and never hardcoded.

## Security notes

- No confidential server secret ships in the binary.
- Tokens are never logged. The logger masks sensitive keys and scrubs token patterns.
- The loopback listener binds to 127.0.0.1 only, accepts a single callback, verifies `state`, and times out after 5 minutes.
