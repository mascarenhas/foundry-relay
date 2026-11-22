# Chapter 4: Headless Browser Automation and the OpenSSL FFI Boundary

Automating a headless Foundry VTT client inside the same native executable
crosses three boundaries that ordinary HTTP forwarding never touches: C FFI
into OpenSSL for RSA-2048 OAEP credential decryption
([`relay/session_crypto.titan`](../relay/session_crypto.titan)), single-flight
Chrome DevTools Protocol commands over loopback WebSockets
([`relay/cdp.titan`](../relay/cdp.titan) and
[`relay/browser.titan`](../relay/browser.titan)), and origin-gated DOM
automation plus pairing verification inside an off-the-record Chromium page
([`relay/foundry_session.titan`](../relay/foundry_session.titan)), all governed
by an in-memory supervisor ([`relay/sessions.titan`](../relay/sessions.titan)).
Neither GM passwords nor RSA private keys ever enter SQLite or logs. For
operator setup, RSA wire examples, and HTTP route contracts, see
[Headless Foundry Sessions](sessions.md).

## Hiding OpenSSL behind a Titan interface

[`relay/session_crypto.titan`](../relay/session_crypto.titan) is the sole
module in `foundry-relay` that imports C headers (`openssl/evp.h`,
`openssl/rsa.h`, `openssl/pem.h`, `openssl/crypto.h`, `openssl/err.h`).
Exposing a record with a `foreign *EVP_PKEY` field in the module's public
interface would propagate OpenSSL header requirements to every consumer.
Instead, `NativeKey` stays a `local record`, and callers interact only with the
nominal `interface Key` (`public_key`, `decrypt`, `close`) returned by
`generate`.

Ownership combines deterministic teardown with a zero-closure
garbage-collection fallback. `generate` creates a 2048-bit RSA `EVP_PKEY`,
renders its SubjectPublicKeyInfo PEM public key into a 4,096-byte automatic C
array via an OpenSSL memory `BIO` (`pem`), constructs
`NativeKey(nil, pem(handle))` before attaching the pointer, registers
`gc.finalizable<|value|>(native_key, finalize_key)` with a top-level helper
function, wraps the record as `Key`, and finally transfers
`native_key.handle = handle`. `NativeKey:close` clears `self.handle = nil`
before calling `ffi.EVP_PKEY_free(handle)`, making explicit closure in
`Manager:close` and GC finalization mutually idempotent.

```titan
interface Key
  public_key: string
  function decrypt(encoded: string): string
  function close()
end

local record NativeKey
  local handle: foreign *EVP_PKEY
  const public_key: string
end

-- ...

function generate(): Key
  -- ...
  local transferred = false
  defer if not transferred then ffi.EVP_PKEY_free(handle) end
  local native_key = NativeKey(nil, pem(handle))
  gc.finalizable<|value|>(native_key, finalize_key)
  local result: Key = native_key
  native_key.handle = handle
  transferred = true
  return result
end
```
*Source: [`relay/session_crypto.titan`](../relay/session_crypto.titan) — `Key`, `NativeKey`, `generate`*

Before any ciphertext reaches OpenSSL, `decode` enforces canonical padded
standard Base64 for a 256-byte RSA-2048 block: exact length `344`, trailing
`"=="` (`string.byte` equal to `61`), valid sextets (`base64_sextet`), and zero
residual pad bits (`accumulator == 0`). Decoded bytes go directly into an
automatic stack C array (`foreign unsigned char.new_array(256)`).

`NativeKey:decrypt` clears OpenSSL's thread error queue on entry and exit
(`ffi.ERR_clear_error()`), configures an `EVP_PKEY_CTX` with
`RSA_PKCS1_OAEP_PADDING` and `EVP_sha256()` for both OAEP and MGF1 (freeing the
context via `defer ffi.EVP_PKEY_CTX_free`), and decrypts into a second 256-byte
stack C array guarded by `defer ffi.OPENSSL_cleanse(raw_plaintext, 256)`. After
validating that `length` lies within the RSA-2048 SHA-256 OAEP plaintext limit
(`1..190` bytes), `raw_plaintext as string(count)` copies exactly `count` bytes
into a Titan string so trailing stack padding never enters the Lua GC heap.
Every validation or decryption error collapses to the fixed message
`"Invalid encrypted credentials"`.

