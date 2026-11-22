# Chapter 2: Declarative Routing, Request Translation, and Event Streaming

An HTTP request entering an API worker crosses four layers before touching a Foundry world: `titan-mk` middleware and PEG route matching ([`relay/routes.titan`](../relay/routes.titan) over `mk`, `mk.router`, and `mk.middleware.*`), lossless JSON decoding ([`relay/wire.titan`](../relay/wire.titan)), declarative parameter coercion and binary framing ([`relay/api.titan`](../relay/api.titan)), and request or SSE stream dispatch ([`relay/api_worker.titan`](../relay/api_worker.titan), paired with event fanout in [`relay/world.titan`](../relay/world.titan)).

## Application middleware and route precedence

[`relay/routes.titan`](../relay/routes.titan) `create` builds the relay's `mk.App` with explicit routing, body, timeout, and error-handler settings:

```titan
  local app = mk.App(mk.Config {
    case_sensitive = true, strict_routing = true, unescape_path = true, auto_head = false,
    body_limit = 16777216, idle_timeout_ms = 10000, error_handler = relay_error, logger = logger,
    workers = mk.WorkerMode.pool(mk.PoolOptions {
      size = settings.api_concurrency, on_start = api_worker.initializer(settings, coordinator),
    }),
  })
  app:use(logger_mw.new(logger_mw.Config { phase = logger_mw.PHASE_ADMISSION }))
  app:use(origin_policy(settings))
  app:use(reject_malformed_target)
  app:use(recover.new(recover.Config { exception_handler = invalid_request }))
```
*Source: [`relay/routes.titan`](../relay/routes.titan) — `create`*

The routing options match the Foundry relay's strict URI contract:

- `case_sensitive = true` and `strict_routing = true` keep path casing and trailing slashes significant (`/api/` and `/api` are distinct).
- `unescape_path = true` decodes segment-preserving percent escapes through `mk.router` while rejecting malformed escapes, `%00`, fragments, and targets exceeding 16 KiB or 256 query fields (surfaced via `ctx:target_error()`).
- `auto_head = false` ensures undeclared `HEAD` requests return `405` with an `Allow` header rather than invoking `GET` handlers.
- `body_limit = 16777216` (16 MiB) causes `ctx:body()` to raise `mk.HttpError(413, ...)` on oversized request bodies, and `idle_timeout_ms = 10000` enforces the 10-second header deadline on initial and keep-alive requests.

Global middleware runs in exact registration order ahead of every routing outcome:

1. **Admission logging (`mk.middleware.logger`, `PHASE_ADMISSION`)**: emits one `http_request` JSON record with normalized `method`, classified `route` template (or `"<unmatched>"`), and `worker_id` before any policy rejection or handler executes.
2. **Origin and CORS (`origin_policy`)**: checks `settings:request_origin_allowed(ctx:get_headers("Origin"), ctx:scheme(), ctx:host())` and raises `403` (`"origin is not allowed"`) ahead of 404/405. Accepted `Origin` headers are echoed in `Access-Control-Allow-Origin` with `Vary: Origin`, and `OPTIONS` preflights return `204` with `Access-Control-Allow-Methods` and `Access-Control-Allow-Headers`.
3. **Malformed target rejection (`reject_malformed_target`)**: converts any `ctx:target_error()` into `mk.HttpError(400, problem)`.
4. **Exception recovery (`mk.middleware.recover`)**: `invalid_request` logs `async.OperationError` as `http_request_failed` (`reason = "io_failure"`) and non-string unexpected errors as `reason = "internal_failure"`, converting every unexpected failure into `mk.HttpError(400, "invalid request", "invalid_request", failure)` without leaking internal error text.

Route registration places 17 local routes ahead of the 91 upstream forwarding routes returned by `api.definitions()`. Specific local paths therefore always win before any parameterized forwarding route runs; [api.md](api.md) documents the complete external route catalog:

- Five unauthenticated routes (`/health`, `/auth/pair`, `/api/self-unpair`, `/api/clients/:clientId/active`, and `/relay`, which carries its own ephemeral `WorkerMode.session`) register directly without `keyauth`.
- Every remaining local route (clients, headless sessions, and the six SSE subscribe routes) and all 91 forwarding routes register `api_key_check(settings)` as their leading route handler. Because `keyauth` is attached per route rather than globally, unmatched paths return `404` and wrong methods return `405` before API-key enforcement returns `401`.
- `api_key_check` configures `mk.middleware.keyauth` with `Extractor.single_header("x-api-key")` and constant-time `config.secret_equal`; on missing, repeated, or mismatched keys, `keyauth` sets `WWW-Authenticate: ApiKey realm="Restricted"` and raises `401`.
- `relay_error` (`Config.error_handler`) normalizes every `mk.HttpError` into `{"error": ...}` via `api_worker.error_response`, mapping router `404`/`405` messages to `"route not found"` (never echoing the request target) and both `missing_api_key` and `invalid_api_key` to `"invalid API key"`.

