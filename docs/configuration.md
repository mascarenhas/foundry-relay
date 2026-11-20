# Configuration, Deployment, and Logging

Operational reference for configuring `foundry-relay`, deploying it behind a
reverse proxy, protecting its SQLite store, collecting its structured JSON
logs, and bounding runtime load. For the internal implementation of
configuration loading, cooperative SQLite access, and non-suspending logging,
see [Chapter 3: Cooperative SQLite Persistence, Configuration, and Structured Logging](persistence-and-logging.md).

## Environment variables

All core relay settings come from environment variables read at startup:

| Variable | Default | Purpose |
| --- | --- | --- |
| `FOUNDRY_REST_API_KEY` | required | Nonempty REST `x-api-key` credential |
| `FOUNDRY_PAIRING_CODE` | required | Reusable six-character ASCII alphanumeric pairing code |
| `RELAY_HOST` | `127.0.0.1` | Listener host or IP address |
| `RELAY_PORT` | `3010` | Listener port, range `1`–`65535` |
| `RELAY_DATABASE` | `relay.sqlite3` | Persistent SQLite database path (empty string and `:memory:` are rejected) |
| `RELAY_PUBLIC_URL` | `ws://127.0.0.1:$RELAY_PORT/relay` | Absolute `ws://` or `wss://` URL returned by pairing; path must be `/relay` with no query |
| `RELAY_ALLOWED_ORIGINS` | `http://127.0.0.1:30000,http://localhost:30000` | Comma-separated exact browser origins for HTTP, WebSocket upgrades, and headless Foundry sessions |
| `RELAY_REQUEST_TIMEOUT_MS` | route default | Global forwarding deadline override in milliseconds, range `1`–`3600000` (route defaults are 10–45 s) |
| `RELAY_AUTH_TIMEOUT_MS` | `10000` | WebSocket handshake and first `auth` frame deadline in milliseconds, range `1`–`60000` |
| `RELAY_HEARTBEAT_MS` | `30000` | WebSocket Ping interval in milliseconds, range `1`–`3600000`; each Ping has a 5 s Pong deadline |
| `RELAY_MAX_PENDING` | `128` | Maximum concurrent pending REST requests per world, range `1`–`10000` |
| `RELAY_API_CONCURRENCY` | `1` | Number of API worker OS threads; HTTP requests use round-robin dispatch |
| `RELAY_LOG_LEVEL` | `info` | Case-sensitive JSON log threshold: `error`, `info`, or `debug` |

`FOUNDRY_PAIRING_CODE` accepts six ASCII letters or digits; the relay
uppercases it to match Foundry's **Enter Code** dialog and compares submitted
codes exactly in constant time. Treat both `FOUNDRY_REST_API_KEY` and
`FOUNDRY_PAIRING_CODE` as secrets. Set `RELAY_PUBLIC_URL` explicitly whenever
clients connect through a different hostname, address, or reverse proxy.

Numeric settings must be unset (to select the default) or parse as positive
base-10 integers within their documented maximum. Startup validates settings in
ordered phases and exits with status `1` plus an `error`-level `server_failed`
log record on failure:

1. **Log level** (`reason: "invalid_log_configuration"`): validates
   `RELAY_LOG_LEVEL` before starting the logger.
2. **Core configuration** (`reason: "invalid_configuration"`): validates the
   twelve core settings above before opening SQLite or binding a socket.
3. **Database and headless session setup**
   (`reason: "database_or_session_initialization_failed"`): opens and protects
   `RELAY_DATABASE`, validates `RELAY_MAX_SESSIONS` and
   `RELAY_SESSION_TIMEOUT_MS`, and generates the ephemeral RSA-2048 key when
   `RELAY_CHROME` is set, all before binding a socket.
4. **Workers and listener** (`reason: "listener_start_failed"`): starts the API
   worker pool and binds `RELAY_HOST:RELAY_PORT`.