```titan
function NativeKey:decrypt(encoded: string): string
  if not self.handle then raise "Session encryption is closed" end
  local ciphertext = foreign unsigned char.new_array(256)
  local raw_ciphertext: foreign *unsigned char = ciphertext
  decode(encoded, raw_ciphertext)
  -- ...
  local plaintext = foreign unsigned char.new_array(256)
  local raw_plaintext: foreign *unsigned char = plaintext
  defer ffi.OPENSSL_cleanse(raw_plaintext, 256)
  local length: foreign size_t = 256
  if ffi.EVP_PKEY_decrypt(context, raw_plaintext, length, raw_ciphertext, 256) <= 0 then
    raise "Invalid encrypted credentials"
  end
  local count: integer = length
  if count < 1 or count > 190 then raise "Invalid encrypted credentials" end
  return raw_plaintext as string(count)
end
```
*Source: [`relay/session_crypto.titan`](../relay/session_crypto.titan) — `NativeKey:decrypt`*

## Single-flight Chrome DevTools Protocol

[`relay/cdp.titan`](../relay/cdp.titan) wraps one `websocket.Connection` as a
strictly single-flight JSON-RPC transport (`Connection`). One boolean flag
(`self.busy`) rejects overlapping commands on the same connection rather than
multiplexing replies or queuing unsolicited browser events.

`Connection:call` increments `self.next_id`, serializes the command via
`wire.encode`, spawns a `deadline` Task that sleeps for `timeout` milliseconds
before calling `self:abort()` (closing the WebSocket so a blocked read wakes
promptly), and drains `deadline` with `defer tasks.drain(deadline)`. Inside
`Connection:exchange`, the loop writes one text frame and reads text frames
until an envelope carries an `"id"`. Frames lacking `"id"` must carry a string
`"method"` and are discarded because readiness is polled explicitly. Mismatched
`id`, unexpected `sessionId`, remote `"error"` payloads, or non-object
`"result"` fields raise a private `local record Failure`.

The `catch` clause in `Connection:call` enforces strict diagnostic sanitization
at the protocol boundary: on any error it aborts the transport, translates
`expired` into `"CDP command timed out"`, forwards only fixed `Failure.message`
strings for protocol violations, and replaces every other transport or JSON
error with `"CDP command failed"`. Neither evaluated JavaScript, credentials,
nor remote DOM diagnostics can escape. `Connection:evaluate` builds on `call`
by invoking `Runtime.evaluate` (`awaitPromise = true`, `returnByValue = true`)
and rejecting `exceptionDetails` with `"CDP evaluation failed"`.

```titan
function Connection:call(method: string, params: {string: value},
                         session_id: string?, timeout_ms: integer?): {string: value}
  -- ...
  self.busy = true
  defer self.busy = false
  local expired = false
  local deadline = async.run<|nil, value|>(function (): nil
    timer.sleep(timeout)
    expired = true
    self:abort()
    return nil
  end)
  defer tasks.drain(deadline)
  do
    return self:exchange(request, id, session_id)
  catch
    self:abort()
    if expired then raise "CDP command timed out" end
    if error is Failure then
      local failure: Failure = error
      raise failure.message
    end
    raise "CDP command failed"
  end
end
```
*Source: [`relay/cdp.titan`](../relay/cdp.titan) — `Connection:call`*

## Disposable profiles and Flatpak-safe browser retirement

[`relay/browser.titan`](../relay/browser.titan) isolates one Chromium child
process and one disposable user-data directory behind `Browser`, started via
`start`.

Profile management defends against host filesystem hazards before launching the
executable. `resolve_profile_parent` resolves symlinks via `fs.realpath`,
checks that the parent is a directory, and maps `async.OperationError` names
(`ENOENT`, `ENOTDIR`, `EACCES`/`EPERM`) to fixed `Failure` diagnostics
(`profile_failure`). `new_profile` creates a unique private subdirectory via
`uv.fs_mkdtemp` (`foundry-cdp-XXXXXX`). During teardown, `remove_profile`
inspects each path with `fs.lstat` rather than `fs.stat` so symlinks written
inside a browser profile are unlinked directly without traversing external
directories.

