# Chapter 1: Multi-Threaded Architecture, Channel Ownership, and World Lifecycle

A relay sits between many short-lived REST and SSE clients and long-lived Foundry VTT WebSocket connections. Isolating those roles into separate OS threads prevents a slow JSON body, a burst of HTTP traffic, or a stalled browser session from delaying heartbeats and message correlation on a live world socket.

Titan threads share no Lua state, heap objects, or async `Runtime`. Every thread creates its own Lua state and communicates only through bounded `thread.channel` endpoints carrying immutable values, arrays, records, unions, or transferred channel endpoints. `foundry-relay` organizes its threads into three roles:

- **Main thread** ([`foundry_relay.titan`](../foundry_relay.titan), [`relay/server.titan`](../relay/server.titan)) — owns the `mk.App` HTTP listener and worker supervisor, the coordinator (`Server:control_loop`), the live world directory and SSE subscriber registry (`Hub` in [`relay/hub.titan`](../relay/hub.titan)), the headless browser session manager (`Manager` in [`relay/sessions.titan`](../relay/sessions.titan)), and the main `mk.log.Logger` `stderr` sink.
- **API pool workers** (`WorkerMode.pool` in [`relay/routes.titan`](../relay/routes.titan), handlers in [`relay/api_worker.titan`](../relay/api_worker.titan)) — `RELAY_API_CONCURRENCY` persistent `mk` pool threads spawned during `App:start()`. Each attaches its own SQLite `Store` and 4-lease reply `Pool` in `on_start`, enforces origin/target/API-key middleware, translates REST endpoints, and drives SSE streams.
- **World session workers** (`WorkerMode.session` with `ephemeral = true` in [`relay/routes.titan`](../relay/routes.titan), engine in [`relay/world.titan`](../relay/world.titan)) — spawned on demand by `mk.App` for each `/relay?id=<clientId>` opening via `world.select_session`. Each attaches its own `Store`, upgrades the WebSocket via `ctx:upgrade_websocket`, authenticates, and owns all framing, heartbeat, and correlation Tasks for one Foundry module connection.

## Signal-safe startup and shielded retirement

`main` in [`foundry_relay.titan`](../foundry_relay.titan) creates the `mk.log.Logger` first (`log.resolve_level(os.getenv("RELAY_LOG_LEVEL"), false, "RELAY_LOG_LEVEL")`) and registers `defer logger:close()` before calling `run`, ensuring final shutdown diagnostics flush only after the server and every worker thread have retired. If `RELAY_LOG_LEVEL` itself is invalid, `main` writes a fixed JSON record through `log.fatal` and exits with status `1`.

Inside `run`, `config.load` validates environment variables before `Server.new` touches SQLite or constructs the `mk.App`. Once `relay:start()` starts `control_loop` and calls `self.app:start(...)` (spawning the API pool workers and opening the listener), `run` spawns two signal Tasks waiting on `os.wait_signal("term")` and `os.wait_signal("int")`. Both invoke `relay:close()` and capture any retirement failure into `shutdown_error`. Because closing the listener wakes `relay:serve()` before headless browser retirement finishes, `run` drains both signal Tasks after `relay:serve()` returns and re-raises `shutdown_error` so a failed teardown produces exit status `1`.

All teardown paths in the relay rely on [`relay/tasks.titan`](../relay/tasks.titan). When a caller's Task is cancelled, ordinary suspending operations abort immediately with `async.CancellationReason`. Waiting for a child Task, a worker join, or a browser retirement inside `defer` therefore wraps `task:add_terminal_listener` in `async.await_cleanup`, shielding the cleanup wait from outer cancellation while preserving deterministic listener removal.

```titan
-- Cleanup must outlive cancellation of the caller that owns it.
function await_terminal<|T|>(task: async.Task<|T, value|>)
  if task:status():has_finished() then return end
  local remove: (function (): ())? = nil
  defer if remove then remove() end
  async.await_cleanup<|nil, nil|>(function (resolve, _reject, _fatal)
    if task:status():has_finished() then resolve(nil)
    else remove = task:add_terminal_listener(function (_) resolve(nil) end)
    end
  end)
end

function drain<|T|>(task: async.Task<|T, value|>)
  if not task:status():has_finished() then task:cancel() end
  await_terminal(task)
end

function await_retirement(task: async.Task<|async.Error?, value|>, cancelled_message: string)
  await_terminal(task)
  case task:status()
  when succeeded(failure) then if failure then failure:raise() end
  when failed(failure) then failure:raise()
  else raise cancelled_message
  end
end
```
*Source: [`relay/tasks.titan`](../relay/tasks.titan) — `await_terminal`, `drain`, `await_retirement`*

