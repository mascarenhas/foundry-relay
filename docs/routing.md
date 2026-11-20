# Chapter 2: Declarative Routing, Request Translation, and Event Streaming

An HTTP request entering an API worker crosses four layers before touching a Foundry world: PEG route matching ([`relay/router.titan`](../relay/router.titan), [`relay/routes.titan`](../relay/routes.titan)), lossless JSON decoding ([`relay/wire.titan`](../relay/wire.titan)), declarative parameter coercion and binary framing ([`relay/api.titan`](../relay/api.titan)), and request or SSE stream dispatch ([`relay/api_worker.titan`](../relay/api_worker.titan), paired with event fanout in [`relay/world.titan`](../relay/world.titan)).

[`relay/router.titan`](../relay/router.titan) follows the parse-parts-then-compile architecture of [mk.routes](https://github.com/mascarenhas/mk/blob/master/src/mk/routes.lua): a single Relabel PEG grammar parses route declarations into typed parts once, and `Route.new` compiles each declaration into an anchored `peg.Pattern` matcher once. Request matching compiles no grammar, owns no network state, and evaluates routes strictly in declaration order.

[`relay/routes.titan`](../relay/routes.titan) `create` builds the relay's route table by placing 17 local routes (`/health`, pairing, self-unpair, client status/list/delete, `/relay`, four headless session routes, and six SSE subscribe routes) ahead of the 91 upstream forwarding routes returned by `api.routes()`. Specific local paths therefore always win before any wildcard or parameterized forwarding route runs; [api.md](api.md) documents the complete external route catalog.

## Route syntax

Every pattern begins with `/` and consists of slash-separated parts:

| Part | Meaning |
| --- | --- |
| Literal text | Match that complete path segment. |
| `:name` | Capture one nonempty segment. Names use `[A-Za-z_][A-Za-z0-9_]*`. |
| Final `*` | Capture the remaining path as `params["wildcard"]`, including slashes. |

Parsing produces a frozen `const {RoutePart}` sequence whose elements are stored alongside the compiled `peg.Pattern` on each immutable `Route`:

```titan
union RoutePart
  literal(text: string, position: integer)
  parameter(name: string, position: integer)
  wildcard(position: integer)
end
-- ...
record Route
  const method: string
  const pattern: string
  const action: string
  local const parts: const {RoutePart}
  local const matcher: peg.Pattern
end
```
*Source: [`relay/router.titan`](../relay/router.titan) — `RoutePart`, `Route`*

The module's root initializer compiles `route_grammar` once per Lua state using Titan's Relabel PEG syntax. Labeled errors (`%{...}`) commit at the exact offending byte, while `peg.define_value` binds the concrete Titan constructor functions `parameter_part`, `literal_part`, and `wildcard_part` directly into capture actions:

```titan
do
  route_grammar = peg.compile([[
    Route <- {|
      ('/' / %{expected_slash})
      (!. / (Part ('/' Part)*))
      (!. / Invalid)
    |}
    Part <- Parameter / Wildcard / Literal
    Parameter <- ({} ':' {Name / %{expected_parameter_name}}
      (&'/' / !. / %{parameter_tail})) -> parameter_part
    Name <- [A-Za-z_] [A-Za-z0-9_]*
    Wildcard <- ({} '*' (!. / %{wildcard_not_terminal})) -> wildcard_part
    Literal <- ({} {LiteralByte*}) -> literal_part
    LiteralByte <- '%' (&'00' %{nul_escape} /
      ([0-9A-Fa-f] / %{percent_escape}) ([0-9A-Fa-f] / %{percent_escape})) /
      (!('/' / '*' / '?' / '#' / '%' / %control) .)
    Invalid <- (&('?' / '#') %{query_or_fragment}) /
      (&'*' %{partial_wildcard}) / (&%control %{control_character}) / %{trailing_input}
  ]], {
    peg.define_value("parameter_part", parameter_part),
    peg.define_value("literal_part", literal_part),
    peg.define_value("wildcard_part", wildcard_part),
    peg.define("control", peg.choice(peg.ranges("\0\31"), peg.literal("\127"))),
  })
end
```
*Source: [`relay/router.titan`](../relay/router.titan) — `route_grammar`, `parameter_part`, `literal_part`, `wildcard_part`*

`compile_route` folds `const {RoutePart}` into combinator patterns: `literal` segments compile through `literal_matcher`, `parameter` segments compile into `peg.group(peg.capture(segment), name)` over non-`/` bytes, and a terminal `wildcard` compiles into `peg.group(..., "wildcard")` with an optional leading `/` when `index > 1`. Wrapping the sequence and end-of-input anchor `peg.negative(peg.any())` in `peg.table_capture` guarantees a fresh, non-nil capture map on every match, even for parameterless literal routes.

`/assets/*` matches `/assets`, `/assets/`, and `/assets/a/b`. A bare `/` matches only `/`, while other trailing slashes remain significant (`/api/` and `/api` are distinct). Empty literal segments such as `/api//status` retain both separators. Wildcards occupy a whole final segment; optional parameters, inline suffixes, and nonterminal wildcards are outside this syntax. `parse_route` enforces unique parameter names (including rejecting `:wildcard` alongside `*`) and caps declarations at `max_route_bytes` (1,024 bytes) and `max_route_parts` (64 parts).

## URI decoding and query values

Matching preserves URI segment boundaries. `literal_matcher` decodes the declared literal once and emits per-byte PEG units accepting either the raw byte or its case-insensitive `%XX` escape—except for `/` and `%`, which match only their escaped form so an encoded slash never splits a segment. `/%61pi/:id` therefore matches the same paths as `/api/:id`, `/api/A%2FB` captures `A/B` as one parameter, and `/encoded/a%2Fb` matches `/encoded/a%2fb` without matching `/encoded/a/b`. Captured parameter values are decoded after matching in `Route:parameters`, keeping `+` literal in paths.

`percent_decode` avoids allocations on the common ASCII path by deferring `string.writer()` creation until the first `%` (or `+` when `plus_as_space` is true). When escapes appear, it flushes untouched spans via `string.sub` instead of appending one byte at a time, while rejecting incomplete escapes, non-hex digits, `%00` (NUL), and raw control bytes:

```titan
function percent_decode(subject: string, plus_as_space: boolean?): string
  local result: string.StringWriter? = nil
  local span_start = 1
  local index = 1
  local length = #subject
  while index <= length do
    local byte: integer = string.byte(subject, index)
    if byte == 37 then
      -- ...
      local decoded = high * 16 + low
      if decoded == 0 then raise "NUL is not allowed in a request target" end
      local writer = result or string.writer()
      result = writer
      if index > span_start then writer:write(string.sub(subject, span_start, index - 1)) end
      writer:write(string.char(decoded))
      index = index + 3
      span_start = index
    -- ...
    end
  end
  if result == nil then return subject end
  local writer = result
  if span_start <= length then writer:write(string.sub(subject, span_start, length)) end
  return writer:drain()
end
```
*Source: [`relay/router.titan`](../relay/router.titan) — `percent_decode`*

`parse_target` validates each request target once before route evaluation. It rejects targets exceeding `max_target_bytes` (16 KiB), targets missing a leading `/`, and fragments containing `#`. Before calling `string.split(query_source, "&")`, it scans `query_source` to count `&` delimiters and enforce `max_query_fields` (256 fields, counting empty fields like `&&` while skipping them during decoding). Query names and values decode with `plus_as_space = true`; `query` retains each key's first value while `query_values` preserves all occurrences in wire order.

## Results and diagnostics

`Router:match(method, target)` evaluates routes in declaration order, matching exact method strings or `*`, and returns a `Resolution` (reusing module-level `empty_allowed: const {string}` whenever no `Allow` list is needed):

| Status | Meaning |
| --- | --- |
| `200` | `match` holds the first matching `Match` (`route`, `action`, `params`, `query`, `query_values`). |
| `400` | Malformed target; `error` carries the validation message from `parse_target`. |
| `404` | No route matched the path. |
| `405` | One or more routes matched the path for other methods; `allowed` holds unique methods in declaration order. |

`allow_header` formats any `const? {string}` method list into an HTTP `Allow` header via `string.writer()`. `json_response` sets status, `Content-Type: application/json; charset=utf-8`, and `Content-Length` before writing the body; `error_response` encodes an `ErrorEnvelope` JSON object through `error_body`.

`parse_route(pattern)` returns `(const {RoutePart}?, RouteError?)`, and `Route.new` raises that same `RouteError` on invalid declarations. `route_error` maps one-based byte positions to `(line, column)` via `peg.line_column` and populates `code` and `message` from `route_messages`:

| Code | Meaning |
| --- | --- |
| `expected_slash` | Missing leading `/`. |
| `expected_parameter_name` | Missing or invalid parameter identifier. |
| `parameter_tail` | Extra text after a parameter name. |
| `wildcard_not_terminal` | Text follows a wildcard. |
| `partial_wildcard` | A wildcard appears inside a literal segment. |
| `query_or_fragment` | A literal query or fragment delimiter appears in the declaration. |
| `percent_escape` | A literal percent escape lacks two hex digits. |
| `nul_escape` | A literal percent escape represents NUL. |
| `control_character` | A raw control byte appears in the declaration. |
| `duplicate_parameter` | A named parameter is repeated, or `:wildcard` accompanies a final `*`. |
| `route_limit` | The 1,024-byte or 64-part limit is exceeded. |
| `invalid_declaration` | Method or action is empty. |
| `trailing_input` | Unexpected trailing declaration input. |

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
local function Param:read(match: router.Match, body: {string: value}): (value, boolean)
  case self.sources
  when body() then
    local candidate? = body[self.name]
    if candidate ~= nil then return candidate, false end
  when query() then
    local candidate? = match.query[self.name]
    if candidate ~= nil and candidate ~= "" then return candidate, true end
  when path() then
    local candidate? = match.params[self.name]
    if candidate ~= nil then return candidate, false end
  when query_then_body() then
    local query_candidate? = match.query[self.name]
    if query_candidate ~= nil and query_candidate ~= "" then return query_candidate, true end
    local body_candidate? = body[self.name]
    if body_candidate ~= nil then return body_candidate, false end
  when body_then_query() then
    local body_candidate? = body[self.name]
    if body_candidate ~= nil then return body_candidate, false end
    local query_candidate? = match.query[self.name]
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

In [`relay/api_worker.titan`](../relay/api_worker.titan), `Worker:handle` matches the incoming request once, logs `http_request` with the matched route template (or `<unmatched>`) and normalized `known_methods` (or `"OTHER"`), and passes the `Resolution` to `Worker:dispatch`:

1. **Origin and CORS**: `settings:request_origin_allowed` rejects disallowed `Origin` headers with `403`. Allowed origins receive `Access-Control-Allow-Origin` and `Vary: Origin`, and `OPTIONS` preflights return `204`.
2. **Routing errors and unauthenticated local routes**: non-`200` resolutions return `400`, `404`, or `405` (with `Allow` from `router.allow_header`). Local routes `/health`, `/auth/pair`, `/relay` (missing `id`), `/api/self-unpair`, and `/api/clients/:clientId/active` run before the API-key gate.
3. **API-key enforcement and dispatch**: `Worker:authorized` verifies a single `x-api-key` header using constant-time `config.secret_equal` (`401` on mismatch), then routes to `session_request`, `clients`, `forget`, `stream` (`sse:*`), or `forward`.

`Worker:forward` reads either raw binary upload bodies (for `endpoint:is_upload()` when `Content-Type` is not `application/json`, wrapping the bytes as a `data:<content-type>;base64,...` URL) or a 16 MiB-bounded JSON object (`json_body`), calls `api.build_payload`, resolves the target world via `ControlAction.select`, forwards through `self.pool:request` with `settings.request_timeout` (falling back to `endpoint.timeout_ms` when `0`), and writes the `api.response` reply.

For SSE subscriptions, `Worker:stream` obtains a `Subscription` from `ControlAction.subscribe`, registers a `defer` closing `subscription.events` and posting `ControlAction.unsubscribe`, writes `text/event-stream` headers plus the initial `connected` event, and loops over `async.race_two`:

```titan
local function Worker:stream(response: http.Response, match: router.Match)
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
        response:write("event: " .. sse_name(channel, data) .. "\ndata: " .. wire.encode(data) .. "\n\n")
        reading = nil
      else return
      end
    when second() then response:write(": keepalive\n\n")
    end
  end
end
```
*Source: [`relay/api_worker.titan`](../relay/api_worker.titan) — `Worker:stream`, `wait_keepalive`, `sse_name`*

Reusing `reading` across 15-second `wait_keepalive` ticks ensures an event arriving right at the keepalive boundary is never cancelled or dropped; only `keepalive` drains on every iteration. `sse_name` derives the SSE event name (`roll`, hook name, or `<prefix>-<eventType>`) and falls back to `"event"` or `prefix` if CR or LF appears, preventing SSE frame injection.

On the producer side, `Engine:receive` in [`relay/world.titan`](../relay/world.titan) maps incoming Foundry event types through hoisted `event_channels` and fans out with non-blocking `target.events:try_send(text)`. A full or closed subscriber channel never suspends the world's WebSocket reader: `Engine:receive` immediately closes and removes the slow target locally, sends an updated `event-subscription-update` count to Foundry via `Engine:notify`, and posts a shielded `ControlAction.unsubscribe` to retire the entry from `Hub`.

---

← Previous: [Chapter 1: Multi-Threaded Architecture, Channel Ownership, and World Lifecycle](threading.md) | [Table of Contents](index.md) | Next: [Chapter 3: Cooperative SQLite Persistence, Configuration, and Structured Logging](persistence-and-logging.md) →