## Lossless JSON boundaries and declarative API translation

Foundry document updates use explicit JSON `null` values to delete or clear properties, whereas Lua tables treat `nil` as key absence. [`relay/wire.titan`](../relay/wire.titan) resolves that mismatch with a private zero-field `Null` record allocated once in the module initializer and shared by hoisted `DecodeOption` and `EncodeOption` constants alongside 16 MiB byte and 64-level nesting bounds:

```titan
-- One identity sentinel preserves explicit JSON nulls at the relay boundary.
local record Null
end
-- ...
local const decode_null: json.DecodeOption?
local const decode_max_bytes = json.DecodeOption.max_bytes(16777216)
local const decode_max_depth = json.DecodeOption.max_depth(64)
local const encode_null: json.EncodeOption?
local const encode_max_bytes = json.EncodeOption.max_bytes(16777216)
local const encode_max_depth = json.EncodeOption.max_depth(64)

function decode(source: string): value
  return json.decode(source, nil, decode_null, decode_max_bytes, decode_max_depth)
end

function encode(subject: value): string
  return json.encode(subject, encode_null, encode_max_bytes, encode_max_depth)
end
-- ...
do
  local null = Null()
  decode_null = json.DecodeOption.null_value(null)
  encode_null = json.EncodeOption.null_value(null)
end
```
*Source: [`relay/wire.titan`](../relay/wire.titan) — `Null`, `decode`, `encode`*

Because `Null` is module-private, no external value can forge it, and every JSON `null` survives `decode` and `encode` verbatim without allocating per-call option records. `wire.object` verifies that a decoded payload is `{string: value}`, and `wire.text` extracts optional string fields with a fallback.

[`relay/api.titan`](../relay/api.titan) models all 91 upstream Foundry forwarding endpoints declaratively through three closed tagged unions (`ParamKind`, `ParamSource`, and `EndpointKind`):

```titan
union ParamKind
  is_string()
  is_boolean()
  is_number()
  is_array()
  is_object()
  is_value()
end

union ParamSource
  query()
  body()
  path()
  query_then_body()
  body_then_query()
end
```
*Source: [`relay/api.titan`](../relay/api.titan) — `ParamKind`, `ParamSource`*

Module-level unit singletons (`KIND_STRING`, `SRC_Q`, `EP_STANDARD`, and their peers) initialize once so the root `do ... end` block builds a frozen `const {Endpoint}` `catalog`, an O(1) `endpoints_by_key` map (`endpoint_for`), and a `known_actions` allowlist (`is_known_action`, used by [`relay/replies.titan`](../relay/replies.titan) for safe timeout logging, while [`relay/world.titan`](../relay/world.titan) builds its `message_types` allowlist from `definitions`).

For each declared `Param`, `Param:read` dispatches exhaustively on `self.sources` and returns `(candidate, from_query)`, treating empty query values `""` as absent so `query_then_body` and `body_then_query` fall through cleanly:

```titan
-- Path parameters, decoded first-value query fields, and the JSON body.
local function Param:read(params: {string: string}, query: {string: string},
                          body: {string: value}): (value, boolean)
  case self.sources
  when body() then
    local candidate? = body[self.name]
    if candidate ~= nil then return candidate, false end
  when query() then
    local candidate? = query[self.name]
    if candidate ~= nil and candidate ~= "" then return candidate, true end
  when path() then
    local candidate? = params[self.name]
    if candidate ~= nil then return candidate, false end
  when query_then_body() then
    local query_candidate? = query[self.name]
    if query_candidate ~= nil and query_candidate ~= "" then return query_candidate, true end
    local body_candidate? = body[self.name]
    if body_candidate ~= nil then return body_candidate, false end
  when body_then_query() then
    local body_candidate? = body[self.name]
    if body_candidate ~= nil then return body_candidate, false end
    local query_candidate? = query[self.name]
    if query_candidate ~= nil and query_candidate ~= "" then return query_candidate, true end
  end
  return nil, false
end
```
*Source: [`relay/api.titan`](../relay/api.titan) — `Param:read`*

`Param:coerce` checks and converts each value according to `self.kind`. For `is_boolean()`, it tests `candidate == true or candidate == false` rather than `candidate is boolean` (which tests Lua truthiness conversion rather than the JSON boolean tag) and accepts case-insensitive `"true"`/`"false"` strings. Numbers and arrays decode JSON strings via `wire.decode` and check `is float` or `is {value}`; objects decode JSON strings only when `from_query` is true, checking `is {string: value}`. Any decode syntax error is caught and normalized to `'<name>' must be a valid <kind>`.

