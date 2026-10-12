# Upstream API compatibility audit

Audited on 2026-10-11 against the [official API index](https://foundryrestapi.com/docs/api) and ThreeHats' Go relay at commit [`65ce83d6a534ea6d340c8a89d72251f4c6a0294e`](https://github.com/ThreeHats/foundryvtt-rest-api-relay/tree/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay). This is the reference revision already named in this application's README. Website documentation is unversioned; disagreements with the pinned source are identified below.

The Titan relay has all **91 ordinary forwarding routes** in the pinned reference: 70 general routes and 21 D&D5e routes. Matching method/path names does not establish full compatibility. The response, filtering, capacity, authentication, and transport differences below remain after the session API work.

This is a static comparison of [the forwarding catalog](../relay/api.titan), [the HTTP handlers](../relay/server.titan), [the module connection hub](../relay/hub.titan), and [the local API contract](api.md). It does not claim live validation of every Foundry operation or compatibility with every game-system version. Entity, Search, and Sheet details were checked directly against the pinned handlers and the official [WebSocket API reference](https://foundryrestapi.com/docs/api/websocket).

## Classification

**Complete forwarding** means that the audited method/path, action, declared parameters, required-parameter checks, defaults, and ordinary response adapter are present, subject to the application-wide policies below. Foundry's module performs the operation itself. **Partial** means a route exists but some documented or pinned behavior differs. **Absent** means there is no corresponding route or protocol handler. **Intentional omission** identifies features belonging to the reference service's accounts, hosted operation, or UI rather than this application's single-user contract.

The [pinned root router](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/handler/routes.go#L19) and [D&D5e router](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/handler/dnd5e.go#L10) establish the census. The full method/path/parameter inventory is maintained in [api.md](api.md#forwarding-routes).

| API group | Forwarding routes | Assessment |
| --- | ---: | --- |
| [Entity](https://foundryrestapi.com/docs/api/entity) | 9 | Partial: all operations forward; the reference's macro-creation script screen is omitted. |
| [Search](https://foundryrestapi.com/docs/api/search) | 1 | Complete forwarding; query/filter validation is present. |
| [Roll](https://foundryrestapi.com/docs/api/roll) | 3 | Complete forwarding; its SSE route is assessed separately. |
| [Encounter](https://foundryrestapi.com/docs/api/encounter) | 9 | Complete forwarding. |
| [Macro](https://foundryrestapi.com/docs/api/macro) | 2 | Complete forwarding; account activity logging and external notifications are omitted. |
| [Structure](https://foundryrestapi.com/docs/api/structure) | 4 | Complete current forwarding; deprecated `/contents/*` compatibility response is absent. |
| [Utility](https://foundryrestapi.com/docs/api/utility) | 5 | Partial: all operations forward; the reference's JavaScript script screen is omitted. |
| [User](https://foundryrestapi.com/docs/api/user) | 5 | Complete forwarding of Foundry users; these are separate from relay-service accounts. |
| [Scene](https://foundryrestapi.com/docs/api/scene) | 7 | Complete forwarding, including raw-image JSON and screenshot bytes. |
| [Canvas](https://foundryrestapi.com/docs/api/canvas) | 6 | Matches pinned forwarding; documented bulk-create arrays are rejected by both relays. |
| [Chat](https://foundryrestapi.com/docs/api/chat) | 4 | Complete forwarding; its SSE route is assessed separately. |
| [Effects](https://foundryrestapi.com/docs/api/effects) | 4 | Complete forwarding. |
| [Playlist/sound](https://foundryrestapi.com/docs/api/playlist) | 7 | Complete forwarding, including `/play-sound` and `/stop-sound`. |
| [FileSystem](https://foundryrestapi.com/docs/api/fileSystem) | 3 | Partial: listing, download, and upload exist, but body/message limits are smaller. |
| [Sheet](https://foundryrestapi.com/docs/api/sheet) | 1 | Complete screenshot forwarding; interactive sheet control is absent. |
| [Dnd5e](https://foundryrestapi.com/docs/api/dnd5e) | 21 | Complete forwarding; requires a compatible D&D5e module/world. |

`GET /clients`, six SSE routes, four session routes, and the deprecated contents handler are outside the 91-route forwarding count. The consumer WebSocket and auth/device-flow APIs are also separate surfaces.

## Remaining partial APIs

### Client discovery response

`GET /clients` exists, but Titan returns a bare array of registered worlds with `connected`. The pinned reference returns `{ "total": n, "clients": [...] }`, with `isOnline` on each entry. Both include known offline worlds, so “connected clients only” is not an accurate description of either current implementation. Reference entries also define fields such as `connectedSince`, `foundryVersion`, `instanceId`, `publicUrl`, `ipAddress`, and `tokenName`; Titan's persisted metadata and local fields do not promise that same schema. Consumers of the documented envelope need an adapter. See [official Clients](https://foundryrestapi.com/docs/api/clients), [the pinned response construction](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/handler/entity.go#L1083), and [ClientInfo](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/ws/client.go#L37).

### Event-stream filters

All six SSE routes connect, send events/keepalives, and update Foundry's channel subscriber counts. Titan selects only `clientId` and the channel; it does not apply these documented per-subscriber filters:

| Route | Unsupported query filters | Pinned reference behavior |
| --- | --- | --- |
| `GET /chat/subscribe` | `speaker`, `type`, `whisperOnly`, `userId` | Parses all four; fanout applies `speaker` and `type` only. |
| `GET /rolls/subscribe` | `userId` | Applies the user filter when the event contains `userId`. |
| `GET /hooks/subscribe` | `hooks` | Applies the comma-separated hook allowlist. |
| `GET /encounters/subscribe` | `encounterId` | Applies encounter filtering. |
| `GET /actor/subscribe` | `actorUuid` | Applies actor filtering. |
| `GET /scene/subscribe` | `sceneId` | Applies scene filtering. |

The unsupported filters are documented in [Chat](https://foundryrestapi.com/docs/api/chat), [Roll](https://foundryrestapi.com/docs/api/roll), and [Events](https://foundryrestapi.com/docs/api/events). The exact source behavior is in [SSE parameter parsing](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/handler/sse.go#L19) and [event fanout](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/server/server.go#L940). Chat's `whisperOnly` and `userId` are a shared documentation/source limitation, not an implemented protection supplied by the pinned relay.

Locally, a filter-bearing subscription receives the same channel events as an unfiltered subscription. It must not be treated as permission-scoped delivery for a particular Foundry player. Ordinary REST `userId` forwarding remains available; the module interprets it as described in [Permission Filtering](https://foundryrestapi.com/docs/permission-filtering).

Titan unwraps an object-valued event `data` before writing SSE data for every channel. The pinned fanout explicitly unwraps combat events and otherwise serializes the received event object, so nested event envelopes can differ on the other channels. Titan retains SSE subscriptions across module reconnects, uses a bounded 128-event queue, and retires a slow subscriber when it fills. The pinned reference cancels a world's SSE connections on module disconnect and limits the number of subscriptions instead. Titan also permits automatic selection when exactly one world is online, whereas the pinned SSE handler requires `clientId`. These are deliberate local payload/lifecycle policies, not missing route declarations.

### File capacity

Titan caps HTTP request bodies and module WebSocket messages at **16 MiB**. The reference upload handler accepts bodies up to **250 MiB**; its documented large-upload capacity is therefore unavailable locally. For a JSON upload, base64 and JSON overhead count toward Titan's 16 MiB body cap. Large download and screenshot result messages can also exceed the local module-message limit. Listing, small uploads, binary downloads, and base64 download responses are present. See [FileSystem](https://foundryrestapi.com/docs/api/fileSystem), the [pinned upload limit](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/handler/filesystem.go#L41), and [the local handlers](../relay/server.titan).

### Relay-side script screening

`POST /execute-js` and `POST /create` with `entityType: "Macro"` forward locally without the reference relay's forbidden-pattern screen. The pinned source rejects matching scripts before forwarding; it also requires `macro:write` for macro creation and an opt-in `execute-js` scope for JavaScript execution. Titan's single configured API key has the application's full authority and does not implement those scopes. This is a concrete behavior difference, not missing JavaScript execution support. The reference calls its screen defense in depth and assigns the primary permission boundary to the Foundry module. See [the screen](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/handler/helpers/validation.go#L5), [macro creation](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/handler/entity.go#L62), and [execute-js](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/handler/entity.go#L538).

## APIs still absent

| Surface | Missing methods or behavior | Evidence |
| --- | --- | --- |
| Consumer WebSocket | `GET /ws/api`, initial `{type:"auth",token:...}` API-key exchange, correlated request/reply operations, `subscribe`/`unsubscribe`, and socket event filters. `/relay` is the separate Foundry-module connection. | [Official WebSocket](https://foundryrestapi.com/docs/api/websocket); [pinned handler](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/ws/client_api.go#L315). |
| Interactive sheet control | `interactive-session-start`, `interactive-input`, and `interactive-session-end`, plus streamed frames/session errors and disconnect cleanup. REST `/sheet` produces a screenshot only. | [Pinned interactive dispatch](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/ws/client_api.go#L340) and [session manager](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/ws/interactive_sessions.go). |
| Cross-world module tunnel | Module `remote-request` to `targetClientId` and its `remote-response`; connection-token target/scope allowlists, per-world rate limit, `autoStartIfOffline`, and remote request audit log. The local hub does not dispatch this message type. | [Official cross-world guide](https://foundryrestapi.com/docs/cross-world-modules); [pinned handler registration](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/ws/remote_request.go#L124). |
| Deprecated contents route | `GET /contents/*` (documented as `/contents/:path`). The reference returns HTTP 400 with a deprecation message and `/structure?path=...` example; Titan has no handler and returns 404. | [Official Structure](https://foundryrestapi.com/docs/api/structure); [pinned deprecation response](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/handler/entity.go#L439). |
| Reference operational endpoints | `GET /api/status` and `GET /api/health`. Titan has its own `GET /health` response; it is not a compatible alias for either reference schema. | [Pinned server routes](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/server/server.go#L683), [health response](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/server/server.go#L902). |
| Machine-readable API documentation | `GET /openapi.json`, `GET /asyncapi.json`, and `GET /api/docs`. The reference serves these only when its generated/static files are available. Titan supplies repository documentation. | [Pinned optional documentation routes](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/server/server.go#L810). |

## Session API scope

The session API work covers `POST /session-handshake`, `POST /start-session`, `DELETE /end-session`, and `GET /session`; it does not add the consumer WebSocket, interactive sheets, or automatic startup on ordinary REST/SSE requests. See [the local session contract](api.md) and [official Session](https://foundryrestapi.com/docs/api/session).

Compatibility is intentionally narrower than the [pinned session handler](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/handler/session.go#L52): a local session uses an existing persisted world pairing instead of minting a fresh connection token. The Foundry origin must be allowed by configuration, and the optional world must resolve to one pairing at that origin. Passwords are used in memory for launch only; handshakes and the active session registry are also in memory. Relay restart does not resume a session or recover its password. Browser-console capture is disabled. The local handlers also accept the reference's start-body `worldName` override and end-body `sessionId` fallback beyond the documented header/query forms.

The encrypted credential payload is base64 RSA-OAEP with SHA-256/MGF1 SHA-256 over JSON `{ "password": "...", "nonce": "..." }`. The reference uses a new RSA key per handshake; the local manager uses an ephemeral key shared by its pending handshakes, with separate nonces and one-shot five-minute tokens. Encryption does not replace TLS or establish trust in a public key fetched over an untrusted connection. Session implementation and lifecycle validation are covered by the session change, rather than counted as remaining absent APIs in this audit.

## Intentional service-model omissions

These upstream APIs and policies are absent by design from the single-user application. Session API support does not imply support for them.

- **Public delegated-key flow:** `POST /auth/key-request`, `GET /auth/key-request/:code/status`, and `POST /auth/key-request/exchange`, plus account approval/denial. The local API key is configured by the operator. See [official Auth](https://foundryrestapi.com/docs/api/auth) and [the pinned flow](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/handler/key_request.go#L24).
- **Accounts and scoped keys:** registration/login/logout/verification/password reset, export/delete account, dashboard sessions, and `/auth/api-keys` CRUD/regeneration. There are no account ownership partitions, per-key client/user bindings, scope checks, expiry/IP restrictions, or monthly usage/billing quotas. The reference injects authenticated `_scopes` and bound `userId` values; Titan ignores caller-supplied `_scopes` and forwards an explicit REST `userId`. See [the pinned auth router](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/handler/auth.go#L106) and [request-context enforcement](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/handler/helpers/route.go#L109).
- **Dashboard pairing and credentials:** `/auth/pair-request` device flow, `/auth/connection-tokens` CRUD, `/auth/credentials` vault, and `/auth/known-clients` management including credential association/automatic-start toggles and per-world user lists. Titan implements its local `POST /auth/pair`, `/api/self-unpair`, and client-active probe, plus a local `DELETE /clients/:clientId` extension. See [pair requests](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/handler/pair_request.go#L33) and [token/credential routes](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/handler/connection_tokens.go#L35).
- **External notifications and account activity:** notification settings/test APIs at account/key/world levels, connection/remote/activity logs, module notification dispatch, and macro/JavaScript alerts. See [credential/notification route registration](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/handler/connection_tokens.go#L727) and [activity API](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/handler/activity_log.go#L19).
- **Hosted administration/billing/clustering:** `/admin/auth`, `/admin/api/*`, `/metrics`, `/api/subscriptions/*`, `/api/webhooks/stripe`, Redis-backed cross-instance ownership, and private `POST /internal/forward-action`. See [admin route groups](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/handler/admin_routes.go#L30) and [server mounts](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/server/server.go#L679).
- **Reference frontend:** dashboard/approval/pair pages, subscription pages, `/sheet-test`, `/proxy-asset/*`, and documentation/static-site hosting. These are UI assets and service integrations, not forwarding endpoints. See [pinned frontend routes](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/server/server.go#L823).

The single-user API key authorizes every paired world. This is materially different from exposing the reference service's delegated/scoped APIs to untrusted consumers.

## Documentation/source discrepancies and local policies

- **Canvas bulk creation:** the official Canvas page describes `POST /canvas/:documentType` `data` as an object or an array. Both relays require an object. The pinned [canvas declaration](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/handler/entity.go#L754) names `TypeObject`, and the [object coercion](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/handler/helpers/params.go#L212) rejects arrays. Supporting documented bulk creation would extend the pinned relay's actual behavior.
- **Chat whisper/user filters:** these are documented and parsed upstream but not applied by its chat fanout, as detailed above. Neither relay should be credited with them from route/parameter presence alone.
- **Typed local input:** Titan requires JSON request bodies, finite JSON-form numbers, actual object body parameters, and a documented data URL for JSON uploads. It also adapts binary upload bodies to a data URL. These local validation/transport rules are described in [api.md](api.md); the reference's permissive parsing and error messages are not an exact compatibility target.
- **Offline worlds and errors:** Titan returns 503 for an offline selected world and 400 for ambiguous world selection, instead of the reference helper's offline 404/autostart behavior. Its bounded pending-request policy can return 429. Both have operation-specific deadlines, but error envelopes and disconnect outcomes are not identical. See [the pinned generic helper](https://github.com/ThreeHats/foundryvtt-rest-api-relay/blob/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay/internal/handler/helpers/route.go#L242) and [the local hub](../relay/hub.titan).

## Follow-up checklist

These are recorded gaps, not additional scope for the session API change:

- [ ] Decide whether to adopt the reference `/clients` envelope and field names or publish an explicit adapter.
- [ ] Implement and test SSE filters, with a documented decision for the two ineffective upstream chat filters.
- [ ] Decide whether the 16 MiB body/message limits meet expected file/screenshot workloads.
- [ ] Decide whether to add reference script screening while keeping its permission limitations explicit.
- [ ] Implement consumer `/ws/api` if socket API clients are required.
- [ ] Implement interactive sheet control if streamed rendering/input is required.
- [ ] Design cross-world requests with explicit target/scope policy before adding the tunnel.
- [ ] Add the deprecated contents response and operational aliases if compatibility consumers require them.
- [ ] Decide whether generated OpenAPI/AsyncAPI documents should be served locally.
- [ ] Resolve the documented canvas-array behavior against the Foundry module before offering bulk creation.

Accounts, delegated keys, billing, external notifications, clustered operation, and the reference frontend remain intentional service-model omissions unless separately adopted.
