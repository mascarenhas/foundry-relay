# Threads and request ownership

The relay runs three kinds of Titan OS thread. Each has its own Lua state,
async Runtime, and Tasks. They share no Titan objects and communicate only
through bounded `thread.channel` endpoints.

- **Main thread**, `relay/server.titan` `Server`, runs the HTTP listener, the
  coordinator (`Server:control_loop`), the dispatcher for returned keep-alive
  requests, and the logging sink. It also owns the live world directory and
  event-stream registry (`relay/hub.titan` `Hub`) and the headless session
  manager (`relay/sessions.titan` `Manager`).
- **API workers**, `relay/api_worker.titan` `run`, are
  `RELAY_API_CONCURRENCY` persistent threads that start before the listener
  opens.
- **World threads**, `relay/world.titan` `run`, are started one per module
  connection by `Server:start_world`.

## Dispatch

The listener disables read-ahead, so connections are read only on demand.
After it parses a request's headers, `Server:handle` converts the exchange,
including any bytes already buffered, into a transfer payload.
`Server:deliver` then starts a world thread for `/relay` with a nonempty `id`
and sends every other request to the next API worker in round-robin order.

On a keep-alive connection, the API worker handles the first request itself.
Each later request returns to the main dispatcher, which takes the next worker
from the same round-robin cursor, or starts a world thread for a `/relay`
upgrade. The listener and each adopted exchange wait at most 10 seconds for
request headers. That deadline does not time handlers, bodies, response
writes, or event streams. A connection still waiting for its first headers
stays with the main thread's HTTP server.

| Channel | Carries | Capacity | Direction |
| --- | --- | ---: | --- |
| `controls` | `messages.ControlRequest` | 256 | workers to coordinator |
| `returned` | `messages.Handoff` | 128 | API workers to dispatcher |
| `log_lines` | encoded log records | 1,024 | workers to logging sink |
| API worker inbox | `messages.Handoff` | 128 | dispatcher to one worker |
| world `requests` | `world_protocol.WorldRequest` | `RELAY_MAX_PENDING` | API workers to one world |
| world `commands` | `world_protocol.WorldCommand` | 256 | main to one world |
| world `health` | nothing; closed by main after joining the thread | 1 | main to everyone holding the handle |
| reply lease | `world_protocol.WorldReply` | 1 | world to one API worker |
| subscriber | event text | 128 | world to one event stream |

HTTP exchanges cross threads as manually owned transfer payloads, never as
live connection values. A sender owns the payload until enqueue succeeds.
After that the receiving thread adopts it at once, or the channel's owner
disposes of it with `http.Exchange.discard_transfer_payload` after the
consumer has joined (`relay/messages.titan` `Handoff`).

## World requests and replies

API workers send requests directly to the selected world's `requests`
channel. A `WorldRequest` carries the request ID, the action, the complete
wire JSON, an absolute deadline, and the sending endpoint of a reply lease.
The world's `Engine` owns correlation, the reader, the writer, the heartbeat,
the output queue (at most `RELAY_MAX_PENDING` + 16 messages), and the
pending-request limit. Just before writing queued work, it checks again that
the request is still pending, uncancelled, and within its deadline
(`Outgoing:should_send`). Requests are never replayed after possible
transmission.

Each API worker owns a `relay/replies.titan` `Pool` of four reply-channel
leases. A request exclusively acquires a lease, sends its endpoint, receives
its matching reply, and returns the lease. Waiters are served FIFO, and the
wait counts against the request's [deadline](api.md#deadlines-and-failures).
Timeout, cancellation, or uncertain completion closes and replaces the lease,
so a late reply cannot reach a later borrower, and request IDs reject duplicate
or stale messages. The leases limit each worker to four simultaneous world
calls, independently of the thread count. Leases exist because reusing a reply
channel is cheaper than creating one and transferring its endpoint for every
request. Headless readiness checks on the main thread use a one-lease pool
(`hub.Session:request`).

A world failure fails its pending calls with 503 and retires that exact
connection. An API worker that terminates unexpectedly makes the server log
`server_failed` and shut down rather than silently lose capacity; a world
thread's exit affects only its own connection.

`Server:shutdown` closes the listener, then cancels and awaits coordinator
operations. It closes the session manager and the world directory, then
cancels and joins the API workers. Each worker cancels and awaits the Tasks
serving its exchanges and disposes of queued payloads. Next the world threads
are cancelled and joined, and the coordinator, dispatcher, and logging
channels close. The main thread's Store closes last. Each worker closes its
own Store handle and forwarding logger as it exits.

## Persistent state and live coordination

Each thread uses its own `relay/store.titan` `Store` handle. The main thread
creates the handle with `store.open`, which restricts the database to mode
0600 before creating the schema. Workers use `store.attach`, which does no
schema work. A handle runs its operations one at a time in FIFO order, and
each operation opens and closes its own SQLite connection. Writers reserve the
database with `BEGIN IMMEDIATE`, and SQLite's busy timeout is zero. On
`SQLITE_BUSY`, the failed operation rolls back and closes its connection,
then retries with a backoff that starts at 1 ms and doubles up to 25 ms. The
retry budget is five seconds from FIFO admission. Cancellation and other
errors propagate, and a committed write is never replayed.

Coordinator requests (`relay/control.titan` `call`) carry data and channel
endpoints only. `Hub:transition` serializes changes to the world directory.
Once a revoke or delete transition is admitted, `Server:coordinate` runs it in
an independent Task. That Task completes both the credential mutation and the
retirement of the captured connection even if the API caller is cancelled.

When a module reconnects, `Hub:publish_authenticated` first quiesces the
incumbent world. The world stops admitting requests, fails its pending
requests with 503, and cancels and joins its data writer before
acknowledging. Only then is the replacement published, and the incumbent's
graceful Close 1000 runs in the background. Revocation, deletion, and
shutdown retire connections without a graceful Close. Headless cleanup
retires only the exact connection it captured.

Event streams run in API workers. Worlds write events directly into the
bounded subscriber channels that the main registry owns; the
[event streams](api.md#event-streams) section gives their contract.
