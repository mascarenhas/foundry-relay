# Threads and request ownership

The main thread accepts connections and reads request headers with demand reads.
It then transfers the HTTP exchange, including buffered bytes, through a bounded
channel. Each WebSocket world connection gets a dedicated Titan OS thread. API
requests go to persistent workers in round-robin order; `RELAY_API_CONCURRENCY`
selects their count and defaults to 1. A later request on a keep-alive connection
returns to the main dispatcher and advances the same worker index. A later
`/relay` upgrade receives its own world thread.

Each handling thread owns its socket I/O and asynchronous Tasks. First and
subsequent HTTP request headers have a 10-second deadline. This deadline does
not time request handlers, bodies, response writes, or SSE streams. Connections
still waiting for their first headers remain with the standard HTTP server and
are bounded by that deadline when its listener closes.

## World requests and replies

API workers send requests directly to the selected world's channel. A message
contains a request ID, the complete wire JSON, an absolute deadline, and the
sending endpoint of a reply channel. The world owns WebSocket correlation,
reader, writer, heartbeat, output queue, and pending-request limit. It checks
cancellation and the deadline again immediately before writing queued work.
Requests are never automatically replayed after possible transmission.

Each API worker has four reply-channel leases. A request exclusively acquires a
lease, sends its endpoint, receives its matching reply, and returns the lease.
FIFO waiters share the pool. Its wait, queue admission, and response all consume
the same request deadline. Timeout, cancellation, or uncertain completion closes
and replaces the lease so a late reply cannot reach a later borrower. Request
IDs also reject duplicate or stale messages. The four leases bound each API
worker to four simultaneous world calls; the OS thread count is independent.

World failure fails pending calls with 503 and retires that exact connection.
Unexpected API-worker termination closes the server and reports failure rather
than silently reducing configured concurrency. Shutdown cancels and joins owned
HTTP and world Tasks before their database handles and logging queues close.
Native payloads use explicit adoption or disposal; they are never embedded as
live connection values in a generic channel message.

## Persistent state and live coordination

API and world workers use independent Store handles and SQLite connections for
ordinary database operations. Writers reserve a transaction with `BEGIN
IMMEDIATE`. SQLite busy waits are disabled: a complete failed operation rolls
back and closes its connection before retrying `SQLITE_BUSY` with cooperative,
bounded backoff. Retry admission has a five-second budget. Cancellation and
other error codes propagate; a committed write is never replayed. The initial
database is protected before schema initialization, and workers attach without
repeating initialization.

The main thread owns the live world directory, persistent SSE subscriptions,
and headless browsers, credentials, and reservations. Channels coordinate final
authentication and publication, revocation or deletion with disconnect, and
headless admission. A reconnect quiesces the incumbent world and receives an
acknowledgment before replacing it. Graceful WebSocket retirement then runs in
the background. Headless cleanup retains the exact captured connection identity.

SSE streams stay in API workers. Worlds send events directly through bounded
subscription channels. The main registry survives reconnects, and every new
world receives all six subscription counts, including zero. Overflow retires
only the affected subscriber. Workers forward bounded JSON log records to the
main logging sink.

## Channel cost measurements

The initial production Linux x86_64 benchmark used five rounds of 3,000 round
trips with exactly one outstanding request, worker startup excluded, and GC
enabled. Socket I/O, JSON encoding, and Foundry execution were excluded.

| Reply strategy | Median round trip |
| --- | ---: |
| New reply channel per request | 35.999 microseconds |
| Reuse four reply channels | 28.866 microseconds |
| Transfer a fixed reply endpoint once at startup | 20.264 microseconds |

The four-channel experiment measures reuse, not the lease manager or contended
relay performance. Reuse saved 19.8% in that experiment. Local channel creation
and close cost 0.625 microseconds, plus 0.316 microseconds for final collection.
A nested endpoint message cost 11.805 microseconds, compared with 6.457 for a
matched small string field. Endpoint transfer and lifetime handling are the
larger opportunity for a separate Titan optimization. These measurements do
not predict end-to-end Foundry latency.
