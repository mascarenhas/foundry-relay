# Headless Foundry sessions

The relay can own a Chrome instance that logs in to an already running Foundry
world and keeps its REST API module connected. The four authenticated endpoints
follow the [upstream session API](https://foundryrestapi.com/docs/api/session).
This implementation requires an existing pairing and does not launch worlds
through Foundry's administration screen. See the [REST catalog](api.md) and
[operator setup](../README.md) for the ordinary relay configuration.

## Enable sessions

Configure the ordinary relay executable. Leave `RELAY_CHROME` unset to disable session
creation. Chrome remains a separate installed dependency, controlled by native
Titan CDP; the relay does not invoke Node, Python, or the Titan compiler.

| Variable | Default | Meaning |
| --- | --- | --- |
| `RELAY_CHROME` | empty, disabled | Chrome/Chromium executable or launcher path |
| `RELAY_BROWSER_PROFILES` | `build/browser-profiles` | Existing parent directory for disposable private profiles |
| `RELAY_MAX_SESSIONS` | `4` | Maximum admitted sessions, including startup and retirement; range 1–64 |
| `RELAY_SESSION_TIMEOUT_MS` | `120000` | Total startup budget; range 1–600000 milliseconds |

For example, after the ordinary API key, pairing code, and relay URL have been
configured:

```sh
mkdir -p build/browser-profiles
export RELAY_CHROME=/path/to/google-chrome
export RELAY_BROWSER_PROFILES="$PWD/build/browser-profiles"
export RELAY_ALLOWED_ORIGINS='https://foundry.example.test'
./build/foundry-relay
```

For a system Flatpak Chrome installation, the launcher can be
`/var/lib/flatpak/exports/bin/com.google.Chrome`.

Use a profile parent accessible to the selected launcher. A Flatpak Chrome
launcher may not see the host's `/tmp`; an accessible directory under the
application checkout can be used instead. Keep this parent private to the relay
user. POSIX profiles are created privately; Windows directory privacy depends on
the parent directory's ACL rather than POSIX mode bits.

Before starting a session:

1. Launch the intended world in Foundry and enable its REST API module.
2. Pair that world with this relay using the existing pairing-code flow. Its
   saved client identity and relay URL must still match this relay.
3. Log out the full GM account that the headless session will use. The supplied
   username must identify that account, with Foundry role 4.
4. Include the exact Foundry origin in `RELAY_ALLOWED_ORIGINS`. Scheme, hostname,
   and non-default port are significant. The session URL must use HTTP or HTTPS
   and must not contain a query string.

`x-world-name` may identify the existing pairing by exact world ID or title.
Omitting it succeeds only when exactly one existing pairing matches the Foundry
origin. The relay resolves a title to its concrete world ID and validates the
loaded world against that ID. It does not create or repair a pairing, change
world settings, enter an administrator password, or select a world from setup.

## Authenticate and start

All four endpoints require the ordinary `x-api-key` header. Password encryption
uses RSA-2048 OAEP with SHA-256 for both OAEP and MGF1, an empty label, and a
SubjectPublicKeyInfo PEM public key (`BEGIN PUBLIC KEY`). Encrypt the UTF-8 JSON
object `{"password":"...","nonce":"..."}` and send standard padded Base64.
The complete JSON plaintext must fit in 190 bytes; this limit counts UTF-8 and
JSON escaping, not password characters. An empty Foundry password is valid.
This is the same format accepted by the
[pinned upstream handler](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/handler/session.go).

| Method and path | Inputs | Successful response |
| --- | --- | --- |
| `POST /session-handshake` | Headers `x-foundry-url`, `x-username`; optional `x-world-name` | `token`, `publicKey`, `nonce`, `instanceId`, `foundryUrl`, `username`, `expires` |
| `POST /start-session` | JSON `handshakeToken`, `encryptedPassword`; optional `worldName` override | `{"success":true,"sessionId":"...","clientId":"..."}` |
| `GET /session` | No extra inputs | `{"activeSessions":[...]}` |
| `DELETE /end-session?sessionId=...` | Session ID in the query, or JSON `sessionId` when the query is absent | `{"status":"ok","message":"Session ended"}` |

The relay creates one ephemeral RSA key when its enabled session manager starts
and reuses that public key until shutdown. Each handshake has its own random
token and nonce, expires after five minutes, and permits exactly one start
attempt. A failed decode, decrypt, nonce check, or startup consumes the handshake;
request a new one before retrying. At most 32 unexpired handshakes are retained.
Neither private keys nor passwords are written to SQLite. Runtime strings are
garbage collected; the relay does not claim secure erasure of their contents.

`captureBrowserConsole` is unsupported: omit it or pass an empty string. A
nonempty value returns 400. Browser console messages, screenshots, page contents,
and authentication payloads are not written to relay logs.

Use HTTPS for the REST connection when it crosses a network. Password encryption
does not protect the API key or other request fields in transit, and the existing
reverse proxy remains responsible for REST TLS.

### Node client example

Save this as an `.mjs` file and run it with a Node version that provides `fetch`.
The example reads credentials from its environment, performs a read-only world
request, and ends its session in `finally`. These client variables do not add
configuration-file dependencies to the relay. Supply `FOUNDRY_URL`,
`FOUNDRY_USERNAME`, `FOUNDRY_PASSWORD`, and `FOUNDRY_REST_API_KEY`; optionally set
`FOUNDRY_WORLD` and `RELAY_API_URL`.

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
selects the empty label. See the
[Node crypto API](https://nodejs.org/api/crypto.html#cryptopublicencryptkey-buffer).
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

Here `handshake` is the decoded handshake response and `password` is supplied by
the caller. See the [cryptography RSA guide](https://cryptography.io/en/latest/hazmat/primitives/asymmetric/rsa/#encryption).

## Lifetime and failures

Each admitted session owns one sandboxed Chrome process, a separate disposable
profile, and an off-the-record browser context. Cookies and client storage stay
in memory in that context. CDP listens on a random loopback port; sandboxing,
certificate verification, proxy settings, and Foundry's existing authentication
remain enabled. The Chrome child inherits desktop integration variables but
receives empty relay API-key and pairing-code environment values.

Startup must complete browser initialization, navigation, GM login, world/module/
pairing checks, relay authentication, and a `world-info` reply within the total
startup budget. The page must still be authenticated and the same Hub connection
must still own the client slot after that reply. Browser retirement has its own
additional cleanup allowance; the startup timeout is not a total HTTP-response
deadline including cleanup.

The manager reserves a client before starting its controller, so two API starts
cannot launch the same paired world concurrently. An already connected world
returns 409. An external browser with the same existing pairing credential still
uses the relay's normal reconnect behavior and can replace a connection during
startup or later. Ownership checks then reject or retire the headless session;
reusing that credential does not establish exclusive admission against external
browsers.

Sessions remain manager-owned while an HTTP handler waits. A disconnected caller
may not be noticed until startup completes and response writing fails. Failed
response publication cancels and retires the unpublished session. Successfully
published sessions are discoverable through `GET /session`; they are monitored
and retired when the page or captured relay connection disconnects.

List entries contain `sessionId`, `clientId`, `foundryUrl`, `username`, `worldName`,
`startedAt`, `lastActivity`, and six world/system metadata fields: `worldId`,
`worldTitle`, `foundryVersion`, `systemId`, `systemTitle`, and `systemVersion`.
`worldName` is the resolved world ID. Times are Unix epoch milliseconds with
one-second clock resolution; currently both timestamps record admission, and
`lastActivity` does not measure REST traffic or implement an inactivity timeout.
Only published active sessions appear in this list.

Ending a session cancels and awaits its controller, closes the owned browser,
reaps its child, and removes its owned profile. Shutdown does the same before
closing shared relay resources. Ordinary stop and failed startup preserve the
existing pairing token. If retirement fails, the manager logs a static cleanup
error and retains the reservation; ending that session returns 503 and another
start for the same world remains blocked. Unknown session IDs return 404.
Malformed inputs return 400, a nonce mismatch returns 401, disallowed Foundry
origins return 403, capacity limits return 429, startup failure returns 408, and
disabled session creation returns 503. Listing still returns an empty list when
creation is disabled.

Sessions, handshakes, and RSA keys exist only in memory. Restart does not resume
sessions, replay handshakes, load `.world`, or retrieve stored Foundry passwords.
SQLite retains ordinary world pairings independently of this lifecycle.

## Validation boundaries

The Linux session implementation passed all four endpoints against a live HTTPS
Foundry world, including read-only world requests, a fresh session after ending
the first, and SIGTERM retirement. After the Windows endpoint-file fix, the Linux
native suite passed 327 cases with one Windows-only fixture skipped, including
independent crypto interoperability, lifecycle races, loopback HTTP/CDP fixtures,
and real Chrome retirement. See the [session validation record](session-validation.md)
for the tested SDK, browser, platform boundaries, and Windows results.
