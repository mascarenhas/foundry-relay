# Chapter 3: Cooperative SQLite Persistence, Configuration, and Structured Logging

Three support subsystems sit beneath the server, API workers, and world
engines: startup configuration in [`relay/config.titan`](../relay/config.titan),
cooperative SQLite storage in [`relay/store.titan`](../relay/store.titan), and
non-suspending JSON logging in [`relay/log.titan`](../relay/log.titan). Each
solves a cross-cutting systems constraint for a multi-threaded Titan server:
validating secrets and browser origins without timing leaks, coordinating
SQLite writes across OS threads without starving libuv's shared thread pool,
and draining structured JSON diagnostics to `stderr` without blocking request
or protocol handlers. For operator-facing environment variable tables,
reverse-proxy settings, and log schemas, see
[Configuration, Deployment, and Logging](configuration.md).

## Startup validation and constant-time secrets

Configuration enters once during process startup in `run` inside
[`main.titan`](../main.titan) through `load` in
[`relay/config.titan`](../relay/config.titan), before any database file or
network listener opens. The result is an immutable `Config` record whose twelve
fields (`host`, `port`, `api_key`, `pairing_code`, `database`, `public_url`,
`origins`, `request_timeout`, `heartbeat`, `auth_timeout`, `max_pending`,
`api_concurrency`) are all declared `const`. Because `Config` holds only
strings, integers, and a string Array, `Server` passes it directly inside
`api_worker.Bootstrap` and `world.Bootstrap` across OS threads with no shared
mutable state.

Validation fails fast on any malformed setting:

- `required` rejects missing or empty `FOUNDRY_REST_API_KEY` and
  `FOUNDRY_PAIRING_CODE`. `load` folds the pairing code with `string.upper` and
  enforces `#code == 6` and `^[A-Z0-9]{6}$`.
- `number` parses optional integer settings with `math.tointeger` and enforces
  `1 <= n <= maximum`. When `RELAY_REQUEST_TIMEOUT_MS` is unset,
  `request_timeout` receives the internal sentinel `0` so each forwarding route
  falls back to its own `Endpoint.timeout_ms`; when the variable is present,
  `0` is rejected.
- `url.parse` validates `RELAY_PUBLIC_URL`, accepting only absolute `ws://` or
  `wss://` URLs whose path is exactly `/relay` with no query string.
- `RELAY_ALLOWED_ORIGINS` splits on `,` via `string.split`, retaining each
  non-empty exact origin string.

Secret comparisons and browser origin checks live alongside `Config` so every
thread enforces one policy. Both `secret_equal` in
[`relay/config.titan`](../relay/config.titan) (used for `x-api-key`, pairing
codes, and headless session nonces) and `same_secret` in
[`relay/store.titan`](../relay/store.titan) (used for WebSocket pairing tokens)
avoid early returns on length or byte mismatch. `secret_equal` seeds its
accumulator with `#left ~ #right`, scans to the maximum length of the two
strings using `string.byte(...) or 0`, and folds each byte difference with
bitwise OR.

`Config:request_origin_allowed` centralizes the `Origin` policy shared by
`Worker:dispatch` in [`relay/api_worker.titan`](../relay/api_worker.titan) and
`execute` in [`relay/world.titan`](../relay/world.titan). Native clients that
omit `Origin` pass; requests carrying multiple `Origin` headers fail;
same-origin requests matching `scheme .. "://" .. authority` pass; and all
other browser origins must match an exact entry via `Config:allows_origin`.

```titan
-- Scan all bytes, including when lengths differ; secrets never appear in logs.
function secret_equal(left: string, right: string): boolean
  local different = #left ~ #right
  local maximum = #left
  if #right > maximum then maximum = #right end
  for i = 1, maximum do
    local a = string.byte(left, i) or 0
    local b = string.byte(right, i) or 0
    different = different | (a ~ b)
  end
  return different == 0
end

-- ...

function Config:request_origin_allowed(origin_headers: {string},
                                       scheme: string, authority: string): boolean
  if #origin_headers == 0 then return true end
  if #origin_headers ~= 1 then return false end
  local origin = origin_headers[1]
  if origin == scheme .. "://" .. authority then return true end
  return self:allows_origin(origin)
end
```
*Source: [`relay/config.titan`](../relay/config.titan) — `secret_equal`, `Config:request_origin_allowed`*

## Per-thread FIFO ownership and database protection

