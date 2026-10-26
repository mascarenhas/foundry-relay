# Declarative HTTP routing

`relay/router.titan` parses route declarations with Titan's Relabel PEG
notation, then compiles each declaration into an anchored PEG matcher. Its
shape follows the parse-parts-then-compile approach in
[mk.routes](https://github.com/mascarenhas/mk/blob/master/src/mk/routes.lua).
The declaration grammar initializes once; each route matcher initializes once
in `Route.new`. Matching a request compiles no grammar.

```titan
local router = import "relay.router"

function resolve(): router.Resolution
  local routes = router.Router({
    router.Route("GET", "/worlds/:worldId", "world"),
    router.Route("POST", "/worlds/:worldId/action", "action"),
    router.Route("*", "/assets/*", "assets"),
  })
  return routes:match("GET", "/worlds/Polis%20Sector?tag=a&tag=b")
end
```

Routes match in declaration order. A method of `*` accepts any method; other
methods compare exactly. The resulting `Match` contains the route, action,
decoded named parameters, and query maps. The caller dispatches the action;
the router owns no application callbacks or network resources. The relay's
own table is `relay/routes.titan` `create`, and the [API](api.md) documents
its routes.

## Route syntax

Every pattern begins with `/` and consists of slash-separated parts:

| Part | Meaning |
| --- | --- |
| Literal text | Match that complete path segment. |
| `:name` | Capture one nonempty segment. Names use `[A-Za-z_][A-Za-z0-9_]*`. |
| Final `*` | Capture the remaining path as `params["wildcard"]`, including slashes. |

The grammar produces typed `RoutePart.literal`, `RoutePart.parameter`, and
`RoutePart.wildcard` values, each carrying its starting byte position. Route
construction folds these parts into literal patterns, named capture groups,
and an explicit end-of-input predicate. A successful matcher returns a fresh,
nonnil capture envelope, including when a literal route has no parameters.
Ordinary matcher failure permits the next route to run.

`/assets/*` matches `/assets`, `/assets/`, and `/assets/a/b`. A bare `/` matches
only `/`. Other trailing slashes are significant: `/api/` and `/api` are
different routes. Empty literal segments are permitted, so `/api//status`
retains both separators. Wildcards occupy a whole final segment. Optional
parameters, inline parameter suffixes, and nonterminal wildcards are outside
this route syntax. Literal punctuation is matched as bytes, without regex or
Relabel source interpolation.

Parameter names must be unique, and a `:wildcard` parameter conflicts with a
final `*`.
Patterns are bounded to 1,024 bytes and 64 parts so declarations remain small
and fit the PEG engine's construction limits.

## URI decoding and query values

Matching preserves URI segment boundaries. Literal matchers accept a byte and
its percent-encoded spelling; escape hex digits are case-insensitive.
`/%61pi/:id` therefore has the same literal segment as `/api/:id`. An encoded
slash remains inside its original segment: `/api/A%2FB` captures `A/B` as one
parameter. A literal declaration `/encoded/a%2Fb` matches `/encoded/a%2fb`
and does not match `/encoded/a/b`. Captured values are decoded after matching.
The `+` byte remains literal in paths.

`parse_target` validates the request target once and parses its query. Query
names and values decode percent escapes and treat `+` as a space. The `query`
map retains each name's first occurrence. The `query_values` map retains all
occurrences in wire order. Empty values and names are preserved; empty fields
such as `&&` are skipped but count toward the field limit. Targets are bounded
to 16 KiB and 256 query fields. Malformed percent escapes, encoded NUL, raw
controls, and fragments are rejected.

## Results and diagnostics

`Router:match(method, target)` returns a `Resolution`:

| Status | Meaning |
| --- | --- |
| `200` | `match` contains the first matching route. |
| `400` | Malformed target; `error` contains its diagnostic. |
| `404` | No matching path. |
| `405` | Matching paths exist for other methods; `allowed` retains unique methods in declaration order. |

`allow_header(allowed)` formats the HTTP `Allow` field. `json_response` sets
the status, `Content-Type: application/json; charset=utf-8`, and
`Content-Length`; `error_response` writes an `error` field through it.

`parse_route(pattern)` returns `(parts?, RouteError?)`. `Route.new` raises that
same error for invalid declarations. `RouteError` exposes `code`, `message`,
`position`, `line`, and `column`. Positions and columns count one-based bytes;
line/column accounting uses `peg.line_column`. Grammar labels commit at the
byte where the expected construct is missing or invalid.

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
| `route_limit` | The byte or part limit is exceeded. |
| `invalid_declaration` | Method or action is empty. |
| `trailing_input` | Unexpected trailing declaration input. |

`tests/router_test.titan` covers typed parts, exact labels and byte positions,
percent-encoded boundaries, ordered matching, 404/405 results, query
repetitions, and reusable matchers with independent capture state.