`Browser:initialize` spawns Chromium with `--user-data-dir`,
`--remote-debugging-address=127.0.0.1`, `--remote-debugging-port=0`,
`--no-first-run`, `--no-default-browser-check`, `about:blank`, and (when
`headless` is true) `--headless=new`. Passing
`os.with_env("FOUNDRY_REST_API_KEY", "")` and
`os.with_env("FOUNDRY_PAIRING_CODE", "")` retains desktop D-Bus variables
required by Flatpak launchers while withholding relay secrets. Background
`discard` Tasks drain `stdout` and `stderr` so browser logs never stall pipes
or leak into relay diagnostics.

Discovering the dynamic loopback port requires polling `DevToolsActivePort`
inside the owned profile directory every 20 ms until `deadline`, confirming via
`fs.lstat` that it is a regular file of at most 1,024 bytes. On Windows,
Chromium can expose the filename while holding its exclusive write handle;
`read_endpoint` treats `async.OperationError` with `name == "EBUSY"` and
`operation == "fs.open"` as not ready yet (`nil`) while propagating all other
I/O errors. `endpoint` parses the decimal port (`1..65535`) and
`/devtools/browser/<alnum-dash>` path into a `ws://127.0.0.1:<port><path>` URL.
Once connected, `initialize` creates an off-the-record context
(`Target.createBrowserContext` with `disposeOnDetach = true`)—keeping cookies
and page storage in memory and avoiding desktop keyring stalls—opens an
`about:blank` target, attaches in flattened mode (`Target.attachToTarget`), and
sends `Page.enable` before returning so preload scripts registered by the
caller activate reliably.

Shutting down a browser safely across direct binaries and Flatpak wrappers
requires an escalating sequence in `Browser:retire`. `Browser:close` launches
`retire` once inside a dedicated Task (`self.retirement`) and joins it via
`tasks.await_retirement`, ensuring yielding cleanup completes even when the
caller carries pending cancellation:

1. Send graceful `Browser.close` (`request_browser_close`, 250 ms timeout) on
   the active CDP transport, then abort it.
2. If that transport was busy or already aborted (for instance, after a command
   timeout), open a fresh recovery WebSocket to `self.debugging_endpoint`
   (500 ms handshake timeout) and send `Browser.close` there.
3. If `Browser.close` succeeded, poll `self.process:is_running()` for up to two
   seconds so Chromium and any Flatpak launcher flush and exit naturally before
   signaling.
4. Spawn a 500 ms `escalation` Task to send `SIGKILL`
   (`signal(self.process, "kill")`), send `SIGTERM`, wait for
   `self.process:wait()`, close stdio streams, and drain `output` and
   `diagnostics`.
5. Decide profile removal fail-closed: reaping a Flatpak launcher process does
   not prove the sandboxed browser exited. When `self.process:is_running()`
   remains true, or when `self.debugging_endpoint` was discovered without a
   confirmed `requested_exit`, `retire` retains the profile directory and
   returns `async.Error("Browser cleanup failed", "")` so the session manager
   quarantines the world slot instead of spawning a duplicate browser.

```titan
local function read_endpoint(address: string): string?
  return fs.read_file(address)
catch
  if error is async.OperationError then
    local problem: async.OperationError = error
    if problem.name == "EBUSY" and problem.operation == "fs.open" then return nil end
  end
  raise
end

local function Browser:retire(): async.Error?
  -- ...
  local retain_profile = false
  if self.process and self.process:is_running() then retain_profile = true end
  if self.debugging_endpoint and not requested_exit then retain_profile = true end
  if retain_profile then
    failed = true
  else
    do remove_profile(self.directory) catch failed = true end
  end
  if failed then return async.Error("Browser cleanup failed", "") end
  return nil
end
```
*Source: [`relay/browser.titan`](../relay/browser.titan) — `read_endpoint`, `Browser:retire`*

