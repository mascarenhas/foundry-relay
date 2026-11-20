# Chapter 1: Multi-Threaded Architecture, Channel Ownership, and World Lifecycle

A relay sits between many short-lived REST and SSE clients and long-lived Foundry VTT WebSocket connections. Isolating those roles into separate OS threads prevents a slow JSON body, a burst of HTTP traffic, or a stalled browser session from delaying heartbeats and message correlation on a live world socket.

Titan threads share no Lua state, heap objects, or async `Runtime`. Every thread creates its own Lua state and communicates only through bounded `thread.channel` endpoints carrying immutable values, arrays, records, unions, or transferred channel endpoints. `foundry-relay` organizes its threads into three roles:

- **Main thread** ([`main.titan`](../main.titan), [`relay/server.titan`](../relay/server.titan)) — owns the HTTP listener, the coordinator (`Server:control_loop`), the keep-alive return dispatcher (`return_task`), the main `stderr` log sink (`log_task`), the live world directory and SSE subscriber registry (`Hub` in [`relay/hub.titan`](../relay/hub.titan)), and the headless browser session manager (`Manager` in [`relay/sessions.titan`](../relay/sessions.titan)).
- **API workers** (`run` in [`relay/api_worker.titan`](../relay/api_worker.titan)) — `RELAY_API_CONCURRENCY` persistent threads spawned before the listener opens. Each parses HTTP targets, enforces origin and API-key checks, translates REST endpoints, and drives SSE streams.
- **World threads** (`run` in [`relay/world.titan`](../relay/world.titan)) — spawned on demand by `Server:start_world`, one per Foundry module connection. Each owns one authenticated WebSocket transport and all of its framing, heartbeat, and correlation Tasks.

## Signal-safe startup and shielded retirement

`main` in [`main.titan`](../main.titan) creates the `log.Logger` first and registers `defer logger:close()` before calling `run`, ensuring final shutdown diagnostics flush only after the server and every worker thread have retired. If `RELAY_LOG_LEVEL` itself is invalid, `main` writes a fixed JSON record through `log.fatal` and exits with status `1`.

Inside `run`, `config.load` validates environment variables before `Server.new` touches SQLite or spawns threads. Once `relay:start()` opens the listener, `run` spawns two signal Tasks waiting on `os.wait_signal("term")` and `os.wait_signal("int")`. Both invoke `relay:close()` and capture any retirement failure into `shutdown_error`. Because closing the listener wakes `relay:serve()` before headless browser retirement finishes, `run` drains both signal Tasks after `relay:serve()` returns and re-raises `shutdown_error` so a failed teardown produces exit status `1`.

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

## Dispatch

