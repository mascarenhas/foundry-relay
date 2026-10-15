# Foundry relay in Titan

A single-user REST-to-WebSocket relay for the Foundry VTT REST API module. It implements the core protocol of [ThreeHats' Go relay](https://github.com/ThreeHats/foundryvtt-rest-api-relay/tree/main/go-relay), with SQLite persistence, an environment API key, and optional headless sessions through the same server's REST API. There is no dashboard, account system, billing, or Redis.

The server and tests are Titan. On POSIX, application modules and the Titan standard provider are linked into the native executable with `--static`. Windows uses an EXE launcher and application DLL with Titan DLL dependencies. The server does not invoke or depend on the Titan compiler at runtime.

## Build and test

Use a prepared Titan installation containing `http`, `websocket`, `sqlite3`, `json`, and `peg`, including HTTP `Response:abort()`, the compiled `titan.test.Case`/`run` API, and `--output` support from [Titan PR #236](https://github.com/mascarenhas/titan/pull/236). GNU Make 4.3 or newer is required for grouped module outputs. [TITAN_REVISION](TITAN_REVISION) pins that producer commit for the production line-coverage workflow. Earlier Linux x86_64 and local Windows x64 validation used commit `4987078d`; those historical checks are recorded in [validation](docs/validation.md).

```sh
export PATH=/path/to/titan-prefix/bin:$PATH
make
make test
make test TEST_ARGS="--filter='^tests[.]integration_test'"
```

The POSIX build defaults to `OPENSSL_MODE=system`, matching Titan's default SDK.
Install OpenSSL 3.0 or newer development files and `pkg-config`; the build adds
`pkg-config --cflags --libs openssl` to the corresponding compiler and linker
inputs while preserving caller-supplied `TITAN_EXTRA_CPPFLAGS` and
`TITAN_EXTRA_LDFLAGS`. Set `PKG_CONFIG=/path/to/pkg-config` if needed. The
resulting executable embeds Titan's standard provider and uses the system
OpenSSL libraries at runtime.

When the installed Titan SDK was built with bundled OpenSSL, use
`make OPENSSL_MODE=bundled` and `make test OPENSSL_MODE=bundled`. This mode uses
the OpenSSL objects already carried by the SDK and does not invoke `pkg-config`.
`OPENSSL_MODE` must match the installed SDK; it does not rebuild or reconfigure
that SDK.

`build/foundry-relay` is the server. `build/relay-tests` is one native `titan.test` runner containing routing, storage, API, protocol, integration, and executable tests. All compiler-generated files live under `build`, preserving the source hierarchy. The application and tests share production module objects and the same compiled Titan standard provider. Builds compile authored sources directly without copying them.

Both phases use `--static --incremental --output build`. Make compiles changed modules separately with `-c`, then links the executable from current objects in that output tree. An unchanged `make` performs no compilation or linking. `make test` builds only missing or stale application/test outputs before running the suite. Only test-owner objects receive Titan's test traceback flag; production modules use the same flags in both images.

`Makefile.modules` records each module's project imports so an edited producer rebuilds its consumers before relinking. Keep it current when adding or renaming modules or changing imports. The build configuration stamp tracks source inventory and caller settings; compiler, SDK, selected provider, native tool, and OpenSSL files are ordinary Make prerequisites. SDK replacement and flag changes rebuild the shared objects. `make clean` removes `build`; legacy source-adjacent artifacts are left untouched.

`TITANC=/absolute/path/bin/titanc` selects a compiler and its SDK prefix. `TITAN_STDLIB=/absolute/path/lib/titan/0.6` overrides the standard-provider directory; the test command also supplies it to child fixtures through `TITAN_PATH_0_6`. Both ordinary POSIX executables embed the selected standard archive. On a restricted development host, set `CCACHE_DIR` to a writable location; `TITAN_PROBE_CACHE_DISABLE=1` is useful after a failed sandboxed native-header probe.

`make coverage` runs the full Titan suite with native executable-line coverage,
including the covered relay child launched by the process test. Titan produces
its summary and annotated report for each executable directly, retaining zero-hit
lines. No Python, gcovr, or relay-specific report processing is required.
See [the coverage workflow](docs/coverage.md) for the matching GCC/gcov requirement,
separate build/run targets, and native report locations.

## Run

Choose an API key and a six-character pairing code. The pairing code accepts ASCII letters and digits and is normalized to uppercase, matching the Foundry module's UI. It is reusable across worlds and authorizes pairing; treat it as a secret.

```sh
export FOUNDRY_REST_API_KEY='your-private-api-key'
export FOUNDRY_PAIRING_CODE='A4X9K2'
./build/foundry-relay
```

The default listener is `127.0.0.1:3010`. SQLite credentials and metadata live in `relay.sqlite3`, created with mode `0600` on POSIX. On Windows, place the database in a private directory protected by your user's ACL; POSIX mode bits do not establish equivalent Windows access control. The parent directory must exist. The process handles SIGINT and SIGTERM, closes its listener and world sessions, and retires owned Tasks.

| Variable | Default | Purpose |
| --- | --- | --- |
| `FOUNDRY_REST_API_KEY` | required | REST `x-api-key` credential |
| `FOUNDRY_PAIRING_CODE` | required | Reusable six-character pairing code |
| `RELAY_HOST` | `127.0.0.1` | Listener address |
| `RELAY_PORT` | `3010` | Listener port |
| `RELAY_DATABASE` | `relay.sqlite3` | SQLite database path |
| `RELAY_PUBLIC_URL` | `ws://127.0.0.1:$RELAY_PORT/relay` | WebSocket URL returned by pairing; set explicitly for a different hostname or proxy |
| `RELAY_ALLOWED_ORIGINS` | `http://127.0.0.1:30000,http://localhost:30000` | Comma-separated browser origins accepted for pairing, REST CORS, and WebSocket opening |
| `RELAY_REQUEST_TIMEOUT_MS` | route default | Override all forwarding deadlines; route defaults are usually 10 seconds, longer for file/image operations |
| `RELAY_AUTH_TIMEOUT_MS` | `10000` | First-message WebSocket authentication deadline |
| `RELAY_HEARTBEAT_MS` | `30000` | WebSocket Ping interval; Pong progress has a five-second deadline |
| `RELAY_MAX_PENDING` | `128` | Maximum pending REST requests per world |
| `RELAY_LOG_LEVEL` | `info` | JSON logging threshold: `error`, `info`, or `debug` |

Headless sessions are available in the same executable when `RELAY_CHROME` is
configured. Pair the already running world first, then use the authenticated
handshake/start/list/end API. See [session setup and client examples](docs/sessions.md)
for browser configuration, encrypted credentials, prerequisites, and cleanup.

Set an exact Foundry origin if using a different hostname or port. An absent Origin is accepted for native clients. Deploy behind an HTTPS/WSS reverse proxy when browser clients require TLS; configure its externally visible `/relay` URL and allow the exact Foundry browser origin. The relay does not trust forwarded headers or configure proxy TLS itself.

## Logs

Relay-generated logs write one JSON object per line to stderr. `RELAY_LOG_LEVEL` defaults
to `info`; values are case sensitive, and invalid values fail startup.

| Level | Events included |
| --- | --- |
| `error` | Configuration, listener, I/O, WebSocket protocol/transport and heartbeat failures; forwarding timeouts; headless browser startup, connection and cleanup failures |
| `info` | All errors, server startup/shutdown, HTTP request admission, successful pairing/revocation/removal, authenticated WebSocket connect/disconnect, and headless session lifecycle |
| `debug` | All info events, WebSocket message categories and byte counts, ignored/discarded messages, forwarding/results, heartbeat Ping/Pong, and subscription counts/overflow |

Every record contains `timestamp` (UTC, one-second resolution), `level`, and
`event`. Additional fields depend on the event, for example:

```json
{"event":"http_request","level":"info","method":"GET","route":"/world-info","timestamp":"2026-10-11T20:00:00Z"}
```

HTTP admission records cover requests reaching the Titan HTTP handler, including
authentication failures, unmatched routes, OPTIONS and long-lived SSE/upgrade
requests. They are emitted before dispatch. The `route` is a declared template
such as `/clients/:clientId`, or `<unmatched>` for unresolved targets. Requests
rejected by the underlying HTTP parser never reach this handler.

Logs omit headers, query values, route parameters, bodies, tokens, passwords,
world metadata, browser/CDP contents, arbitrary error text and peer Close
reasons. Message categories come from the known protocol catalog; unrecognized
types are recorded as `unknown`. Client IDs in lifecycle logs come from stored
pairings. Normal disconnect, reconnect replacement, unpair and shutdown are
lifecycle events.

Logging admission does not suspend request or connection owners. A writer drains
up to 1,024 queued records plus one in-flight record, with each JSON object
capped at 16 KiB.
Overflow and unencodable records are counted in an error-level `log_dropped`
record when the sink progresses. A failed sink disables further logging for that
process. Shutdown drains admitted records; a permanently stalled stderr sink
can delay that drain.

Low-level Titan runtime diagnostics outside relay handlers, such as an uncaught
HTTP parser/framing failure, retain the runtime's diagnostic format and are not
controlled by `RELAY_LOG_LEVEL`.

The current Titan standard-stream API supports terminals and pipes. To save
logs, pipe through a collector, for example
`./build/foundry-relay 2>&1 | tee relay.log`; direct stderr redirection to a
regular file is unsupported and disables the log sink.

## Pair a Foundry world

1. Open the Foundry world as a GM with the REST API module enabled.
2. Set the module relay URL to `ws://127.0.0.1:3010/relay` (or the configured public URL).
3. Choose **Enter Code** in the module connection dialog and enter your `FOUNDRY_PAIRING_CODE`. The default **Pair** button uses the upstream browser-approval flow, which this relay does not implement.
4. Repeat in additional worlds with the same code.

The module posts to `/auth/pair`; the relay returns a distinct `clientId` and cryptographically random token for each world/server identity. The module stores that token and sends it in its first WebSocket message, never in the URL. Credentials survive relay restarts. Re-pairing an existing world retains its identity and credential. Module self-unpair revokes its token while retaining the registered world; re-pairing then returns a fresh token.

```sh
curl -H "x-api-key: $FOUNDRY_REST_API_KEY" http://127.0.0.1:3010/clients
curl -H "x-api-key: $FOUNDRY_REST_API_KEY" \
  'http://127.0.0.1:3010/world-info?clientId=YOUR_CLIENT_ID'
```

Exactly one online world is selected automatically when `clientId` is omitted. Multiple online worlds require an explicit `clientId`. Offline worlds remain listed with `connected: false`; tokens are never included in the list. `DELETE /clients/:clientId`, authenticated with the API key, forgets a world and revokes its pairing.

See [the API catalog](docs/api.md) for all 91 forwarding declarations and [routing](docs/routing.md) for the project-local declarative router. REST replies preserve Foundry's response envelope. File downloads and screenshots can return binary data; `format=base64` retains their JSON form. Raw file uploads and JSON data-URL uploads are supported. Explicit JSON nulls survive forwarding.

The [upstream API audit](docs/api-audit.md) records remaining response, filter,
capacity, and transport gaps, plus the account and hosted-service features
intentionally omitted from this single-user relay.

Six authenticated SSE endpoints forward chat, roll, hook, combat, actor, and scene events. Each subscriber has a 128-event queue; a slow subscriber is retired when it fills. Streams send a 15-second keepalive and keep their subscription across a world reconnect. Foundry receives per-channel subscriber counts so it can enable and disable its hooks. Stream data is the inner Foundry event data; event names follow the corresponding channel and `eventType`. Upstream's per-subscriber event filters and consumer `/ws/api` transport are outside this implementation.

The relay serializes output per world, correlates replies by world, action, and request ID, and permits concurrent REST requests. A forwarding deadline returns `408`; a world disconnect settles pending requests with `503`. A timed-out request may already have reached Foundry and performed a mutation; the relay does not retry it. The output queue is bounded, while Titan's underlying network receive buffering retains its current stdlib behavior. Failed HTTP responses are aborted, including disconnected SSE streams. Shutdown does not currently track and abort every accepted HTTP exchange, so it is not guaranteed to be bounded if a client permanently stalls while sending a request body or reading a response. The HTTP idle deadline covers waiting for the next request headers.

## Windows build

Use an experimentally supported native x64 Titan Windows SDK with the WebSocket module and compiled `titan.test.Case`/`run` API. From an MSYS2 CLANG64 shell, build in a separate local NTFS checkout with an absolute SDK prefix:

```sh
make -f Makefile.windows PREFIX=/c/Titan/sdk
make -f Makefile.windows test PREFIX=/c/Titan/sdk
```

Windows builds use a launcher EXE and application DLL. The application payload is `build/windows/app`: run `bin/foundry-relay.exe` and retain the entire `bin`, `lib`, and license layout. Its six runtime DLLs live beside the EXE; `lib/titan/0.6` contains the application and Titan standard providers. The payload contains no Titan compiler. The build copies runtime files from the SDK and does not modify that SDK. Application and test links use `--incremental --output` and share the generated objects under `build/windows/out`, with module dependencies and SDK/settings invalidation as on POSIX. Final compiler outputs are copied into the application and test payloads. Use a separate local NTFS checkout for native Windows validation.

The Windows test target compiles routing, storage, API, protocol, integration,
CDP, browser, and session tests into a native Titan runner. The POSIX database
mode and shell-child fixtures are separately skipped. Independent-client crypto
tests use the OpenSSL CLI selected by `RELAY_TEST_OPENSSL`; production sessions
call OpenSSL directly. The target also audits every shipped PE image for
unexpected imports and runs a relocated application from ordinary PowerShell
with MSYS2, LLVM, and SDK paths removed from the child environment. The Unix
executable test exercises static linkage and SIGTERM behavior separately.
PowerShell script execution must be permitted by local policy; the target does
not change that policy.

## Provenance

Route and wire-protocol compatibility was researched from the upstream Go relay at `65ce83d6a534ea6d340c8a89d72251f4c6a0294e` and the locally installed Foundry module's source map. [Third-party notices](THIRD_PARTY_NOTICES.md) preserve the upstream MIT notice. The router's PEG design follows the route parser approach in [mk/routes.lua](https://github.com/mascarenhas/mk/blob/master/src/mk/routes.lua).