## Foundry preload binding and readiness verification

[`relay/foundry_session.titan`](../relay/foundry_session.titan) layers
Foundry-specific authentication and pairing invariants atop `Browser` and
`hub.Hub`.

Before starting Chromium, `existing_client` selects a unique stored
`store.Client` whose `server_origin` matches the validated Foundry origin and
(when `world` is non-empty) whose `world_id` or `world_title` matches `world`.
Zero or ambiguous matches fail fast; headless sessions never create or mutate
pairings.

`start` rejects worlds already online (`worlds:online`), launches Chromium
through `browser.start`, and registers `binding_script(options)` via
`Page.addScriptToEvaluateOnNewDocument` before calling `Page.navigate`. The
preload script executes on every new document only when
`location.origin === cfg.origin`. Once `game.ready` fires, it checks four
invariants—matching `game.world.id`, exact GM `game.user.name` with `isGM` and
`role === 4`, active `foundry-rest-api` module, and stored module settings
(`clientId`, `wsRelayUrl`, and `pairedRelayUrl`, normalized for trailing
`/relay`)—before seeding the pairing token into `localStorage` under
`foundry-rest-api.connectionToken`. Hooks on `foundry-rest-api.relayConnected`
and `foundry-rest-api.relayDisconnected` advance
`globalThis.__titanFoundrySession.phase`.

The readiness loop polls `page_state` every 100 ms within the overall startup
budget (`remaining`):

- When `page_state` detects Foundry's `form[name="join"]`, `login` runs
  once—checking `location.origin`, matching the unique enabled `<option>` whose
  text equals `options.user`, filling the password, and calling
  `form.requestSubmit`.
- Unrecoverable phases (`"pairing-mismatch"`, `"wrong-world"`, `"wrong-user"`,
  `"admin-login"`) map through `phase_errors` to fixed relay diagnostics
  without returning DOM or console content.
- Once `phase == "authenticated"` and `worlds:online(client_id)` is true,
  `start` selects the live `hub.Session`, performs a
  `relay:request("world-info", ...)` round-trip, extracts only six allowlisted
  fields (`worldId`, `worldTitle`, `foundryVersion`, `systemId`, `systemTitle`,
  `systemVersion`) in `session_metadata` while verifying
  `world.id == options.world`, and re-checks both `page_state == "authenticated"`
  and `owns_connection(worlds, client_id, relay)` (exact `hub.Session` identity
  equality) before publishing the `Session`.

`Session:check` re-verifies browser liveness, page authentication, and
`owns_connection`. `Session:close` defers `self.relay:close()` ahead of
`self.browser:close()`, guaranteeing that only the captured `hub.Session`
closes—even if browser retirement fails—without interrupting a later reconnect.

## Admission, `EntryState`, and two-phase HTTP publication

[`relay/sessions.titan`](../relay/sessions.titan) keeps all session handshakes,
active browsers, and per-world reservations in memory on the main thread inside
`Manager`. `Manager.new` accepts an optional `launcher` returning the narrow
`interface Client` (`metadata`, `check`, `close`), defaulting to
`default_launcher` (`foundry.start`) in production and letting native tests
inject synthetic clients without spawning Chrome.

Handshakes and admission are guarded against replay, concurrency races, and
memory retention:

- `Manager:handshake` validates the target URL (`foundry_origin`, allowing only
  `http`/`https` without query strings) against `self.origins`, prunes expired
  entries (`Manager:prune`), caps pending handshakes at 32, and issues a
  five-minute `Handshake` carrying a 32-byte random `token` and 16-byte
  `nonce`.
- `Manager:begin` deletes `self.handshakes[token] = nil` *before* checking
  expiry, decrypting, or validating JSON, so every failed attempt consumes its
  handshake. Nonce equality uses `config.secret_equal`. After listing pairings
  from `self.database:list()` and resolving `foundry.existing_client`, `begin`
  re-checks `self:available()` (because SQLite I/O can suspend while shutdown
  starts), rejects conflicting reservations or online worlds (`409`), enforces
  `self.options.maximum` (`429`), and synchronously inserts `entry` into both
  `self.entries` and `self.reservations` *before* spawning `entry.worker`.