## Dispatch and worker ownership

[`relay/routes.titan`](../relay/routes.titan) configures the `mk.App` with `WorkerMode.pool(mk.PoolOptions { size = settings.api_concurrency, on_start = api_worker.initializer(settings, coordinator) })` as the default mode for REST and SSE routes, and attaches `WorkerMode.session(mk.SessionOptions { session_id = world.select_session, ephemeral = true, on_start = world.initializer(settings, coordinator), on_exit = world_exited })` specifically to `GET /relay`.

`titan-mk` owns HTTP listener accept, `read_ahead(false)` demand reads, `http.Exchange` socket detachment and handoff to worker threads, HTTP/1.1 keep-alive `return_pipe` round-trips back to the parent for fresh classification, and cross-thread log forwarding (`mk.log.forward`). When a `/relay` request arrives, `world.select_session` runs on the parent against read-only `mk.RequestMeta`:

```titan
--- Parent-side session selector: every `/relay?id=...` opening gets its own
-- ephemeral worker, keyed `opening_key .. ":" .. client_id`.
function select_session(meta: mk.RequestMeta): string?
  local client_id = meta:query("id", "")
  if client_id == "" then raise mk.HttpError(400, "id is required") end
  return store.secure_token(16) .. ":" .. client_id
end
```
*Source: [`relay/world.titan`](../relay/world.titan) — `select_session`*

A missing `id` raises `mk.HttpError(400, "id is required")` on the parent without spawning a thread; every valid opening receives a unique `opening_key:client_id` session key so `mk.App` spawns a dedicated ephemeral session worker for that connection alone. All other routes dispatch round-robin across the `RELAY_API_CONCURRENCY` pool workers.

Per-worker resources live in module-level `local state` variables initialized inside `on_start(wctx)` and torn down LIFO by `wctx:defer_cleanup(...)`: `api_worker.initializer` attaches a `Store` and a 4-lease `replies.Pool`, while `world.initializer` attaches a `Store`.

