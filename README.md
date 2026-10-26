# Foundry relay in Titan

A single-user REST-to-WebSocket relay for the Foundry VTT REST API module. It implements the core protocol of [ThreeHats' Go relay](https://github.com/ThreeHats/foundryvtt-rest-api-relay/tree/main/go-relay), with SQLite persistence, an environment API key, and optional headless sessions through the same server's REST API. There is no dashboard, account system, billing, or Redis.

The server and tests are Titan. On POSIX, application modules and the Titan standard provider are linked into the native executable with `--static`. Windows uses an EXE launcher and application DLL with Titan DLL dependencies. The server does not invoke or depend on the Titan compiler at runtime.

## Build and test

Use a prepared Titan installation containing `thread`, `http`, `websocket`, `sqlite3`, `json`, and `peg`, including channel endpoint transfer, portable demand reads, HTTP exchange transfer/disposal, and `Exchange:serve` header deadlines. The compiled `titan.test.Case`/`run` API, HTTP `Response:abort()`, compiler-owned incremental builds, native input switches, `--output`, `--exe`, and `--test-dir`/`--test-exclude` support are also required. `Makefile` builds on Linux and macOS; Windows uses [`Makefile.windows`](#windows-build). Builds and native coverage use `titanc` from `PATH`, without pinning a Titan source revision. Prepend another installation's `bin` directory to `PATH` to select its compiler and matching standard library.

```sh
export PATH=/path/to/titan-prefix/bin:$PATH
make
make test
make test TEST_ARGS="--filter='^tests[.]integration_test'"
```

The POSIX build defaults to `OPENSSL_MODE=system`, matching Titan's default SDK.
Install OpenSSL 3.0 or newer development files and `pkg-config`; the build adds
`pkg-config --cflags --libs openssl` as explicit `titanc` native switches.
Caller-supplied `TITAN_EXTRA_CPPFLAGS`, `TITAN_EXTRA_CFLAGS`, and
`TITAN_EXTRA_LDFLAGS` remain ambient compiler inputs. Set `PKG_CONFIG=/path/to/pkg-config` if needed. The
resulting executable embeds Titan's standard provider and uses the system
OpenSSL libraries at runtime.

When the installed Titan SDK was built with bundled OpenSSL, use
`make OPENSSL_MODE=bundled` and `make test OPENSSL_MODE=bundled`. This mode uses
the OpenSSL objects already carried by the SDK and does not invoke `pkg-config`.
`OPENSSL_MODE` must match the installed SDK; it does not rebuild or reconfigure
that SDK.

`build/foundry-relay` is the server. `build/relay-tests` is one native `titan.test` runner selected with `--tree . --test-dir tests`, including every `tests/*_test.titan` module. All compiler-generated files live under `build`, preserving the source hierarchy, and builds compile authored sources in place.

Both images use `--static --incremental --output build`, with `--exe` selecting their final paths. Make always invokes `titanc` for each requested image; the compiler owns import discovery, dependency scheduling, object certification, and final-link reuse. An unchanged build compiles and links nothing. The application and runner share unchanged production objects and the compiled Titan standard provider. There is no project module graph or configuration stamp to maintain when adding sources, changing imports, or updating the SDK or native flags. `make clean` removes `build`.

`TITANC=/absolute/path/bin/titanc` selects a compiler and its SDK prefix. `TITAN_STDLIB=/absolute/path/lib/titan/0.6` overrides the standard-provider directory; the test command also supplies it to child fixtures through `TITAN_PATH_0_6`. `TITAN_JOBS` (default 2) bounds compiler workers and native compilation inside each `titanc` call. On a restricted development host, set `CCACHE_DIR` to a writable location; `TITAN_PROBE_CACHE_DISABLE=1` keeps persistent native-header probes from writing to an immutable SDK and is also useful after a failed sandboxed probe.

`make test` runs the suite under `timeout 300s` by default and passes `TEST_ARGS` to the runner. `TEST_TIMEOUT=<seconds>` overrides the POSIX test and coverage execution budget, including optional installed-Chromium checks. Both need a `timeout` command on `PATH`, such as GNU coreutils'; macOS does not ship one. It sets `RELAY_TEST_EXECUTABLE`, so `tests/process_test.titan` can run a relocated copy of the server without the compiler or Titan provider on its search paths and stop it with SIGTERM. Optional capabilities enable more cases:

| Variable | Effect |
| --- | --- |
| `RELAY_TEST_CHROME` and `RELAY_TEST_BROWSER_PROFILES` | Run the installed-browser lifecycle and Foundry login/readiness DOM cases; both must be set |
| `RELAY_TEST_OPENSSL` | OpenSSL CLI for the independent-client crypto cases; default `openssl`, skipped when it is missing |

POSIX runs skip the Windows exclusive-file-sharing case. Windows runs skip the POSIX permission-bit and fake-child browser cases. The SQLite contention case skips when `UV_THREADPOOL_SIZE` is set to anything other than 4.

`make coverage` runs the full suite with Titan's native executable-line coverage; see [the coverage workflow](docs/coverage.md).

## Run

Choose an API key and a six-character pairing code. The pairing code accepts ASCII letters and digits; the relay uppercases it, matching the Foundry module's code entry, and compares submitted codes exactly. It is reusable across worlds and authorizes pairing; treat it as a secret.

```sh
export FOUNDRY_REST_API_KEY='your-private-api-key'
export FOUNDRY_PAIRING_CODE='A4X9K2'
./build/foundry-relay
```

The default listener is `127.0.0.1:3010`. SQLite credentials and metadata live in `relay.sqlite3`, restricted to mode `0600` on POSIX. On Windows, place the database in a private directory protected by your user's ACL; POSIX mode bits do not establish equivalent Windows access control. The parent directory must exist. The process handles SIGINT and SIGTERM, closes its listener and world sessions, and retires owned Tasks.

| Variable | Default | Purpose |
| --- | --- | --- |
| `FOUNDRY_REST_API_KEY` | required | REST `x-api-key` credential |
| `FOUNDRY_PAIRING_CODE` | required | Reusable six-character pairing code |
| `RELAY_HOST` | `127.0.0.1` | Listener address |
| `RELAY_PORT` | `3010` | Listener port, at most 65535 |
| `RELAY_DATABASE` | `relay.sqlite3` | SQLite database path |
| `RELAY_PUBLIC_URL` | `ws://127.0.0.1:$RELAY_PORT/relay` | WebSocket URL returned by pairing; an absolute `ws://` or `wss://` URL whose path is `/relay`, without a query. Set it explicitly for a different hostname or proxy |
| `RELAY_ALLOWED_ORIGINS` | `http://127.0.0.1:30000,http://localhost:30000` | Comma-separated exact browser origins accepted for HTTP requests and WebSocket openings, and the Foundry origins allowed for headless sessions |
| `RELAY_REQUEST_TIMEOUT_MS` | route default | Override every forwarding deadline, at most 3600000; route defaults are 10 seconds or longer |
| `RELAY_AUTH_TIMEOUT_MS` | `10000` | First-message WebSocket authentication deadline, at most 60000 |
| `RELAY_HEARTBEAT_MS` | `30000` | WebSocket Ping interval, at most 3600000; each Ping has a five-second deadline |
| `RELAY_MAX_PENDING` | `128` | Maximum pending REST requests per world, at most 10000 |
| `RELAY_API_CONCURRENCY` | `1` | Number of API worker OS threads; requests use round-robin dispatch |
| `RELAY_LOG_LEVEL` | `info` | JSON logging threshold: `error`, `info`, or `debug` |

Numeric settings must be positive integers. An invalid value for any of these settings stops startup with exit status 1 before the database or listener opens. The headless session variables, listed in [sessions](docs/sessions.md#enable-sessions), are checked after the database opens and before the listener does.

[Threading](docs/threading.md) describes the API worker and world threads and how they own requests.

Headless sessions are available in the same executable when `RELAY_CHROME` is
configured. Pair the already running world first, then use the authenticated
handshake/start/list/end API. See [session setup and client examples](docs/sessions.md)
for browser configuration, encrypted credentials, prerequisites, and cleanup.

Set an exact Foundry origin if using a different hostname or port. Requests without an `Origin` header, such as those from native clients, are accepted; the [API request rules](docs/api.md#request-rules) give the complete check. Deploy behind an HTTPS/WSS reverse proxy when browser clients require TLS; configure its externally visible `/relay` URL and allow the exact Foundry browser origin. The relay does not trust forwarded headers or configure proxy TLS itself.

The relay bounds its per-world output queue; inbound network buffering follows Titan's standard library. Shutdown cancels and joins the Tasks serving adopted HTTP exchanges but does not abort their transports, so it is not guaranteed to be bounded if a client permanently stalls while sending a request body or reading a response.

## Logs

Relay-generated logs write one JSON object per line to stderr. `RELAY_LOG_LEVEL` defaults
to `info`; values are case sensitive, and invalid values fail startup.

| Level | Events included |
| --- | --- |
| `error` | Configuration, listener, I/O, WebSocket protocol/transport and heartbeat failures; forwarding timeouts; headless browser startup, connection and cleanup failures |
| `info` | All errors, server startup/shutdown, HTTP request admission, successful pairing/revocation/removal, rejected WebSocket authentication, authenticated WebSocket connect/disconnect, and headless session lifecycle |
| `debug` | All info events, WebSocket message categories and byte counts, ignored/discarded messages, forwarding/results, heartbeat Ping/Pong, reconnect replacement, and subscription counts |

Every record contains `timestamp` (UTC, one-second resolution), `level`, and
`event`. Additional fields depend on the event, for example:

```json
{"event":"http_request","level":"info","method":"GET","route":"/world-info","timestamp":"2026-10-11T20:00:00Z"}
```

HTTP admission records cover requests reaching the Titan HTTP handler, including
authentication failures, unmatched routes, OPTIONS and long-lived SSE/upgrade
requests. They are emitted before dispatch. The `route` is a declared template
such as `/clients/:clientId`, or `<unmatched>` for unresolved targets;
unrecognized methods are recorded as `OTHER`. Requests rejected by the
underlying HTTP parser never reach this handler.

Logs omit headers, query values, route parameters, bodies, tokens, passwords,
world metadata, browser/CDP contents, arbitrary error text and peer Close
reasons. Message categories come from the known protocol catalog; unrecognized
types are recorded as `unknown`. Client IDs in lifecycle logs come from stored
pairings. Normal disconnect, reconnect replacement, unpair and shutdown are
lifecycle events.

A forwarded request returning HTTP 408 emits one `request_timeout` event,
regardless of whether the caller's deadline or the world worker's deadline wins.

Logging admission does not suspend request or connection owners. A writer drains
up to 1,024 queued records plus one in-flight record, with each JSON object
capped at 16 KiB. Worker threads forward their records to this writer.
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

Each world receives its own client ID and token, and credentials survive relay restarts. The [API](docs/api.md#pairing-and-the-module-connection) specifies pairing, the module connection, re-pairing, and revocation.

```sh
curl -H "x-api-key: $FOUNDRY_REST_API_KEY" http://127.0.0.1:3010/clients
curl -H "x-api-key: $FOUNDRY_REST_API_KEY" \
  'http://127.0.0.1:3010/world-info?clientId=YOUR_CLIENT_ID'
```

Pass `clientId` when more than one world is online; the [request rules](docs/api.md#request-rules) describe world selection, and the [client list](docs/api.md#client-list) includes offline worlds.

[The API](docs/api.md) documents all 91 forwarding routes, the local routes, the six event streams, deadlines and failure statuses, and the differences from the upstream relay. [Routing](docs/routing.md) describes the project-local declarative router.

## Windows build

Use an experimentally supported native x64 Titan Windows SDK with the WebSocket module and compiled `titan.test.Case`/`run` API. From an MSYS2 CLANG64 shell, build in a separate local NTFS checkout with an absolute SDK prefix:

```sh
make -f Makefile.windows PREFIX=/c/Titan/sdk
make -f Makefile.windows test PREFIX=/c/Titan/sdk
```

Windows builds use a launcher EXE and application DLL. The application payload is `build/windows/app`: run `bin/foundry-relay.exe` and retain the entire `bin`, `lib`, and license layout. Its six runtime DLLs live beside the EXE; `lib/titan/0.6` contains the application and Titan standard providers. The payload contains no Titan compiler. The build copies runtime files from the SDK and does not modify that SDK. Application and test builds always invoke `titanc --incremental --output`, sharing compiler-certified objects under `build/windows/out`. `--exe` selects the two launchers under that tree's `bin`; the launchers and providers are then copied into the application and test payloads. Test roots are discovered with `--test-dir tests --test-exclude tests.process_test`; the explicit `tests.router_test` root preserves the packaged test provider's identity.

The Windows test runner contains every test module except `tests/process_test.titan`. The test target runs `scripts/check-windows.ps1`, which audits every shipped PE image for unexpected regular or delay-loaded imports. It then copies the application to a Unicode path on local NTFS and runs it from another working directory, with `PATH` reduced to the Windows system directories and the Lua and Titan search variables removed. The script checks health, pairing, authenticated client listing, and credential-free JSON logs, then ends the application with `Process.Kill`; server shutdown is covered by the native tests instead. Finally it runs the native suite, passing `RELAY_TEST_OPENSSL` and `RELAY_TEST_CHROME` through and placing browser profiles in its scratch directory. Production sessions call OpenSSL directly. PowerShell script execution must be permitted by local policy; the target does not change that policy.

## Provenance

Route and wire-protocol compatibility was researched from the upstream Go relay at `65ce83d6a534ea6d340c8a89d72251f4c6a0294e` and the locally installed Foundry module's source map, and checked live against Foundry 14.368 with REST API module 3.4.1. [Third-party notices](THIRD_PARTY_NOTICES.md) preserve the upstream MIT notice. The router's PEG design follows the route parser approach in [mk/routes.lua](https://github.com/mascarenhas/mk/blob/master/src/mk/routes.lua).

## Retired records

Validation logs, audits, and measurement records describe past runs rather than current behavior. Their lasting conclusions live in the documents above; their last versions remain available:

- [`docs/master-validation.md`](https://github.com/mascarenhas/foundry-relay/blob/25271a4d5581b1a65a0184a9518318d15d85e85f/docs/master-validation.md): 2026-10-25 Titan-master validation on Linux and M1 macOS, including the headless login and timeout-logging regressions.
- [`docs/validation.md`](https://github.com/mascarenhas/foundry-relay/blob/2903378391888e0737819920abe8d15c7bda9875/docs/validation.md): Linux, Windows, and live Foundry validation of the relay before it used worker threads.
- [`docs/logging-validation.md`](https://github.com/mascarenhas/foundry-relay/blob/2903378391888e0737819920abe8d15c7bda9875/docs/logging-validation.md): validation of structured logging.
- [`docs/session-validation.md`](https://github.com/mascarenhas/foundry-relay/blob/2903378391888e0737819920abe8d15c7bda9875/docs/session-validation.md): validation of the headless session API, including the live HTTPS Foundry run.
- [`docs/thread-validation.md`](https://github.com/mascarenhas/foundry-relay/blob/2903378391888e0737819920abe8d15c7bda9875/docs/thread-validation.md): Linux, macOS, and Windows validation of the threaded relay.
- [`docs/api-audit.md`](https://github.com/mascarenhas/foundry-relay/blob/2903378391888e0737819920abe8d15c7bda9875/docs/api-audit.md): the upstream API audit, with evidence links and the follow-up checklist.
- [`docs/coverage-baseline.json`](https://github.com/mascarenhas/foundry-relay/blob/2903378391888e0737819920abe8d15c7bda9875/docs/coverage-baseline.json): a coverage snapshot from an earlier collection workflow.
- [Channel cost measurements](https://github.com/mascarenhas/foundry-relay/blob/2903378391888e0737819920abe8d15c7bda9875/docs/threading.md#channel-cost-measurements), formerly in `docs/threading.md`: the reply-channel benchmark behind the lease pool.