- Inside `entry.worker`, the local `pending: foundry.Options?` (carrying the
  decrypted password) is cleared to `nil` immediately after
  `self.launcher(...)` returns or raises. Any startup error passes through
  `startup_failure`, which maps only exact relay-authored strings via
  `startup_failures` (`StartupFailure(status, stage, cause)`) and folds
  anything unrecognized into `default_startup_failure` (`500`, `"startup"`,
  `"startup_failed"`).

Session lifecycle transitions are governed by the closed five-variant union
`EntryState` (`starting()`, `active()`, `stopping()`, `stopped()`,
`cleanup_failed()`) with preallocated unit singletons (`STATE_STARTING` through
`STATE_CLEANUP_FAILED`). Once `launcher` succeeds, the worker transitions to
`STATE_ACTIVE`, signals `entry:notify()`, and polls `client:check(self.worlds)`
every second. On exit, error, or cancellation,
`defer self:retire(entry, client)` runs `client:close()`. If retirement
succeeds, `Manager:retire` transitions to `STATE_STOPPED` and clears both
`self.entries[session_id]` and `self.reservations[client_id]`. If retirement
fails, `retire` transitions to `STATE_CLEANUP_FAILED` and deliberately retains
both map entries so no second browser can be admitted for that world and
subsequent `Manager:finish` or `Manager:close` calls surface HTTP `503`.

```titan
local function Manager:retire(entry: Entry, client: Client?)
  if self.entries[entry.session_id] ~= entry then return end
  local failed = false
  case entry.state
  when cleanup_failed() then failed = true
  end
  entry.state = STATE_STOPPING
  if client then
    do client:close()
    catch failed = true
    end
  end
  if failed then
    entry.state = STATE_CLEANUP_FAILED
    log.emit(self.logger, "error", "headless_session_cleanup_failed", {["client_id"] = entry.client_id,
      ["reason"] = "browser_retirement_failed"})
  else
    entry.state = STATE_STOPPED
    self.entries[entry.session_id] = nil
    if self.reservations[entry.client_id] == entry then self.reservations[entry.client_id] = nil end
    log.emit(self.logger, "info", "headless_session_stopped", {["client_id"] = entry.client_id})
  end
  entry:notify()
end
```
*Source: [`relay/sessions.titan`](../relay/sessions.titan) — `Manager:retire`*

Publishing a new session over HTTP uses a two-phase coordinator handshake so a
client disconnect mid-startup or during response write never strands an
unacknowledged browser. In [`relay/api_worker.titan`](../relay/api_worker.titan),
`session_start` generates a provisional `key`, registers
`defer control.notify(..., ControlAction.session_discard(key))`, sends
`ControlAction.session_start(key, source)` to the main thread, writes and
commits (`ctx:commit()`) the `200` JSON response, and only then sends
`ControlAction.session_publish(key)` (calling `ctx:abort()` if publication fails).
On the main thread, `Server:coordinate` in
[`relay/server.titan`](../relay/server.titan) executes `Manager:begin` inside
`worlds:transition`, records the `Entry` in `self.provisional[key]`, awaits
`Manager:ready(entry)` (suspending on `entry.wake` until `entry:notify()`), and
discards the provisional entry if the reply channel closes or `try_send` fails.
`Manager:list` exposes only entries where `state` is `active()` and
`entry.published` is true. Only `ControlAction.session_publish` calls
`Manager:publish` and removes `self.provisional[key]`; if the HTTP worker
aborts or cancels first, the deferred `session_discard` calls
`Server:discard_provisional` and `Manager:discard`, retiring the unpublished
browser cleanly.

---

← Previous: [Chapter 3: Cooperative SQLite Persistence, Configuration, and Structured Logging](persistence-and-logging.md) | [Table of Contents](index.md) | Next: [Appendix A: Native Builds, Windows Packaging, Testing, and Retired Records](build-and-testing.md) →