Because every OS thread in Titan runs an independent Lua state, threads cannot
share a `sqlite3.Connection` or `Store` userdata. Each thread holds its own
`Store` pointing at the same persistent file path (`self.path`), initialized
through two distinct entry points in
[`relay/store.titan`](../relay/store.titan):

- **Main thread (`open`)**: Called once from `Server.new` in
  [`relay/server.titan`](../relay/server.titan) before any worker thread
  starts. `validate_path` rejects empty paths and `":memory:"`, because workers
  must share durable storage on disk. `open` creates the file through a
  short-lived `connection`, immediately restricts its permissions to `0600`
  (`384`) via synchronous `uv.fs_chmod`, closes that setup handle, and then
  executes `CREATE TABLE IF NOT EXISTS clients (...)` inside `retry_operation`.
  Applying `chmod` ahead of schema initialization protects the database before
  SQLite writes any journal or credential row. (On Windows, POSIX mode bits do
  not establish ACLs; see
  [Database and permissions](configuration.md#database-and-permissions).)
- **Worker threads (`attach`)**: Called by `run` in
  [`relay/api_worker.titan`](../relay/api_worker.titan) and `execute` in
  [`relay/world.titan`](../relay/world.titan). `attach` validates the filename
  and allocates a local `Store` record with no SQLite connection open and no
  DDL work, so worker startup never contends with a held schema or write lock.

Inside a single thread, multiple concurrent Tasks—such as simultaneous HTTP
requests inside an API worker—may call `Store` methods concurrently. `Store`
serializes them cooperatively with a FIFO queue (`owner: async.Task?` and
`waiters: {Waiter}`, each `Waiter` pairing a `task` with a fresh
`async.ResumeToken("relay.store")`).

`Store:acquire` rejects a closed store, runs `async.checkpoint()`, and grabs
`self.owner` immediately when idle. Re-entering from the current owner raises
`"recursive relay store operation"` instead of deadlocking. Otherwise, the Task
appends itself to `self.waiters` and suspends via
`async.suspend(waiter.token, detach)`.

Two invariants make the handoff race-free under Titan's cooperative scheduler:

1. **No barging**: `Store:release` removes the head waiter via
   `Store:remove_waiter` and assigns `self.owner = waiter.task` *before*
   calling `waiter.task:resume(waiter.token)`. Because resumption is deferred
   to the scheduler, a third Task calling `acquire` in the interim sees
   `self.owner ~= nil` and joins the tail of `self.waiters`.
2. **Cancellation after reservation**: A waiting Task can be cancelled after
   `release` has assigned `self.owner = current` but before its deferred wake
   runs. Both the `async.suspend` cancel hook and the lexical
   `defer if not acquired then detach() end` execute `detach()`, which removes
   the waiter and—if `self.owner == current`—calls `self:release()` to pass
   ownership to the next waiter.

```titan
local function Store:release()
  if #self.waiters == 0 then self.owner = nil; return end
  local waiter = self.waiters[1]
  self:remove_waiter(waiter)
  self.owner = waiter.task
  waiter.task:resume(waiter.token)
end

local function Store:acquire()
  if self.closed then raise "relay store is closed" end
  async.checkpoint()
  local current = async.running()
  if not self.owner then self.owner = current; return end
  if self.owner == current then raise "recursive relay store operation" end
  local waiter = Waiter(current, async.ResumeToken("relay.store"))
  self.waiters[#self.waiters + 1] = waiter
  local detach = function()
    self:remove_waiter(waiter)
    if self.owner == current then self:release() end
  end
  local acquired = false
  defer if not acquired then detach() end
  async.suspend(waiter.token, detach)
  acquired = true
end
```
*Source: [`relay/store.titan`](../relay/store.titan) — `Store:release`, `Store:acquire`*

## Immediate transactions, cooperative retry, and token generation

Titan's asynchronous `sqlite3` library runs native SQLite calls on libuv's
process-wide worker thread pool (four worker slots by default). That
architecture creates a pool-starvation hazard when SQLite's built-in busy
handler is enabled: if four OS threads contend on a write lock with a nonzero
`PRAGMA busy_timeout`, all four libuv worker threads sleep inside C, leaving
zero worker slots to run the lock holder's `COMMIT` or `ROLLBACK`.

[`relay/store.titan`](../relay/store.titan) avoids pool exhaustion by setting
`PRAGMA busy_timeout = 0` inside `connection`. SQLite returns `SQLITE_BUSY`
(error code `5`) immediately without sleeping in C, freeing the libuv worker
thread at once. `Store:operation` holds the thread-local FIFO gate across the
entire `retry_operation` loop, while each attempt opens a fresh short-lived
connection and closes it before any backoff sleep.

Inside `retry_operation`, writes begin with `execute(db, "BEGIN IMMEDIATE")`,
acquiring SQLite's reserved lock up front rather than attempting a
mid-transaction upgrade from a read lock. Two lexical `defer` statements unwind
in reverse order: first a conditional rollback guarded by synchronous
`not db:get_autocommit()` (so a `SQLITE_BUSY` failure on `BEGIN IMMEDIATE`
itself does not trigger a spurious rollback error) and `not committed`
(protecting an already acknowledged `db:commit()`), then `db:close()`. Because
Titan runs block-local `defer` statements before entering the `catch` handler
of the same `do ... catch ... end` block, both rollback and connection close
finish before `catch` inspects `error` or suspends in `timer.sleep(pause)`.

Only `sqlite3.Error` with `code == 5` retries. Errors such as `SQLITE_LOCKED`
(code `6`) or `async.CancellationReason` propagate immediately. Backoff doubles
from `1 ms` to a `25 ms` ceiling within a 5-second monotonic `uv.hrtime()`
deadline (`5000000000` nanoseconds), clamping the final sleep to the remaining
budget.

```titan
local function retry_operation<|T|>(path: string, write: boolean,
    operation: function (sqlite3.Connection): T): T
  -- ...
  while true do
    if previous ~= nil and uv.hrtime() >= deadline then raise previous end
    local committed = false
    do
      local db = connection(path)
      defer db:close()
      defer if write and not committed and not db:get_autocommit() then db:rollback() end
      if write then execute(db, "BEGIN IMMEDIATE") end
      local result = operation(db)
      if write then
        db:commit()
        committed = true
      end
      return result
    catch
      if committed or not (error is sqlite3.Error) then raise end
      local failure: sqlite3.Error = error
      if failure.code ~= 5 then raise end
      previous = failure
      -- ...
      timer.sleep(pause)
      delay = delay * 2
      if delay > 25 then delay = 25 end
    end
  end
end
```
*Source: [`relay/store.titan`](../relay/store.titan) — `retry_operation`*

All business operations run through `Store:operation` and materialize `Client`
records (`row_client`), closing statements and cursors before returning:

- **Three-tier pairing reuse (`Store:pair`)**: Inside one `BEGIN IMMEDIATE`
  transaction, `Store:pair` searches `clients` through `find_client` in three
  ordered passes: (1) `existing_client_id` + `world_id` with compatible
  `server_origin` (either side empty or equal), (2) `world_id` +
  `server_fingerprint` with compatible `server_origin`, and (3) exact
  `world_id` + `server_origin`. Matching an existing row preserves its
  `client_id` and `token` while updating `world_title`, `server_fingerprint`,
  `server_origin`, and `last_seen`. Only when all three passes miss does
  `Store:pair` mint a fresh 16-byte `client_id` and 32-byte `token` and insert
  a new row.
- **Cryptographic tokens (`secure_token`)**: Allocates a `uv.buf_t`, fills it
  from the operating system CSPRNG via synchronous
  `uv.random(nil, nil, buffer, count, 0, nil)` (retaining no callback or
  borrowed native state), and maps each byte through the preallocated 256-entry
  `const {string}` table `hex_bytes` into a `string.writer()`.
- **Authentication, updates, and retirement**: `Store:authenticate` loads by
  `client_id` and compares tokens with `same_secret`. `Store:update` uses SQL
  `CASE WHEN ? = '' THEN col ELSE ? END` so omitted fields leave stored
  metadata intact. `Store:revoke` replaces the row's `token` with a new
  `secure_token()` rather than deleting the pairing; `Store:remove` deletes the
  row; `Store:close` marks `self.closed = true` while already-admitted
  operations finish cleanup on their own connections.

## Non-suspending structured logging

Every HTTP request, WebSocket frame, timeout, and lifecycle transition emits
structured JSON lines through [`relay/log.titan`](../relay/log.titan). If log
admission suspended on `stderr` I/O, a stalled pipe reader could pause request
dispatch, delay heartbeat Pongs, or inject unexpected yields into state
transitions.

`Logger` eliminates that coupling by placing an
`async.BufferedSubscription<|string, nil|>` (`source`) between synchronous
callers and a single background writer Task (`worker`). Callers invoke
`Logger:emit` (or the nil-safe module helper `emit`), which checks
`self.closed` and `self.failed`, maps the level through `rank` (`error` = 1,
`info` = 2, `debug` = 3), drops messages above `self.minimum`, enforces the
queue bound (`self.queued >= self.capacity`, default 1,024), encodes the JSON
record with `line`, and pushes it via `self.publish(encoded)`.

To keep hot fieldless events allocation-light, `line` branches on
`fields == nil`. Fieldless records such as `server_stopped` and
`websocket_authentication_rejected` encode a typed `SimpleRecord` directly
without allocating a temporary `{string: value}` Map. When structured fields
are supplied, `line` copies them into a fresh Map and overwrites `"timestamp"`,
`"level"`, and `"event"` so caller data cannot shadow envelope keys. Both paths
pass `encode_limit` (`json.EncodeOption.max_bytes(16384)`), and `Logger:emit`'s
`catch` turns invalid UTF-8, cycles, unsupported types, or oversized payloads
into a silent increment of `self.dropped`.

```titan
local record SimpleRecord
  const event: string
  const level: string
  const timestamp: string
end

-- ...

local function line(level: string, event: string, fields: {string: value}?): string
  local timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
  if fields == nil then
    return json.encode(SimpleRecord(event, level, timestamp), encode_limit) .. "\n"
  end
  local contents: {string: value} = {}
  for key, item in iteration.pairs(fields) do contents[key] = item end
  contents["timestamp"] = timestamp
  contents["level"] = level
  contents["event"] = event
  return json.encode(contents, encode_limit) .. "\n"
end
```
*Source: [`relay/log.titan`](../relay/log.titan) — `SimpleRecord`, `line`*

The writer Task runs `Logger:write_loop`, pulling one encoded line at a time
from `self.source:next()`, invoking `self.sink` (default `write_stderr`,
writing to `os.stderr`), and calling `Logger:report_dropped` after each
successful write and at stream shutdown to emit an error-level `log_dropped`
event with the accumulated count. Any sink error—such as a closed pipe or an
unsupported regular-file stderr target—sets `self.failed = true`, resets
`self.queued = 0`, and exits cleanly so logging failures never become uncaught
Task errors or mask application failures.

```titan
local function Logger:write_loop(): nil
  defer self.source:close()
  while true do
    case self.source:next()
    when item(text) then
      self.queued = self.queued - 1
      self.sink(text)
      self:report_dropped()
    else
      self:report_dropped()
      return nil
    end
  end
  return nil
catch
  -- A failed destination disables logging and discards unread records. It must
  -- never become an uncaught Task error or replace an application failure.
  self.failed = true
  self.queued = 0
  return nil
end
```
*Source: [`relay/log.titan`](../relay/log.titan) — `Logger:write_loop`*

Worker threads forward their logs to the main thread without blocking on the
shared channel. Both `run` in
[`relay/api_worker.titan`](../relay/api_worker.titan) and `run` in
[`relay/world.titan`](../relay/world.titan) call
`log.forward(bootstrap.log_level, bootstrap.log_lines)`, constructing a
thread-local `Logger` whose custom sink pushes encoded lines onto the borrowed
`thread.Sender<|string|>` (`log_lines`, capacity 1,024) via non-blocking
`try_send`, tracking its own `lost` counter for `log_dropped`. The `Sender`
stays borrowed so one worker's exit cannot close logging for sibling threads.
On the main thread, `Server.log_task` drains `log_inbox` into
`self.logger:accept(text)`, which enforces `maximum_line_bytes + 1` and
`self.capacity` without re-encoding.

During shutdown, `Logger:close` marks `self.closed = true`, invokes
`self.finish()` to signal end-of-stream, and awaits `self.worker` via
`tasks.await_terminal`. Because [`main.titan`](../main.titan) defers
`logger:close()` outside `run`, `Server:close()` joins every worker and drains
`log_task` before the main logger flushes its final records. If `resolve_level`
fails on an invalid `RELAY_LOG_LEVEL` before any `Logger` exists, `main`
invokes `log.fatal`, writing a single fixed JSON error line to `os.stderr`
inside an isolated `catch`.

---

← Previous: [Chapter 2: Declarative Routing, Request Translation, and Event Streaming](routing.md) | [Table of Contents](index.md) | Next: [Chapter 4: Headless Browser Automation and the OpenSSL FFI Boundary](headless-sessions.md) →
