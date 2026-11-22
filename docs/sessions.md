# Headless Foundry sessions

The relay can launch and own a Chromium-based browser that signs in to an
already running Foundry world and keeps its REST API module connected. Its four
authenticated endpoints follow the
[upstream session API](https://foundryrestapi.com/docs/api/session), reusing an
existing pairing rather than launching worlds through Foundry's administration
screen. See [upstream compatibility](api.md#upstream-compatibility) for API
differences, [Configuration, Deployment, and Logging](configuration.md) for
ordinary relay settings, and [Chapter 4: Headless Browser Automation and the OpenSSL FFI Boundary](headless-sessions.md)
for the internal browser, CDP, and OpenSSL architecture.

## Enable sessions

Configure the ordinary relay executable. Leave `RELAY_CHROME` unset or empty to
disable session creation. The browser remains a separate installed binary
driven directly over native Titan CDP; the relay never invokes Node, Python, or
the Titan compiler. The numeric settings are validated at startup even when
sessions are disabled—after SQLite opens and before the listener binds—so an
invalid value exits with status 1.

| Variable | Default | Meaning |
| --- | --- | --- |
| `RELAY_CHROME` | empty, disabled | Chrome, Chromium, or Edge executable or launcher path |
| `RELAY_BROWSER_PROFILES` | `build/browser-profiles` | Existing parent directory for disposable private profiles |
| `RELAY_MAX_SESSIONS` | `4` | Maximum admitted sessions, including startup and retirement; range `1`–`64` |
| `RELAY_SESSION_TIMEOUT_MS` | `120000` | Total startup budget in milliseconds; range `1`–`600000` |

With `FOUNDRY_REST_API_KEY`, `FOUNDRY_PAIRING_CODE`, and `RELAY_PUBLIC_URL`
configured:

```sh
mkdir -p build/browser-profiles
export RELAY_CHROME=/path/to/google-chrome
export RELAY_BROWSER_PROFILES="$PWD/build/browser-profiles"
export RELAY_ALLOWED_ORIGINS='https://foundry.example.test'
foundry-relay
```

For a system Flatpak Chrome installation, set `RELAY_CHROME` to
`/var/lib/flatpak/exports/bin/com.google.Chrome` and preserve the desktop D-Bus
environment (`XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS`); without D-Bus
access, Flatpak can exit before creating the debugging endpoint.

Choose a profile parent accessible to the selected launcher. A Flatpak Chrome
launcher may not see the host's `/tmp`; an accessible directory under the
application checkout works instead. Keep the parent directory private to the
relay user: POSIX profiles are created privately, while Windows directory
privacy depends on the parent directory's NTFS ACL rather than POSIX mode bits.

Before starting a session:

1. Launch the intended world in Foundry and enable its REST API module.
2. Pair that world with this relay using the pairing-code flow. Its saved
   client ID and relay URL must match this relay.
3. Log out the full GM account (Foundry role `4`) that the headless session
   will use.
4. Include the exact Foundry origin in `RELAY_ALLOWED_ORIGINS`. Scheme,
   hostname, and non-default port are significant. The session URL must use
   `http` or `https` and contain no query string.

`x-world-name`, or the start body's `worldName`, identifies the existing
pairing by exact world ID or title among pairings for that Foundry origin.
Omitting it succeeds only when exactly one pairing matches that origin. The
relay resolves a title to its concrete world ID and verifies the loaded world
against that ID; it never creates or repairs pairings, edits world settings,
enters an administrator password, or selects a world from setup. The username
is the account's exact displayed name—on the join form, the relay selects that
name and submits its internal user ID, so an already active account cannot be
selected.

## Authenticate and start

All four endpoints require `x-api-key` and respond with
`Cache-Control: no-store`. Password encryption uses RSA-2048 OAEP with SHA-256
for both OAEP and MGF1, an empty label, and a SubjectPublicKeyInfo PEM public
key (`BEGIN PUBLIC KEY`). Encrypt the UTF-8 JSON object
`{"password":"...","nonce":"..."}` and send canonical padded standard Base64
(344 characters for a 256-byte ciphertext). The complete JSON plaintext must
fit in 190 bytes, counting UTF-8 bytes and JSON escaping; an empty Foundry
password is valid. This matches the
[pinned upstream handler](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/handler/session.go).

| Method and path | Inputs | Successful response |
| --- | --- | --- |
| `POST /session-handshake` | Headers `x-foundry-url`, `x-username`; optional `x-world-name` | `token`, `publicKey`, `nonce`, `instanceId`, `foundryUrl`, `username`, `expires` |
| `POST /start-session` | JSON `handshakeToken`, `encryptedPassword`; optional `worldName` override | `{"success":true,"sessionId":"...","clientId":"..."}` |
| `GET /session` | No extra inputs | `{"activeSessions":[...]}` |
| `DELETE /end-session?sessionId=...` | `sessionId` in query, or JSON `sessionId` when query is absent or empty | `{"status":"ok","message":"Session ended"}` |

Each handshake header may appear at most once. `x-foundry-url` is capped at
4,096 bytes, `x-username` at 1–256 bytes, and `x-world-name` at 256 bytes.

When enabled, the session manager generates one ephemeral RSA-2048 key at
startup and reuses that public key until shutdown. Each handshake carries its
own random token and nonce, expires after five minutes, and allows exactly one
start attempt; any failed decode, decrypt, nonce check, or startup consumes the
handshake, so request a fresh one before retrying. At most 32 unexpired
handshakes are retained. Neither private keys nor passwords enter SQLite;
runtime strings are garbage collected without claiming secure heap erasure.

`captureBrowserConsole` is unsupported: omit it or pass an empty string, or the
relay returns 400. Browser console messages, screenshots, page contents, and
authentication payloads never appear in relay logs.

Use HTTPS over a [reverse proxy](configuration.md#reverse-proxy-and-origins)
whenever REST traffic crosses a network: password encryption protects only the
Foundry password, not the API key or other request fields in transit.

### Node client example

Save this as an `.mjs` file and run it with a Node version that provides
`fetch`. Supply `FOUNDRY_URL`, `FOUNDRY_USERNAME`, `FOUNDRY_PASSWORD`, and
`FOUNDRY_REST_API_KEY` in the environment, and optionally `FOUNDRY_WORLD` and
`RELAY_API_URL`. The script runs a read-only `world-info` request and ends its
session in `finally`:

```js
import { constants, publicEncrypt } from 'node:crypto';

const base = (process.env.RELAY_API_URL ?? 'http://127.0.0.1:3010').replace(/\/$/, '');
const key = process.env.FOUNDRY_REST_API_KEY;
const foundryUrl = process.env.FOUNDRY_URL;
const username = process.env.FOUNDRY_USERNAME;
const password = process.env.FOUNDRY_PASSWORD;
if (!key || !foundryUrl || !username || password === undefined) {
  throw new Error('Required client environment variables are missing');
}

async function request(path, method = 'GET', body, extraHeaders = {}) {
  const response = await fetch(base + path, {
    method,
    headers: {
      'x-api-key': key,
      ...(body === undefined ? {} : { 'content-type': 'application/json' }),
      ...extraHeaders,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`Relay returned HTTP ${response.status}`);
  return response.json();
}

const headers = { 'x-foundry-url': foundryUrl, 'x-username': username };
if (process.env.FOUNDRY_WORLD) headers['x-world-name'] = process.env.FOUNDRY_WORLD;
const handshake = await request('/session-handshake', 'POST', undefined, headers);
const plaintext = Buffer.from(JSON.stringify({ password, nonce: handshake.nonce }), 'utf8');
if (plaintext.length > 190) throw new Error('Encrypted credential payload is too large');
const encryptedPassword = publicEncrypt({
  key: handshake.publicKey,
  padding: constants.RSA_PKCS1_OAEP_PADDING,
  oaepHash: 'sha256',
}, plaintext).toString('base64');
const session = await request('/start-session', 'POST', {
  handshakeToken: handshake.token,
  encryptedPassword,
});
try {
  await request('/world-info?clientId=' + encodeURIComponent(session.clientId));
  console.log('Headless Foundry session answered world-info');
} finally {
  await request('/end-session?sessionId=' + encodeURIComponent(session.sessionId), 'DELETE');
}
```

Node's `oaepHash` selects the OAEP and MGF1 hash together; omitting `oaepLabel`
selects the empty label (see the
[Node crypto API](https://nodejs.org/api/crypto.html#cryptopublicencryptkey-buffer)).
With Python's `cryptography` library, the equivalent encryption expression is:

```python
import base64
import json
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

public_key = serialization.load_pem_public_key(handshake["publicKey"].encode("ascii"))
plaintext = json.dumps({"password": password, "nonce": handshake["nonce"]},
                       separators=(",", ":"), ensure_ascii=False).encode("utf-8")
if len(plaintext) > 190:
    raise ValueError("Encrypted credential payload is too large")
encrypted_password = base64.b64encode(public_key.encrypt(
    plaintext, padding.OAEP(mgf=padding.MGF1(hashes.SHA256()),
                            algorithm=hashes.SHA256(), label=None)
)).decode("ascii")
```

Here `handshake` is the decoded handshake response and `password` is supplied
by the caller (see the
[cryptography RSA guide](https://cryptography.io/en/latest/hazmat/primitives/asymmetric/rsa/#encryption)).

## Lifetime and failures

Each admitted session owns one browser process, a disposable private profile,
and an off-the-record browser context keeping cookies and storage in memory.
CDP listens on a random loopback port. The relay passes no flags disabling
sandboxing, certificate verification, or proxy settings, and Foundry's own
authentication remains in force. The browser inherits desktop integration
variables while receiving empty `FOUNDRY_REST_API_KEY` and
`FOUNDRY_PAIRING_CODE` environment values.

The browser publishes its CDP endpoint in the profile's `DevToolsActivePort`
file. On Windows the file can appear while the browser holds an exclusive write
handle, so only an `EBUSY` open error counts as not ready; other errors fail
startup.

Startup must finish browser initialization, navigation, GM login,
world/module/pairing verification, relay authentication, and a `world-info`
reply within `RELAY_SESSION_TIMEOUT_MS`, and the page and captured relay
connection must remain authenticated and owned after that reply. Browser
retirement uses a separate cleanup allowance outside the startup budget.

A paired world is reserved synchronously before its browser starts, preventing
concurrent starts for the same client. A world that is already connected or has
an admitted session returns 409, and an external module connection arriving
during startup fails that startup. External browsers holding the same pairing
token follow ordinary reconnect replacement; ownership checks then reject or
retire the headless session.

Sessions remain manager-owned while the HTTP handler waits. If a caller
disconnects during startup and response publication fails, the unpublished
session is cancelled and retired. Published active sessions appear in
`GET /session` and are polled every second, retiring automatically if the page
or captured relay connection disconnects.

`GET /session` entries contain `sessionId`, `clientId`, `foundryUrl`,
`username`, `worldName` (the resolved world ID), `startedAt`, `lastActivity`,
and six world/system fields: `worldId`, `worldTitle`, `foundryVersion`,
`systemId`, `systemTitle`, and `systemVersion`. Timestamps are Unix epoch
milliseconds at one-second resolution; both record admission (`lastActivity` is
not updated by REST traffic and does not trigger an inactivity timeout).

Ending a session cancels its monitor, closes the browser, reaps the process,
deletes the disposable profile, and closes its captured relay connection
(returning 503 to requests pending on that connection while preserving any
later replacement connection). Server shutdown does the same before closing
shared relay resources. Ordinary stop and failed startup preserve the stored
pairing token. If retirement cannot be proved, the manager logs
`headless_session_cleanup_failed` and retains the reservation: ending that
session returns 503 and starting the same world returns 409.

HTTP status codes across the four endpoints: `400` for malformed inputs,
expired/invalid handshakes, bad ciphertext, unsupported `captureBrowserConsole`,
or missing/ambiguous pairings; `401` for a nonce mismatch or invalid API key;
`403` for a disallowed Foundry origin; `404` for an unknown `sessionId`; `408`
for an expired startup deadline; `409` for a world already connected or
admitted; `413` for a request body exceeding 16 MiB; `429` at the 32-handshake
or `RELAY_MAX_SESSIONS` limit; `500` for other startup failures; and `503` when
session creation is disabled, the server is closing, or cleanup failed
(`GET /session` returns an empty list when creation is disabled).

Startup failures log `headless_session_failed` (`reason: "startup_failed"`)
with `client_id`, `elapsed_ms`, and fixed `stage`/`cause` categories—omitting
browser output, raw OS errors, profile paths, credentials, and handshake data
(runtime disconnects log `headless_session_failed` with
`reason: "connection_lost"`):

| `stage` | `cause` values |
| --- | --- |
| `browser_profile` | `profile_parent_missing`, `profile_parent_not_directory`, `profile_parent_permission_denied`, `profile_parent_unavailable`, `profile_creation_failed` |
| `browser_startup` | `deadline_expired`, `browser_exited`, `invalid_debugging_endpoint`, `startup_failed` |
| `browser_protocol` | `deadline_expired` |
| `foundry_readiness` | `deadline_expired`, `pairing_mismatch`, `wrong_world`, `wrong_user`, `administrator_login_required`, `setup_or_module_required` |
| `startup` | `startup_failed` |

Relative `RELAY_BROWSER_PROFILES` paths resolve from the relay's working
directory; create the directory before starting a session. If Foundry shows its
administrator screen (`administrator_login_required`), sign in to Foundry's
administration interface and launch the world before retrying with a fresh
handshake.

Sessions, handshakes, and RSA keys exist only in memory; restarts never resume
sessions or replay handshakes, while SQLite retains ordinary world pairings
independently.