`Server:start` starts the coordinator, return dispatcher, and log Tasks, spawns all API workers (waiting on each worker's one-shot capacity-1 `ready` channel via `wait_ready`), and opens `http.listen` with a 128-connection backlog and a 10-second header deadline. It immediately calls `listener:read_ahead(false)` so the HTTP server reads from accepted sockets only on demand.

When headers for a request arrive, `Server:handle` yields once with `async.yield()` so the socket never detaches from inside the final native read callback on Windows. It then serializes the connection and any buffered request bytes into a transfer payload via `http.Exchange(request, response):to_transfer_payload()`, wraps that byte string in `messages.Handoff`, and calls `Server:deliver`.

```titan
local function Server:deliver(opening: messages.Handoff)
  local consumed = false
  defer if not consumed then http.Exchange.discard_transfer_payload(opening.payload) end
  if self.closed then return end
  local match? = self:classify(opening.method, opening.target)
  if match then
    local slot = self:start_world(match)
    defer if not consumed then slot.worker:cancel(); tasks.await_terminal(slot.monitor) end
    if self.closed then return end
    -- ...
    if not slot.sender:try_send(world.Opening(opening.delivery_id, opening.payload,
        match.query["worldTitle"] or "", match.query["version"] or "", wire.encode(metadata))) then
      raise "world opening inbox is full"
    end
    consumed = true
  else
    local slot = self.api_workers[self.next_api]
    self.next_api = self.next_api % #self.api_workers + 1
    -- Sender.send returns immediately after enqueue commits; cancellation while
    -- waiting for space unregisters its waiter without committing the message.
    slot.sender:send(opening)
    consumed = true
  end
end
```
*Source: [`relay/server.titan`](../relay/server.titan) — `Server:deliver`*

`Server:classify` checks the request against `routes.create()`. A `GET /relay` request with a nonempty `id` query parameter spawns a dedicated world thread through `Server:start_world` and sends a `world.Opening` through its capacity-1 `opening` channel. Every other request goes to the next API worker in round-robin order.

On an HTTP/1.1 keep-alive connection, `run` in [`relay/api_worker.titan`](../relay/api_worker.titan) adopts the `Handoff` with `http.Exchange.from_transfer_payload` before yielding and hands it to a child Task running `exchange:serve(..., 10000)`. That worker handles the first request itself; every subsequent request on the same connection yields once, converts back to a transfer payload, and sends a fresh `Handoff` onto `bootstrap.returned`. The main thread's `return_task` feeds returned exchanges back into `Server:deliver`, advancing the round-robin cursor or promoting a keep-alive `/relay` upgrade to a new world thread. The 10-second timeout bounds header arrival only—never request bodies, response writes, or SSE streams. A connection awaiting its very first headers stays inside the main listener.

Nine steady-state bounded channels connect the three thread roles (in addition to the one-shot capacity-1 `ready` and `opening` startup channels):

| Channel | Carries | Capacity | Direction |
| --- | --- | ---: | --- |
| `controls` | `messages.ControlRequest` | 256 | API and world workers to coordinator |
| `returned` | `messages.Handoff` | 128 | API workers to main dispatcher |
| `log_lines` | encoded JSON log lines (`string`) | 1,024 | API and world workers to main logging sink |
| API worker inbox | `messages.Handoff` | 128 | main dispatcher to one API worker |
| world `requests` | `world_protocol.WorldRequest` | `RELAY_MAX_PENDING` | API workers to one world |
| world `commands` | `world_protocol.WorldCommand` | 256 | main to one world |
| world `health` | `nil`; closed by main after `worker:join()` | 1 | main monitor to every holder of `WorldHandle` |
| reply lease | `world_protocol.WorldReply` | 1 | world to one API worker |
| subscriber | event JSON (`string`) | 128 | world to one SSE stream |

Transfer payloads hold native socket descriptors outside Lua's garbage collector, so ownership obeys a strict three-state invariant (`Handoff` in [`relay/messages.titan`](../relay/messages.titan)):

1. **Pre-enqueue**: the sender owns the payload and protects it with `defer if not consumed then http.Exchange.discard_transfer_payload(payload) end`.
2. **In-flight**: once `send` or `try_send` succeeds, the channel owns the payload until its sole consumer dequeues and calls `from_transfer_payload` without an intervening yield.
3. **Post-join cleanup**: if the consumer terminates with unread messages queued, the worker's `defer` drains its own inbox via `try_receive()` without closing it, and the supervisor closes the producer endpoint before running `discard_handoffs` or `discard_openings` after `worker:join()`. Keeping the receiver open until the producer closes guarantees that a concurrently enqueued raw socket is never discarded inside a closed channel.

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

Inside [`relay/world.titan`](../relay/world.titan), `execute` attaches to SQLite (`store.attach`), adopts `world.Opening`, enforces `settings:request_origin_allowed`, upgrades the WebSocket with `websocket.accept` (16 MiB `read_limit`, `auth_timeout`), and waits for the first text `auth` frame under an `auth_timeout` deadline Task. After verifying the token locally and updating client metadata in SQLite, it sends `ControlAction.auth_publish(bootstrap.handle, token)` to the coordinator, which re-authenticates inside `Hub:transition` so a concurrent revocation cannot be raced. Upon receiving `ControlReply.published(activation)`, `execute` installs active SSE subscriber targets, writes `{"type":"auth-success"}`, starts `write_loop`, `heartbeat_loop`, and `request_loop`, pushes initial `event-subscription-update` counts, and enters `read_loop`.

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

Failure domains follow thread ownership. When a world thread exits, `Server:start_world`'s monitor closes `health_tx` (waking every waiting `Pool:wait_reply` and any quiescence handshake), closes the world's channels, discards unread openings, and calls `self.worlds:retire(handle.client_id, handle.key)`, affecting only that world's pending calls (503). By contrast, if an API worker thread exits while `not self.closed`, its monitor records `self.failure`, logs `server_failed` (`reason = "api_worker_failed"`), and calls `self:begin_close()` so the relay shuts down rather than silently losing request capacity.

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

- **Module reconnect (`Hub:publish_authenticated`)**: under `Hub:transition`, an existing `Session` for the same `client_id` runs `old:quiesce("replacement")`, which sends `WorldCommand.quiesce` and races its boolean `ack` against `self:terminal` (`health:receive_result()`). Inside `Engine:quiesce`, the incumbent stops admitting requests, closes `outbox`, completes every pending request with `503`, cancels `self.writer` before yielding to drain deadline Tasks, and awaits `self.writer`'s termination before sending `ack`. Only then—and after `async.checkpoint()` confirms the newcomer was not cancelled—does `Hub:publish_authenticated` install the replacement `Session`, snapshot active SSE subscriptions into an `Activation`, and launch `old:stop(true)` in the background to send WebSocket Close `1000` (`Replaced by reconnect`).
- **Credential revocation and deletion (`Server:retire_credential`)**: `POST /api/self-unpair` (`revoke`) and `DELETE /clients/:clientId` (`delete_client`) spawn an independent Task awaited via `tasks.await_terminal`. Once admitted, both the SQLite mutation (`database:revoke` or `database:remove`) and `worlds:disconnect(id)` followed by `retired:close()` complete even if the HTTP caller disconnects. Revocation, deletion, and shutdown call `stop(false)` without a graceful WebSocket Close frame; headless cleanup ([Chapter 4](headless-sessions.md)) retires only the exact `hub.Session` instance it captured.

`Server:shutdown` runs inside a single `Server.retirement` Task created by `Server:begin_close` and awaited by `Server:close` via `tasks.await_retirement`. Its teardown order preserves every channel-ownership invariant:

1. Close the HTTP listener so no new connections arrive.
2. Cancel and drain active coordinator `operations`, then close `self.headless` (`sessions.Manager:close`) and `self.worlds` (`Hub:close`) and clear `self.unclaimed`.
3. Cancel and join all `api_workers`, await their monitors, discard unread `Handoff` payloads, and close their channels. `control_loop` stays alive throughout this phase so cancelled HTTP Tasks can deliver `unsubscribe` and `session_discard` cleanup notices.
4. Cancel and join all `world_workers`, close `health`, await their monitors, discard unread `Opening` payloads, and close their channels.
5. Discard any remaining `provisional` headless session entries.
6. Close `controls` and await `control_task` plus any final cleanup operations; close `returned`, await `return_task`, and discard unread handoffs; close `log_lines` and await `log_task`.
7. Close `self.database` last. Each worker closes its own `Store` handle and forwarding `Logger` as it exits.

Event streams run inside API workers while world threads write events directly into the bounded subscriber channels registered in `Hub`; [Chapter 2](routing.md) details that streaming and fanout path, and [api.md](api.md#event-streams) defines the external SSE contract.

---

← [Table of Contents](index.md) | Next: [Chapter 2: Declarative Routing, Request Translation, and Event Streaming](routing.md) →