The four headless session variables (`RELAY_CHROME`, `RELAY_BROWSER_PROFILES`,
`RELAY_MAX_SESSIONS`, and `RELAY_SESSION_TIMEOUT_MS`) are specified in
[Enable sessions](sessions.md#enable-sessions). [Chapter 1](threading.md)
explains how `RELAY_API_CONCURRENCY` distributes work across OS threads.

## Reverse proxy and origins

The relay speaks plain HTTP and WebSocket (`ws://`) on its listener. When
browser clients or remote REST callers require HTTPS/WSS, place a
TLS-terminating reverse proxy in front of the relay:

- Set `RELAY_PUBLIC_URL` to the externally visible WebSocket endpoint, such as
  `wss://relay.example.test/relay`. `POST /auth/pair` returns this URL to the
  Foundry module, and headless sessions verify that the world's saved relay URL
  matches it.
- Set `RELAY_ALLOWED_ORIGINS` to the exact Foundry browser origin or origins
  (scheme, host, and non-default port, comma-separated, without wildcards).
  Empty comma segments are ignored.
- Configure the proxy to upgrade WebSocket connections on `/relay` and disable
  response buffering for the six Server-Sent Events `/<channel>/subscribe`
  routes (responses also send `Cache-Control: no-cache` and
  `X-Accel-Buffering: no`).

The relay ignores `Forwarded` and `X-Forwarded-*` headers and never manages
proxy TLS itself. Requests without an `Origin` header—such as native CLI tools
or backend services—are accepted. Browser requests with a single `Origin`
matching either the request's own scheme and authority or an entry in
`RELAY_ALLOWED_ORIGINS` are accepted and echoed in
`Access-Control-Allow-Origin` with `Vary: Origin`; all other `Origin` values
return `403` before route resolution. See [request rules](api.md#request-rules)
for full CORS and `OPTIONS` handling.

## Database and permissions

Pairing credentials and nonsecret world metadata live in the SQLite file named
by `RELAY_DATABASE` (default `relay.sqlite3`). The parent directory must
already exist before startup.

- **POSIX**: the relay opens the file and enforces mode `0600` before creating
  tables or journals, keeping pairing tokens unreadable to other local users.
- **Windows**: POSIX permission bits do not establish equivalent Windows access
  control; place `RELAY_DATABASE` in a private directory restricted by the
  relay user's NTFS ACL. See [Windows build](build-and-testing.md#windows-build)
  for the packaged deployment layout.

Credentials survive relay restarts. `POST /api/self-unpair` rotates a world's
token while preserving its client ID so re-pairing issues the new token, and
`DELETE /clients/:clientId` removes the world and disconnects it; see
[pairing and the module connection](api.md#pairing-and-the-module-connection).
Headless session RSA keys, handshakes, and passwords stay exclusively in memory
and never enter SQLite.

## Logs

Relay-generated logs write one JSON object per line to `stderr`.
`RELAY_LOG_LEVEL` defaults to `info`; values are case-sensitive, and any
unrecognized value stops startup with status `1`.

| Level | Events included |
| --- | --- |
| `error` | Startup/configuration/listener failures (`server_failed`), HTTP I/O or internal failures (`http_request_failed`), WebSocket protocol/transport/heartbeat failures (`websocket_failed`), forwarding timeouts (`request_timeout`), headless browser startup/connection/cleanup failures (`headless_session_failed`, `headless_session_cleanup_failed`), and dropped log counts (`log_dropped`) |
| `info` | All `error` events plus server lifecycle (`server_started`, `server_stopped`), HTTP request admission (`http_request`), pairing/revocation/removal (`pairing_created`, `pairing_revoked`, `client_removed`), rejected WebSocket auth (`websocket_authentication_rejected`), authenticated WebSocket connect/disconnect (`websocket_connected`, `websocket_disconnected`), and headless session lifecycle (`headless_session_starting`, `headless_session_started`, `headless_session_stopped`) |
| `debug` | All `info` events plus WebSocket message categories and byte counts (`websocket_message_sent`, `websocket_message_received`), ignored/discarded messages (`websocket_message_ignored`, `websocket_message_discarded`), forwarding/results (`request_forwarded`, `request_result`), heartbeat frames (`websocket_ping`, `websocket_pong`), closing/reconnect replacement (`websocket_closing`, `websocket_replaced`), and subscription count updates (`subscription_changed`) |

Every record carries `timestamp` (UTC ISO-8601 at one-second resolution),
`level`, and `event`, along with fixed event-specific fields:

```json
{"event":"http_request","level":"info","method":"GET","route":"/world-info","timestamp":"2026-10-11T20:00:00Z"}
```

### Admission, privacy, and delivery guarantees

- **HTTP admission.** `http_request` records cover every request reaching the
  relay's HTTP handler, including authentication failures, unmatched paths,
  `OPTIONS`, SSE streams, and `/relay` upgrades. They are emitted before
  dispatch. `route` records the declared route template (such as
  `/clients/:clientId`) or `<unmatched>`; standard HTTP methods (`GET`, `POST`,
  `PUT`, `PATCH`, `DELETE`, `OPTIONS`, `HEAD`, `CONNECT`, `TRACE`) are recorded
  verbatim, and other methods as `OTHER`. Requests rejected by the HTTP parser
  never reach this handler.
- **Strict sanitization.** Logs omit HTTP headers, query values, route
  parameters, bodies, API keys, pairing codes, tokens, passwords, world
  metadata, browser/CDP contents, arbitrary error text, and peer Close reasons.
  WebSocket message `type` values come from the known protocol catalog
  (`unknown` for unrecognized types), and `client_id` values come exclusively
  from stored pairings.
- **Single timeout record.** A forwarded request returning HTTP `408` emits
  exactly one `request_timeout` record (`client_id`, `type`), whether the API
  worker's deadline or the world worker's deadline expires first.
- **Bounded non-suspending queue.** Log admission never suspends request or
  connection handlers. The writer drains up to 1,024 queued records plus one
  in-flight record, capping each JSON object at 16 KiB; worker threads forward
  their encoded lines over a 1,024-entry channel to this writer. Overflow,
  oversized records, and unencodable payloads increment a drop counter emitted
  as an `error`-level `log_dropped` record (`count`) when the sink progresses.
  A write error on `stderr` disables relay logging for the rest of the process
  without failing the server. Shutdown drains admitted records; a permanently
  stalled `stderr` sink can delay that drain.
- **Runtime diagnostics.** Low-level Titan runtime diagnostics outside relay
  handlers (such as an uncaught HTTP framing failure) keep the runtime's own
  diagnostic format and are outside `RELAY_LOG_LEVEL`.
- **Saving logs to a file.** Titan's standard-stream API supports terminals and
  pipes. Pipe `stderr` through a collector rather than redirecting it directly
  to a regular file, which is unsupported and disables the log sink:

```sh
./build/foundry-relay 2>&1 | tee relay.log
```

## Shutdown and limits

`SIGINT` and `SIGTERM` trigger orderly shutdown: the relay closes its listener,
retires active headless browser sessions and world WebSockets, cancels and
joins API and world worker threads, drains admitted log records, and closes the
SQLite store. If a headless browser fails to retire cleanly during shutdown,
the server logs `server_failed` (`reason: "serve_or_shutdown_failed"`) and
exits with status `1`.

Shutdown cancels and joins the Tasks serving adopted HTTP exchanges without
aborting their underlying TCP transports. If an HTTP client permanently stalls
while sending a request body or reading a response, shutdown is not guaranteed
to be bounded.

### Operational limits

| Resource | Limit | Overflow or expiry behavior |
| --- | --- | --- |
| Listener accept backlog | 128 pending connections | OS TCP listen backlog |
| HTTP header read timeout | 10 s (initial and keep-alive) | Connection closes |
| Request target / query fields | 16 KiB / 256 query fields | HTTP `400` |
| HTTP body / WebSocket frame / JSON depth | 16 MiB / 16 MiB / 64 levels | HTTP `400` or WebSocket close |
| Pending forwarding requests per world | `RELAY_MAX_PENDING` (default 128, max 10,000) | HTTP `429` |
| Per-world WebSocket output queue | `RELAY_MAX_PENDING + 16` messages | HTTP `503` |
| Per-SSE subscriber queue | 128 events | Subscriber retired; stream ends after draining queued events |
| Log queue / JSON record size | 1,024 queued records / 16 KiB per object | Counted in `log_dropped` |
| Headless sessions / pending handshakes | `RELAY_MAX_SESSIONS` (default 4, max 64) / 32 (5 min TTL) | HTTP `429` |