`build_payload` strips `clientId` from the wire map, runs `Endpoint:validate` (enforcing multi-field one-of rules such as `keys_search` and `upload-file`'s `data:...;base64,` format), applies `EndpointKind` defaults (`canvas()` maps `documentType` through `canvas_classes` to `className`; `image()` defaults `format`, `quality`, and `scale`; `upload()` defaults `source` to `"data"`), and guarantees `result["data"]` exists as a map.

Binary transfers cross Foundry's JSON WebSocket framed in strict padded Base64 (`encode_base64` and `decode_base64`, which validates length multiples of 4, alphabet bytes, and zero padding bits). On the return path, `api.response` decodes `download()` and `image()` payloads back into raw bytes unless `format == "base64"` or `result["error"]` is set, sanitizes `Content-Type` to printable ASCII via `safe_header`, scrubs `Content-Disposition` filenames with the precompiled `unsafe_filename_re` regex, and exposes `X-Image-Width` and `X-Image-Height` headers for screenshots.

## HTTP dispatch and persistent event streams

In [`relay/api_worker.titan`](../relay/api_worker.titan), each endpoint is a plain `mk.Handler` that accesses its thread-local `State` (`worker_id`, `settings`, `database`, `coordinator`, `pool`, `logger`) initialized in `on_start`:

- `json_body(ctx)` reads `ctx:body()` (enforcing `Config.body_limit` with `413`), treats an empty body as `{}`, and otherwise requires `ctx:is_json()` before decoding via `wire.object`.
- `forward(key)` wraps `forward_endpoint(ctx, key)`: for `endpoint:is_upload()` when `not ctx:is_json()`, it wraps raw `ctx:body()` bytes as a `data:<content-type>;base64,...` URL; otherwise it decodes `json_body(ctx)`. It calls `api.build_payload(endpoint, ctx:params(), ctx:queries(), data)`, resolves the target world via `ControlAction.select`, forwards through `worker.pool:request` with `settings.request_timeout` (falling back to `endpoint.timeout_ms` when `0`), and writes the `api.response` reply via `ctx:status(...):set(...):send(...)`.
- For SSE subscriptions, `stream(channel)` invokes `serve_stream(ctx, channel)`, which obtains a `Subscription` from `ControlAction.subscribe`, registers a `defer` closing `subscription.events` and posting `ControlAction.unsubscribe`, sets `text/event-stream`, `Cache-Control: no-cache`, and `X-Accel-Buffering: no`, writes the initial `connected` event with `ctx:write_chunk(...)`, and loops over `async.race_two`:

```titan
local function serve_stream(ctx: mk.Context, channel: string)
  -- ...
  local reading: async.Task<|string?, value|>? = nil
  defer if reading then tasks.drain(reading) end
  while true do
    if not reading then reading = async.run<|string?, value|>(subscription:next) end
    local keepalive = async.run<|nil, value|>(wait_keepalive)
    defer tasks.drain(keepalive)
    case async.race_two(reading, keepalive)
    when first(status) then
      case status
      when succeeded(text) then
        if not text then return end
        local envelope = wire.object(text)
        local data: {string: value} = envelope
        if envelope["data"] is {string: value} then data = envelope["data"] end
        ctx:write_chunk("event: " .. sse_name(channel, data) .. "\ndata: " .. wire.encode(data) .. "\n\n")
        reading = nil
      else return
      end
    when second() then ctx:write_chunk(": keepalive\n\n")
    end
  end
end
```
*Source: [`relay/api_worker.titan`](../relay/api_worker.titan) — `serve_stream`, `wait_keepalive`, `sse_name`*

Reusing `reading` across 15-second `wait_keepalive` ticks ensures an event arriving right at the keepalive boundary is never cancelled or dropped; only `keepalive` drains on every iteration. `sse_name` derives the SSE event name (`roll`, hook name, or `<prefix>-<eventType>`) and falls back to `"event"` or `prefix` if CR or LF appears, preventing SSE frame injection.

On the producer side, `Engine:receive` in [`relay/world.titan`](../relay/world.titan) maps incoming Foundry event types through hoisted `event_channels` and fans out with non-blocking `target.events:try_send(text)`. A full or closed subscriber channel never suspends the world's WebSocket reader: `Engine:receive` immediately closes and removes the slow target locally, sends an updated `event-subscription-update` count to Foundry via `Engine:notify`, and posts a shielded `ControlAction.unsubscribe` to retire the entry from `Hub`.

---

← Previous: [Chapter 1: Multi-Threaded Architecture, Channel Ownership, and World Lifecycle](threading.md) | [Table of Contents](index.md) | Next: [Chapter 3: Cooperative SQLite Persistence, Configuration, and Structured Logging](persistence-and-logging.md) →