Six relay-owned bounded channels connect the three thread roles (alongside `mk`'s internal worker intake pipes, keep-alive `return_pipe`, and log-forwarding channel):

| Channel | Carries | Capacity | Direction |
| --- | --- | ---: | --- |
| `controls` | `messages.ControlRequest` | 256 | API and world workers to coordinator |
| world `requests` | `world_protocol.WorldRequest` | `RELAY_MAX_PENDING` | API workers to one world |
| world `commands` | `world_protocol.WorldCommand` | 256 | main to one world |
| world `health` | `nil`; closed by main in `world_exited` after OS join | 1 | main `on_exit` observer to every holder of `WorldHandle` |
| reply lease | `world_protocol.WorldReply` | 1 | world to one API worker |
| subscriber | event JSON (`string`) | 128 | world to one SSE stream |

Coordinator requests (`ControlRequest` in [`relay/messages.titan`](../relay/messages.titan)) carry only typed data and channel endpoints—never raw HTTP transports. When `Server:publish_world` publishes a world, it allocates `requests`, `commands`, and `health` channels on the main thread, keeps the `Sender` ends plus `health_tx` in `self.world_slots[opening_key]` (`WorldSlot`), and transfers the sole `requests_rx` and `commands_rx` receivers to the world worker inside `ControlReply.published(...)`.

## World requests and replies

[`relay/world_protocol.titan`](../relay/world_protocol.titan) holds the cross-thread data-transfer types shared by main, API workers, and world threads: `WorldHandle`, `WorldRequest`, `WorldReply`, the five-variant `WorldCommand` union (`quiesce`, `stop`, `cancel`, `subscribe`, `unsubscribe`), `Subscription`, `SubscriptionTarget`, `ChannelCount`, `Activation`, and `SSE_CHANNELS`.

After resolving a world's `WorldHandle` through the coordinator, an API worker sends a `WorldRequest` directly to `handle.requests`, bypassing the main thread on the data path. Each `WorldRequest` carries a random `request_id`, the Foundry `action`, the complete wire JSON (`type` and `requestId` injected, `clientId` stripped), a monotonic `deadline_ns` from `uv.hrtime()`, and the sending endpoint of a reply lease.

Creating a fresh `thread.channel` and transferring a new endpoint per HTTP request adds avoidable allocation and synchronization overhead. Each API worker therefore owns a `Pool` ([`relay/replies.titan`](../relay/replies.titan)) of four pre-allocated capacity-1 `thread.channel<|WorldReply|>` leases (and `hub.Session:request` creates a temporary one-lease pool for low-rate headless readiness probes on the main thread). `Pool:acquire` serves concurrent Tasks on the worker in strict FIFO order using `async.ResumeToken` and `async.suspend`; `Pool:release` sets `lease.busy = true` and assigns `waiter.lease = lease` *before* calling `waiter.task:resume(waiter.token)` so a newcomer cannot barge while the woken Task waits in the ready queue. Wait time counts against the request's [deadline](api.md#deadlines-and-failures).

`Pool:wait_reply` runs three concurrent Tasks—`operation` (acquiring the lease, sending `WorldRequest`, and reading matching replies), `deadline` (`timer.sleep` until `deadline_ns`), and `health` (waiting for `handle.health` closure)—and settles them with `async.race_three`:

```titan
local function Pool:wait_reply(handle: protocol.WorldHandle, action: string,
                              payload: {string: value}, timeout_ms: integer): protocol.WorldReply
  -- ...
  defer do
    tasks.drain(operation)
    tasks.drain(deadline)
    tasks.drain(health)
  end
  case async.race_three(operation, deadline, health)
  when first(status) then
    case status
    when succeeded(received) then return received
    when failed(failure) then failure:raise()
    when cancelled(reason) then raise reason
    else raise "reply operation did not finish"
    end
  when second() then return reply(id, 408, "Foundry request timed out")
  when third() then return reply(id, 503, "Foundry world is offline")
  end
  raise "reply operation did not finish"
end
```
*Source: [`relay/replies.titan`](../relay/replies.titan) — `Pool:wait_reply`*

If `operation` returns cleanly with a reply matching `id` before `deadline_ns`, it marks `reusable = true` and `Pool:release` hands the same channel to the next waiter. Any timeout, cancellation, or transport failure leaves `reusable = false`: `operation`'s `defer` closes `lease.receiver`, sends an advisory `WorldCommand.cancel(id)` with `try_send`, and `Pool:release` closes both endpoints and replaces them with a fresh channel. Closing `lease.receiver` discards queued packets and invalidates every earlier transferred `Sender` so a late Foundry response can never contaminate a later borrower; matching `received.request_id == id` likewise discards any duplicate reply on a reused channel. `Pool:request` inspects the final status and emits the single `request_timeout` log event whenever a call finishes with `408`.

Inside [`relay/world.titan`](../relay/world.titan), `handle_relay` calls `serve`, which extracts `opening_key` and `client_id` from `ctx:session_id()`, upgrades the WebSocket via `ctx:upgrade_websocket(websocket.AcceptOptions { allowed_origins = worker.settings.origins, read_limit = 16777216, handshake_timeout = worker.settings.auth_timeout })`, and waits for the first text `auth` frame under an `auth_timeout` deadline Task. After verifying the token locally and updating client metadata in SQLite, it sends `ControlAction.auth_publish(session_id, opening_key, client_id, token)` to the coordinator.

On the main thread, `Server:publish_world` runs credential authentication, live-worker verification (`self.app:session_worker(session_key)`), slot allocation (`WorldSlot`), and `self.worlds:publish_authenticated(handle, publishable)` inside a single `Hub:transition`. The `publishable` callback re-checks that the relay is open, `health_rx` is open, the same worker is still alive, and the reply channel is still open **after** any incumbent world's `quiesce` + `async.checkpoint()`. If `publishable` fails—or if `control_loop` cannot deliver `ControlReply.published` via `try_send`—`Server:abandon_world` retires the `Hub` entry, sends best-effort `WorldCommand.stop(false)`, closes the `requests` and `commands` `Sender`s, and calls `self.app:stop_worker(slot.worker_id)` without joining the worker itself. Upon receiving `ControlReply.published(activation, _, granted_requests, granted_commands)`, `serve` constructs `Engine(Link(...), connection, logger)`, installs active SSE subscriber targets, writes `{"type":"auth-success"}`, starts `write_loop`, `heartbeat_loop`, and `request_loop`, broadcasts all six subscription counts, and enters `engine:read_loop()`.

`Engine` keeps correlation (`pending`, bounded by `RELAY_MAX_PENDING`), a per-request deadline Task, and a non-suspending `async.BufferedSubscription<|Outgoing, string|>` (`outbox`) capped at `RELAY_MAX_PENDING + 16` queued frames. Immediately before writing a queued frame to the WebSocket, `Engine:write_loop` re-checks liveness via `Outgoing:should_send`:

```titan
local record Outgoing
  const text: string
  const request_id: string?
  const kind: string?
end

local function Outgoing:should_send(pending_requests: {string: Pending}): boolean
  if not self.request_id then return true end
  local pending? = pending_requests[self.request_id]
  return pending ~= nil and not pending.completed and not pending.job.reply:is_closed() and uv.hrtime() < pending.job.deadline_ns
end
```
*Source: [`relay/world.titan`](../relay/world.titan) — `Outgoing`, `Outgoing:should_send`*

If the caller timed out or disconnected while the request sat in `outbox`, `write_loop` discards the frame and removes the pending slot without transmitting it to Foundry. Once a frame is handed to `connection:write`, requests are never retried.

Failure domains follow `titan-mk`'s worker isolation model. When an ephemeral world session worker exits, `mk.App` invokes `Server:world_exited(session_id, worker_id)` (`SessionOptions.on_exit`) strictly **after** the worker's OS thread has joined: `world_exited` removes `self.world_slots[key]`, closes `slot.health` (waking every waiting `Pool:wait_reply` and any quiescence handshake), closes `requests`/`commands` `Sender`s, and calls `self.worlds:retire(slot.client_id, key)`, affecting only that world's pending calls (`503`). By contrast, if a pool worker exits outside shutdown, `mk.App` triggers forced shutdown and raises the failure from `self.app:serve()` so `Server:serve()` shuts down cleanly and propagates the error rather than silently losing request capacity. Likewise, if `control_loop` fails unexpectedly, it closes `controls`, records `self.failure`, and calls `self.app:initiate_shutdown()`.

## Persistent state and live coordination

Each thread opens its own cooperative SQLite `Store` handle ([`relay/store.titan`](../relay/store.titan)): the main thread runs `store.open` (enforcing `0600` before creating the schema), while API and world threads call schema-free `store.attach`. [Chapter 3](persistence-and-logging.md) details FIFO `Store` serialization, `BEGIN IMMEDIATE` transactions, cooperative `SQLITE_BUSY` retry, and cross-thread log forwarding.

Live coordination between workers and the main thread runs over typed closed unions (`ControlAction` and `ControlReply` in [`relay/messages.titan`](../relay/messages.titan)) rather than internal JSON strings, transferring records, `const {string}` arrays, and channel endpoints directly. [`relay/control.titan`](../relay/control.titan) implements the client side:

```titan
function call(sender: thread.Sender<|messages.ControlRequest|>, worker_id: integer,
    action: messages.ControlAction): messages.ControlReply
  local tx, rx = thread.channel<|messages.ControlReply|>(1)
  local id = store.secure_token(16)
  local completed = false
  defer do
    rx:close()
    tx:close()
    if not completed then notify(sender, worker_id, cancel_action, id) end
  end
  sender:send(messages.ControlRequest(id, worker_id, action, tx))
  local reply = rx:receive()
  case reply
  when subscribed() then
    notify(sender, worker_id, claim_action, id)
  end
  completed = true
  return reply
end
```
*Source: [`relay/control.titan`](../relay/control.titan) — `call`*

`control.notify` sends one-way control messages (`cancel`, `claim`, `unsubscribe`, `session_discard`) inside a dedicated child Task awaited with `tasks.await_terminal`, so cleanup signals survive cancellation of the caller. When `Server:coordinate` grants a `subscribe` request, it records the new `Subscription` in `self.unclaimed[request_id]` until `control_loop` receives `claim()`. If the worker cancels before claiming, `cancel()` (or a failed `request.reply:try_send` inside `control_loop`) immediately calls `self.worlds:unsubscribe`, preventing orphaned subscriber channels.

Directory mutations in [`relay/hub.titan`](../relay/hub.titan) serialize through `Hub:transition`, a Task-reentrant FIFO gate built on `Hub:acquire` and `Hub:release` (`async.ResumeToken` + `async.suspend`). Same-Task reentrancy lets `sessions.Manager` admission call `Hub:online` and `Hub:select` inside an outer transition without deadlocking.

Two coordination paths require multi-step retirement:

- **Module reconnect (`Hub:publish_authenticated`)**: under `Hub:transition`, an existing `Session` for the same `client_id` runs `old:quiesce("replacement")`, which sends `WorldCommand.quiesce` and races its boolean `ack` against `self:terminal` (`health:receive_result()`). Inside `Engine:quiesce`, the incumbent stops admitting requests, closes `outbox`, completes every pending request with `503`, cancels `self.writer` before yielding to drain deadline Tasks, and awaits `self.writer`'s termination before sending `ack`. Only then—after `async.checkpoint()` confirms the newcomer was not cancelled and `can_publish()` (`publishable`) still holds—does `Hub:publish_authenticated` install the replacement `Session`, snapshot active SSE subscriptions into an `Activation`, and launch `old:stop(true)` in the background so the incumbent closes gracefully with WebSocket code `1000`.
- **Credential revocation and deletion (`Server:retire_credential`)**: `POST /api/self-unpair` (`revoke`) and `DELETE /clients/:clientId` (`delete_client`) spawn an independent Task awaited via `tasks.await_terminal`. Once admitted, both the SQLite mutation (`database:revoke` or `database:remove`) and `worlds:disconnect(id)` followed by `retired:close()` complete even if the HTTP caller disconnects. Revocation, deletion, and shutdown call `stop(false)` without a graceful WebSocket Close frame; headless cleanup ([Chapter 4](headless-sessions.md)) retires only the exact `hub.Session` instance it captured.

`Server:shutdown` runs inside a single `Server.retirement` Task created by `Server:begin_close` and awaited by `Server:close` via `tasks.await_retirement`. `Server.new` registers `on_pre_shutdown` (`Server:close_admission`) and `on_post_shutdown` (`Server:release`) hooks on `self.app:hooks()`, so calling `self.app:shutdown()` drives teardown in exact ownership order (guarded steps record the first failure in `self.cleanup_failure`):

1. `mk.App` closes the HTTP listener so no new connections arrive.
2. **`on_pre_shutdown` (`Server:close_admission`)**: marks `self.closed = true`, cancels and drains active coordinator `operations`, closes `self.headless` (`sessions.Manager:close`) and `self.worlds` (`Hub:close`) while world workers are still alive to answer quiescence, and clears `self.unclaimed`.
3. `mk.App` aborts and drains active HTTP exchanges, cancels and joins all API pool workers and ephemeral world session workers (running worker `defer_cleanup` callbacks and `world_exited` `on_exit` hooks), drains `return_pipe`, and flushes cross-worker log forwarding.
4. **`on_post_shutdown` (`Server:release`, idempotent via `self.released`)**: discards any remaining `provisional` headless session entries, closes `controls`, awaits `control_task` and any final cleanup operations, closes `control_inbox`, and closes `self.database` last.
5. `Server:shutdown` also calls `self:release()` directly after `self.app:shutdown()` as an idempotent backstop (for example, if `self.app:shutdown()` raises before its hooks run), and returns `self.cleanup_failure` so `Server:close()` raises the first retirement error.

Event streams run inside API workers while world threads write events directly into the bounded subscriber channels registered in `Hub`; [Chapter 2](routing.md) details that streaming and fanout path, and [api.md](api.md#event-streams) defines the external SSE contract.

---

← [Table of Contents](index.md) | Next: [Chapter 2: Declarative Routing, Request Translation, and Event Streaming](routing.md) →
