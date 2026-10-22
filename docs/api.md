# HTTP and WebSocket API

This is the contract for every route the relay serves. The route table is
built by `relay/routes.titan` `create`: local handlers first, then the
forwarding catalog from `relay/api.titan`. [Routing](routing.md) describes how
targets are matched. API worker threads handle HTTP routes in
`relay/api_worker.titan` `Worker:dispatch`; each module WebSocket runs in
`relay/world.titan` `execute` on its own thread.

## Request rules

These rules apply to every route, including the public ones:

- **Origin.** A request may omit `Origin`, send its own scheme and authority, or
  send one of the exact `RELAY_ALLOWED_ORIGINS` entries. Anything else,
  including more than one `Origin` header, returns 403 before routing. An
  accepted `Origin` is echoed in `Access-Control-Allow-Origin` with
  `Vary: Origin`. `OPTIONS` returns 204 with `Access-Control-Allow-Methods`
  and `Access-Control-Allow-Headers` (`Content-Type`, `X-API-Key`,
  `X-Foundry-Url`, `X-Username`, `X-World-Name`).
- **Authentication.** Every route except `/health`, `/auth/pair`,
  `/api/self-unpair`, `/api/clients/:clientId/active`, and `/relay` requires
  exactly one `x-api-key` header equal to `FOUNDRY_REST_API_KEY`. A missing,
  wrong or repeated header returns 401.
- **Bodies.** A route that reads a body requires `Content-Type:
  application/json` and a JSON object, nested at most 64 levels, when the body
  is nonempty; an empty body counts as `{}`. Bodies are capped at 16 MiB. The
  one exception is a raw `POST /upload`, described under
  [responses](#responses).
- **World selection.** Forwarding routes and event streams take `clientId`
  from the query; forwarding routes also accept a string `clientId` in the
  body. When it is omitted and exactly one world is online, that world is
  used. Several online worlds return 400 for forwarding routes and 503 for
  event streams. An unknown or offline world, or no online world, returns 503.
- **Errors.** Failures use a JSON body `{"error":"..."}`. A malformed target
  returns 400; an unmatched path returns 404; a path declared only for other
  methods returns 405 with an `Allow` header. Invalid parameters, an
  oversized or non-JSON body, and other rejected input return 400 with the
  generic message `invalid request`.

## Local routes

| Method and path | Authentication | Result |
| --- | --- | --- |
| `GET /health` | public | `{"status":"ok"}` |
| `POST /auth/pair` | pairing code in the body | `token`, `clientId`, `relayUrl`; see [pairing](#pairing-and-the-module-connection) |
| `POST /api/self-unpair` | connection token in the body | Revokes that token |
| `GET /api/clients/:clientId/active` | public | `{"active":true}` or `{"active":false}`; 404 for an unknown client |
| `GET /relay?id=<clientId>` | first WebSocket message | Foundry module connection; 400 without `id` |
| `GET /clients` | API key | Registered worlds; see [client list](#client-list) |
| `DELETE /clients/:clientId` | API key | Forgets the world and revokes its pairing; 404 if unknown |
| Six `GET /<channel>/subscribe` routes | API key | Server-sent events; see [event streams](#event-streams) |
| `POST /session-handshake`, `POST /start-session`, `GET /session`, `DELETE /end-session` | API key | Headless sessions; see [sessions](sessions.md) |

### Pairing and the module connection

The Foundry module posts `/auth/pair` with `code`, `worldId`, `worldTitle`,
`serverFingerprint`, `existingClientId`, and `serverOrigin`. A wrong code
returns 401 and a missing `worldId` returns 400. Submitted codes are compared
exactly with the uppercased `FOUNDRY_PAIRING_CODE`. The response contains
`token`, `clientId`, and `relayUrl` (`RELAY_PUBLIC_URL`).

`relay/store.titan` `Store:pair` reuses an existing registration, with its
client ID and token, when the request matches it by `existingClientId` and
`worldId`, then by `worldId` and `serverFingerprint`, then by `worldId` and
`serverOrigin`. A stored origin must agree with a supplied one. Otherwise it
creates a new client ID (16 random bytes, hex) and token (32 random bytes,
hex) from the operating system's CSPRNG.

The module connects to `/relay?id=<clientId>` with nonsecret world and system
query metadata. Its first text frame must be `{"type":"auth","token":"..."}`
within `RELAY_AUTH_TIMEOUT_MS`. The relay answers `{"type":"auth-success"}`,
or `{"type":"auth-failed","error":"invalid pairing token"}` followed by Close
1008. A new authenticated connection for the same client replaces the old
one, which is closed with code 1000. The relay pings every
`RELAY_HEARTBEAT_MS` and answers module `ping` messages with `pong`. Module
messages must be text and at most 16 MiB. The relay records the query
metadata on each successful authentication.

`POST /api/self-unpair` takes `{"token":"..."}`. It replaces that token with a
fresh one, keeps the registration, disconnects the world, and returns
`{"success":true}`; an unknown token returns 401. Re-pairing then returns the
fresh token. `DELETE /clients/:clientId` also disconnects the world.

### Client list

`GET /clients` returns a JSON array of every registered world, online or not,
ordered by world title. Each entry has `id` and `clientId` (both the client
ID), `worldId`, `worldTitle`, `version` (module version), `lastSeen` (Unix
seconds of the last pairing or authentication), and `connected`. The query
metadata from the module's last authenticated connection is then copied into
the entry, except keys named `id`, `token`, `clientId`, and `connected`.
Tokens never appear.

### Event streams

| Route | Foundry channel | Module event type |
| --- | --- | --- |
| `/chat/subscribe` | `chat-events` | `chat-event` |
| `/rolls/subscribe` | `roll-events` | `roll-data` |
| `/hooks/subscribe` | `hooks` | `hook-event` |
| `/encounters/subscribe` | `combat-events` | `combat-event` |
| `/actor/subscribe` | `actor-events` | `actor-event` |
| `/scene/subscribe` | `scene-events` | `scene-event` |

A stream opens with `event: connected` and data `{"clientId":"..."}`. Each
module event is written with its inner object-valued `data`, or the whole
message when `data` is not an object. Event names are `roll` for rolls; the
event's `hook` or `hookName` (default `hook`) for hooks; and
`<chat|combat|actor|scene>-<eventType>` (default `eventType` `create`) for the
others. A `: keepalive` comment follows every 15 seconds without an event.

Each subscriber has a 128-event queue. A subscriber whose queue is full is
retired, and its stream ends after the queued events. Subscriptions belong to
the main registry, so they survive a world reconnect. Foundry receives
`{"type":"event-subscription-update","channel":...,"count":...}` whenever a
channel's subscriber count changes, and all six counts, including zero, after
each authentication, so it can enable only the hooks in use. The streaming
handler is `relay/api_worker.titan` `Worker:stream`.

## Forwarding behavior

The relay forwards 91 declarations from the reference Go relay to the
selected world. Use `userId` (a Foundry user ID or username) to request
permission-scoped operations; when it is omitted, the module uses the
connected GM's authority. The D&D5e routes require a compatible D&D5e world.

### Parameters

`relay/api.titan` `build_payload` reads only the declared parameters, in their
declared source order, and sends them as top-level fields of the WebSocket
message. The relay sets `type` and `requestId` itself and never forwards
`clientId`. Undeclared fields, including `_scopes`, are dropped. A false or
zero body value counts as present; an empty query value counts as absent.
When `data` is absent, an empty object is sent. Explicit JSON nulls, nested or
trailing in arrays, survive the round trip.

Values are checked against their declared kind (`Param:coerce`):

- `boolean` accepts JSON booleans and the strings `true` and `false` in any
  case.
- `number` accepts JSON numbers and strings that parse as a finite JSON number.
- `array` accepts JSON arrays and strings that parse as one.
- `object` accepts JSON objects; JSON text is parsed only from the query.
  URL-encode structured query values.
- `value` (`speaker`) is forwarded unchanged, so a body may send a string or a
  Foundry speaker object while a query value arrives as a string.

Besides required parameters, some routes need at least one of a group
(`relay/api.titan` `validate`): `/search` needs `query` or `filter`;
`POST /select` needs `uuids`, `name`, `data`, or `all`; `GET`, `PUT`, and
`DELETE /user` need `id` or `name`; `GET /scene` needs `sceneId`, `name`,
`active`, `viewed`, or `all`; `PUT /scene` needs `sceneId`, `name`, or
`active`; `DELETE /scene` and `/switch-scene` need `sceneId` or `name`; and
`/sheet` needs `uuid` or `selected`. `/upload` needs `path`, `filename`, and a
`fileData` data URL.

Canvas `documentType` must be `tokens`, `tiles`, `drawings`, `lights`,
`sounds`, `notes`, `templates`, `walls`, or `regions`; the relay adds the
matching Foundry `className`. Most other defaults are applied by the module.

### Responses

A successful reply is the complete Foundry result object, including its
`<action>-result` type and the relay's request ID. A result with a top-level
`error` field is returned unchanged with status 400. `relay/api.titan`
`response` converts three routes to binary unless `format=base64` is given:

- `GET /download` decodes `fileData` and sets `Content-Type` from `mimeType`
  (default `application/octet-stream`) and an attachment
  `Content-Disposition` from the file name.
- `GET /sheet` and `GET /scene/image` decode `imageData` (top-level or inside
  `data`), set `Content-Type` from `mimeType` (default `image/png`), and add
  `X-Image-Width` and `X-Image-Height` when the result has numeric
  dimensions. Both default to `format` `png` and `quality` 0.9; `/sheet`
  also defaults `scale` to 1.

A result without file or image data is returned as JSON, and
`GET /scene/image/raw` always returns the module's ordinary JSON result.

`POST /upload` takes JSON `path`, `filename`, and `fileData` formatted as
`data:<mime>;base64,<bytes>`; `source` defaults to `data`. A body with any
other `Content-Type` is uploaded raw: the relay encodes it as a data URL with
that content type and takes the other parameters from the query. Files pass
through Foundry's file API and are not stored by the relay.

### Deadlines and failures

Each declaration has a deadline. It is 10 seconds unless listed here:

| Deadline | Routes |
| --- | --- |
| 15 s | `GET /file-system` |
| 20 s | `POST /execute-js`, `GET /sheet` |
| 30 s | `POST /scene`, `PUT /scene`, `POST /switch-scene`, `POST` and `PUT /canvas/:documentType`, `GET /scene/image`, `GET /scene/image/raw`, `POST /upload` |
| 45 s | `GET /download` |

`RELAY_REQUEST_TIMEOUT_MS` replaces every deadline. The deadline covers
waiting for a reply channel, admission, and the reply. When it expires the
relay returns 408. The request may already have reached Foundry and
performed a mutation; it is never retried. A world disconnect returns 503 to
its pending requests. A world with `RELAY_MAX_PENDING` requests in flight
returns 429, and a full output queue returns 503. [Threading](threading.md)
describes how these requests are owned.

## Forwarding routes

The catalog is `relay/api.titan` `catalog`. The last column lists the
parameters that must be present; some routes add the one-of rules described
under [parameters](#parameters).

| Method | Path | WebSocket action | Required parameters |
| --- | --- | --- | --- |
| GET | `/get` | `entity` | — |
| POST | `/create` | `create` | entityType, data |
| PUT | `/update` | `update` | data |
| DELETE | `/delete` | `delete` | — |
| POST | `/give` | `give` | — |
| POST | `/remove` | `remove` | — |
| POST | `/decrease` | `decrease` | attribute, amount |
| POST | `/increase` | `increase` | attribute, amount |
| POST | `/kill` | `kill` | — |
| GET | `/search` | `search` | — |
| GET | `/rolls` | `rolls` | — |
| GET | `/lastroll` | `last-roll` | — |
| POST | `/roll` | `roll` | formula |
| GET | `/encounters` | `encounters` | — |
| POST | `/start-encounter` | `start-encounter` | — |
| POST | `/next-turn` | `next-turn` | — |
| POST | `/next-round` | `next-round` | — |
| POST | `/last-turn` | `last-turn` | — |
| POST | `/last-round` | `last-round` | — |
| POST | `/end-encounter` | `end-encounter` | — |
| POST | `/add-to-encounter` | `add-to-encounter` | — |
| POST | `/remove-from-encounter` | `remove-from-encounter` | — |
| GET | `/macros` | `macros` | — |
| GET | `/structure` | `structure` | — |
| GET | `/get-folder` | `get-folder` | name |
| POST | `/create-folder` | `create-folder` | name, folderType |
| DELETE | `/delete-folder` | `delete-folder` | folderId |
| POST | `/select` | `select` | — |
| GET | `/selected` | `selected` | — |
| GET | `/players` | `players` | — |
| GET | `/users` | `get-users` | — |
| GET | `/user` | `get-user` | — |
| POST | `/user` | `create-user` | name |
| PUT | `/user` | `update-user` | data |
| DELETE | `/user` | `delete-user` | — |
| GET | `/scene` | `get-scene` | — |
| GET | `/scene/image/raw` | `scene-raw-image` | — |
| POST | `/scene` | `create-scene` | data |
| PUT | `/scene` | `update-scene` | data |
| DELETE | `/scene` | `delete-scene` | — |
| POST | `/switch-scene` | `switch-scene` | — |
| GET | `/canvas/:documentType` | `get-canvas-documents` | documentType |
| GET | `/measure-distance` | `measure-distance` | — |
| POST | `/canvas/:documentType` | `create-canvas-document` | documentType, data |
| PUT | `/canvas/:documentType` | `update-canvas-document` | documentType, documentId, data |
| DELETE | `/canvas/:documentType` | `delete-canvas-document` | documentType, documentId |
| POST | `/move-token` | `move-token` | x, y |
| GET | `/chat` | `chat-messages` | — |
| POST | `/chat` | `chat-send` | content |
| DELETE | `/chat/:messageId` | `chat-delete` | messageId |
| DELETE | `/chat` | `chat-flush` | — |
| GET | `/effects` | `get-effects` | uuid |
| GET | `/effects/list` | `get-status-effects` | — |
| POST | `/effects` | `add-effect` | uuid |
| DELETE | `/effects` | `remove-effect` | uuid |
| GET | `/world-info` | `world-info` | — |
| GET | `/playlists` | `get-playlists` | — |
| POST | `/playlist/play` | `playlist-play` | — |
| POST | `/playlist/stop` | `playlist-stop` | — |
| POST | `/playlist/next` | `playlist-next` | — |
| POST | `/playlist/volume` | `playlist-volume` | volume |
| POST | `/play-sound` | `play-sound` | src |
| POST | `/stop-sound` | `stop-sound` | — |
| GET | `/file-system` | `file-system` | — |
| GET | `/download` | `download-file` | — |
| POST | `/macro/:uuid/execute` | `macro-execute` | uuid |
| POST | `/execute-js` | `execute-js` | — |
| GET | `/scene/image` | `scene-screenshot` | — |
| POST | `/upload` | `upload-file` | — |
| GET | `/sheet` | `sheet-screenshot` | — |
| GET | `/dnd5e/get-actor-details` | `get-actor-details` | actorUuid, details |
| POST | `/dnd5e/modify-item-charges` | `modify-item-charges` | actorUuid, amount |
| POST | `/dnd5e/short-rest` | `short-rest` | — |
| POST | `/dnd5e/long-rest` | `long-rest` | — |
| POST | `/dnd5e/skill-check` | `skill-check` | actorUuid, skill |
| POST | `/dnd5e/ability-save` | `ability-save` | actorUuid, ability |
| POST | `/dnd5e/ability-check` | `ability-check` | actorUuid, ability |
| POST | `/dnd5e/death-save` | `death-save` | actorUuid |
| POST | `/dnd5e/modify-experience` | `modify-experience` | amount |
| GET | `/dnd5e/concentration` | `get-concentration` | — |
| POST | `/dnd5e/break-concentration` | `break-concentration` | — |
| POST | `/dnd5e/concentration-save` | `concentration-save` | damage |
| POST | `/dnd5e/equip-item` | `equip-item` | equipped |
| POST | `/dnd5e/attune-item` | `attune-item` | attuned |
| POST | `/dnd5e/transfer-currency` | `transfer-currency` | currency |
| POST | `/dnd5e/modify-currency` | `modify-currency` | actorUuid, currency, amount |
| POST | `/dnd5e/prepare-spell` | `prepare-spell` | actorUuid, spellName, prepared |
| POST | `/dnd5e/use-ability` | `use-ability` | actorUuid |
| POST | `/dnd5e/use-feature` | `use-feature` | actorUuid |
| POST | `/dnd5e/use-spell` | `use-spell` | actorUuid |
| POST | `/dnd5e/use-item` | `use-item` | actorUuid |

## Accepted parameters

Names marked `*` are required. The source list gives the lookup order:
`body/query` checks the body first and `query/body` checks the query first.

- `GET /get`: `clientId:string (query)`, `uuid:string (query)`, `selected:boolean (query/body)`, `actor:boolean (query)`, `userId:string (query/body)`
- `POST /create`: `entityType*:string (body)`, `data*:object (body)`, `clientId:string (query)`, `folder:string (body)`, `keepId:boolean (body/query)`, `override:boolean (body/query)`, `userId:string (query/body)`
- `PUT /update`: `data*:object (body)`, `clientId:string (query)`, `uuid:string (query)`, `selected:boolean (query/body)`, `actor:boolean (query)`, `userId:string (query/body)`
- `DELETE /delete`: `clientId:string (query)`, `uuid:string (query)`, `selected:boolean (query/body)`, `userId:string (query/body)`
- `POST /give`: `clientId:string (query)`, `fromUuid:string (body)`, `toUuid:string (body)`, `selected:boolean (query/body)`, `itemUuid:string (body)`, `itemName:string (body)`, `quantity:number (body)`, `userId:string (query/body)`
- `POST /remove`: `clientId:string (query)`, `actorUuid:string (body)`, `selected:boolean (query/body)`, `itemUuid:string (body)`, `itemName:string (body)`, `quantity:number (body)`, `userId:string (query/body)`
- `POST /decrease`: `attribute*:string (body)`, `amount*:number (body)`, `clientId:string (query)`, `uuid:string (query)`, `selected:boolean (query/body)`, `userId:string (query/body)`
- `POST /increase`: `attribute*:string (body)`, `amount*:number (body)`, `clientId:string (query)`, `uuid:string (query)`, `selected:boolean (query/body)`, `userId:string (query/body)`
- `POST /kill`: `clientId:string (query)`, `uuid:string (query)`, `selected:boolean (query/body)`, `userId:string (query/body)`
- `GET /search`: `clientId:string (query)`, `query:string (query)`, `filter:string (query)`, `excludeCompendiums:boolean (query)`, `limit:number (query)`, `minified:boolean (query)`, `ownedByUserId:string (query)`, `userId:string (query/body)`
- `GET /rolls`: `clientId:string (query)`, `limit:number (query)`, `userId:string (query/body)`
- `GET /lastroll`: `clientId:string (query)`, `userId:string (query/body)`
- `POST /roll`: `formula*:string (body)`, `clientId:string (query)`, `flavor:string (body)`, `createChatMessage:boolean (body)`, `speaker:value (body)`, `whisper:array (body)`, `userId:string (query/body)`
- `GET /encounters`: `clientId:string (query)`, `userId:string (query/body)`
- `POST /start-encounter`: `clientId:string (query)`, `tokens:array (body)`, `startWithSelected:boolean (body)`, `startWithPlayers:boolean (body)`, `rollNPC:boolean (body)`, `rollAll:boolean (body)`, `name:string (body)`, `userId:string (query/body)`
- `POST /next-turn`: `clientId:string (query)`, `encounter:string (body/query)`, `userId:string (query/body)`
- `POST /next-round`: `clientId:string (query)`, `encounter:string (body/query)`, `userId:string (query/body)`
- `POST /last-turn`: `clientId:string (query)`, `encounter:string (body/query)`, `userId:string (query/body)`
- `POST /last-round`: `clientId:string (query)`, `encounter:string (body/query)`, `userId:string (query/body)`
- `POST /end-encounter`: `clientId:string (query)`, `encounter:string (body/query)`, `userId:string (query/body)`
- `POST /add-to-encounter`: `clientId:string (query)`, `encounter:string (body/query)`, `selected:boolean (query/body)`, `uuids:array (body)`, `rollInitiative:boolean (body)`, `userId:string (query/body)`
- `POST /remove-from-encounter`: `clientId:string (query)`, `encounter:string (body/query)`, `selected:boolean (query/body)`, `uuids:array (body)`, `userId:string (query/body)`
- `GET /macros`: `clientId:string (query)`, `userId:string (query/body)`
- `GET /structure`: `clientId:string (query)`, `includeEntityData:boolean (query)`, `path:string (query)`, `recursive:boolean (query)`, `recursiveDepth:number (query)`, `types:string (query)`, `userId:string (query/body)`
- `GET /get-folder`: `name*:string (body/query)`, `clientId:string (query)`, `userId:string (query/body)`
- `POST /create-folder`: `name*:string (body/query)`, `folderType*:string (body/query)`, `clientId:string (query)`, `parentFolderId:string (body/query)`, `userId:string (query/body)`
- `DELETE /delete-folder`: `folderId*:string (body/query)`, `clientId:string (query)`, `deleteAll:boolean (body/query)`, `userId:string (query/body)`
- `POST /select`: `clientId:string (query)`, `uuids:array (body)`, `name:string (body)`, `data:object (body)`, `overwrite:boolean (body)`, `all:boolean (body)`, `userId:string (query/body)`
- `GET /selected`: `clientId:string (query)`, `userId:string (query/body)`
- `GET /players`: `clientId:string (query)`, `userId:string (query/body)`
- `GET /users`: `clientId:string (query)`, `userId:string (query/body)`
- `GET /user`: `clientId:string (query)`, `id:string (query)`, `name:string (query)`, `userId:string (query/body)`
- `POST /user`: `name*:string (body)`, `clientId:string (query)`, `role:number (body)`, `password:string (body)`, `userId:string (query/body)`
- `PUT /user`: `data*:object (body)`, `clientId:string (query)`, `id:string (body/query)`, `name:string (body/query)`, `userId:string (query/body)`
- `DELETE /user`: `clientId:string (query)`, `id:string (query)`, `name:string (query)`, `userId:string (query/body)`
- `GET /scene`: `clientId:string (query)`, `sceneId:string (query)`, `name:string (query)`, `active:boolean (query)`, `viewed:boolean (query)`, `all:boolean (query)`, `userId:string (query/body)`
- `GET /scene/image/raw`: `clientId:string (query)`, `sceneId:string (body/query)`, `active:boolean (body/query)`, `userId:string (query/body)`
- `POST /scene`: `data*:object (body)`, `clientId:string (query)`, `userId:string (query/body)`
- `PUT /scene`: `data*:object (body)`, `clientId:string (query)`, `sceneId:string (body/query)`, `name:string (body/query)`, `active:boolean (body/query)`, `userId:string (query/body)`
- `DELETE /scene`: `clientId:string (query)`, `sceneId:string (query)`, `name:string (query)`, `userId:string (query/body)`
- `POST /switch-scene`: `clientId:string (query)`, `sceneId:string (body/query)`, `name:string (body/query)`, `userId:string (query/body)`
- `GET /canvas/:documentType`: `documentType*:string (path)`, `clientId:string (query)`, `sceneId:string (query)`, `documentId:string (query)`, `userId:string (query/body)`
- `GET /measure-distance`: `clientId:string (query)`, `originX:number (body/query)`, `originY:number (body/query)`, `targetX:number (body/query)`, `targetY:number (body/query)`, `originUuid:string (body/query)`, `originName:string (body/query)`, `targetUuid:string (body/query)`, `targetName:string (body/query)`, `sceneId:string (body/query)`, `userId:string (query/body)`
- `POST /canvas/:documentType`: `documentType*:string (path)`, `data*:object (body)`, `clientId:string (query)`, `sceneId:string (body/query)`, `userId:string (query/body)`
- `PUT /canvas/:documentType`: `documentType*:string (path)`, `documentId*:string (body/query)`, `data*:object (body)`, `clientId:string (query)`, `sceneId:string (body/query)`, `userId:string (query/body)`
- `DELETE /canvas/:documentType`: `documentType*:string (path)`, `documentId*:string (query)`, `clientId:string (query)`, `sceneId:string (query)`, `userId:string (query/body)`
- `POST /move-token`: `x*:number (body/query)`, `y*:number (body/query)`, `clientId:string (query)`, `uuid:string (body/query)`, `name:string (body/query)`, `waypoints:array (body/query)`, `animate:boolean (body/query)`, `sceneId:string (body/query)`, `userId:string (query/body)`
- `GET /chat`: `clientId:string (query)`, `limit:number (query)`, `offset:number (query)`, `userId:string (query/body)`, `chatType:number (query)`, `speaker:value (query)`
- `POST /chat`: `content*:string (body)`, `clientId:string (query)`, `whisper:array (body)`, `speaker:value (body)`, `alias:string (body)`, `chatType:number (body)`, `flavor:string (body)`, `userId:string (query/body)`
- `DELETE /chat/:messageId`: `messageId*:string (path)`, `clientId:string (query)`, `userId:string (query/body)`
- `DELETE /chat`: `clientId:string (query)`, `userId:string (query/body)`
- `GET /effects`: `uuid*:string (body/query)`, `clientId:string (query)`, `userId:string (query/body)`
- `GET /effects/list`: `clientId:string (query)`, `userId:string (query/body)`
- `POST /effects`: `uuid*:string (body/query)`, `clientId:string (query)`, `statusId:string (body/query)`, `effectData:object (body/query)`, `userId:string (query/body)`
- `DELETE /effects`: `uuid*:string (body/query)`, `clientId:string (query)`, `effectId:string (body/query)`, `statusId:string (body/query)`, `userId:string (query/body)`
- `GET /world-info`: `clientId:string (query)`, `userId:string (query/body)`
- `GET /playlists`: `clientId:string (query)`, `userId:string (query/body)`
- `POST /playlist/play`: `clientId:string (query)`, `playlistId:string (body/query)`, `playlistName:string (body/query)`, `soundId:string (body/query)`, `soundName:string (body/query)`, `userId:string (query/body)`
- `POST /playlist/stop`: `clientId:string (query)`, `playlistId:string (body/query)`, `playlistName:string (body/query)`, `userId:string (query/body)`
- `POST /playlist/next`: `clientId:string (query)`, `playlistId:string (body/query)`, `playlistName:string (body/query)`, `userId:string (query/body)`
- `POST /playlist/volume`: `volume*:number (body/query)`, `clientId:string (query)`, `playlistId:string (body/query)`, `playlistName:string (body/query)`, `soundId:string (body/query)`, `soundName:string (body/query)`, `userId:string (query/body)`
- `POST /play-sound`: `src*:string (body/query)`, `clientId:string (query)`, `volume:number (body/query)`, `loop:boolean (body/query)`, `userId:string (query/body)`
- `POST /stop-sound`: `clientId:string (query)`, `src:string (body/query)`, `userId:string (query/body)`
- `GET /file-system`: `clientId:string (query)`, `path:string (query)`, `source:string (query)`, `recursive:boolean (query)`, `userId:string (query/body)`
- `GET /download`: `clientId:string (query)`, `path:string (query)`, `source:string (query)`, `format:string (query)`, `userId:string (query/body)`
- `POST /macro/:uuid/execute`: `uuid*:string (path)`, `clientId:string (query)`, `args:object (body)`, `userId:string (query/body)`
- `POST /execute-js`: `clientId:string (query)`, `script:string (body)`, `userId:string (query/body)`
- `GET /scene/image`: `sceneId:string (query)`, `active:boolean (query)`, `clientId:string (query)`, `format:string (query)`, `quality:number (query)`, `viewport:boolean (query)`, `width:number (query)`, `height:number (query)`, `showGrid:boolean (query)`, `hideOverlays:boolean (query)`, `userId:string (query)`
- `POST /upload`: `clientId:string (query)`, `path:string (body/query)`, `filename:string (body/query)`, `source:string (body/query)`, `mimeType:string (body/query)`, `overwrite:boolean (body/query)`, `fileData:string (body)`, `userId:string (query/body)`
- `GET /sheet`: `uuid:string (query)`, `selected:boolean (query)`, `actor:boolean (query)`, `clientId:string (query)`, `format:string (query)`, `quality:number (query)`, `scale:number (query)`, `userId:string (query)`
- `GET /dnd5e/get-actor-details`: `actorUuid*:string (body/query)`, `details*:array (body/query)`, `clientId:string (query)`, `userId:string (query/body)`
- `POST /dnd5e/modify-item-charges`: `actorUuid*:string (body/query)`, `amount*:number (body/query)`, `clientId:string (query)`, `itemUuid:string (body/query)`, `itemName:string (body/query)`, `userId:string (query/body)`
- `POST /dnd5e/short-rest`: `clientId:string (query)`, `actorUuid:string (body/query)`, `selected:boolean (query/body)`, `autoHD:boolean (body/query)`, `autoHDThreshold:number (body/query)`, `userId:string (query/body)`
- `POST /dnd5e/long-rest`: `clientId:string (query)`, `actorUuid:string (body/query)`, `selected:boolean (query/body)`, `newDay:boolean (body/query)`, `userId:string (query/body)`
- `POST /dnd5e/skill-check`: `actorUuid*:string (body/query)`, `skill*:string (body/query)`, `clientId:string (query)`, `userId:string (query/body)`, `advantage:boolean (body/query)`, `disadvantage:boolean (body/query)`, `bonus:string (body/query)`, `createChatMessage:boolean (body/query)`
- `POST /dnd5e/ability-save`: `actorUuid*:string (body/query)`, `ability*:string (body/query)`, `clientId:string (query)`, `userId:string (query/body)`, `advantage:boolean (body/query)`, `disadvantage:boolean (body/query)`, `bonus:string (body/query)`, `createChatMessage:boolean (body/query)`
- `POST /dnd5e/ability-check`: `actorUuid*:string (body/query)`, `ability*:string (body/query)`, `clientId:string (query)`, `userId:string (query/body)`, `advantage:boolean (body/query)`, `disadvantage:boolean (body/query)`, `bonus:string (body/query)`, `createChatMessage:boolean (body/query)`
- `POST /dnd5e/death-save`: `actorUuid*:string (body/query)`, `clientId:string (query)`, `advantage:boolean (body/query)`, `createChatMessage:boolean (body/query)`, `userId:string (query/body)`
- `POST /dnd5e/modify-experience`: `amount*:number (body/query)`, `clientId:string (query)`, `actorUuid:string (body/query)`, `selected:boolean (query/body)`, `userId:string (query/body)`
- `GET /dnd5e/concentration`: `clientId:string (query)`, `actorUuid:string (body/query)`, `actorName:string (body/query)`, `userId:string (query/body)`
- `POST /dnd5e/break-concentration`: `clientId:string (query)`, `actorUuid:string (body/query)`, `actorName:string (body/query)`, `userId:string (query/body)`
- `POST /dnd5e/concentration-save`: `damage*:number (body/query)`, `clientId:string (query)`, `actorUuid:string (body/query)`, `actorName:string (body/query)`, `userId:string (query/body)`, `advantage:boolean (body/query)`, `disadvantage:boolean (body/query)`, `bonus:string (body/query)`, `createChatMessage:boolean (body/query)`
- `POST /dnd5e/equip-item`: `equipped*:boolean (body/query)`, `clientId:string (query)`, `actorUuid:string (body/query)`, `actorName:string (body/query)`, `itemUuid:string (body/query)`, `itemName:string (body/query)`, `userId:string (query/body)`
- `POST /dnd5e/attune-item`: `attuned*:boolean (body/query)`, `clientId:string (query)`, `actorUuid:string (body/query)`, `actorName:string (body/query)`, `itemUuid:string (body/query)`, `itemName:string (body/query)`, `userId:string (query/body)`
- `POST /dnd5e/transfer-currency`: `currency*:object (body/query)`, `clientId:string (query)`, `sourceActorUuid:string (body/query)`, `sourceActorName:string (body/query)`, `targetActorUuid:string (body/query)`, `targetActorName:string (body/query)`, `userId:string (query/body)`
- `POST /dnd5e/modify-currency`: `actorUuid*:string (body/query)`, `currency*:string (body/query)`, `amount*:number (body/query)`, `clientId:string (query)`, `userId:string (query/body)`
- `POST /dnd5e/prepare-spell`: `actorUuid*:string (body/query)`, `spellName*:string (body/query)`, `prepared*:boolean (body/query)`, `clientId:string (query)`, `userId:string (query/body)`
- `POST /dnd5e/use-ability`: `actorUuid*:string (body/query)`, `clientId:string (query)`, `abilityUuid:string (body/query)`, `abilityName:string (body/query)`, `targetUuid:string (body/query)`, `targetName:string (body/query)`, `userId:string (query/body)`
- `POST /dnd5e/use-feature`: `actorUuid*:string (body/query)`, `clientId:string (query)`, `abilityUuid:string (body/query)`, `abilityName:string (body/query)`, `targetUuid:string (body/query)`, `targetName:string (body/query)`, `userId:string (query/body)`
- `POST /dnd5e/use-spell`: `actorUuid*:string (body/query)`, `clientId:string (query)`, `abilityUuid:string (body/query)`, `abilityName:string (body/query)`, `targetUuid:string (body/query)`, `targetName:string (body/query)`, `userId:string (query/body)`
- `POST /dnd5e/use-item`: `actorUuid*:string (body/query)`, `clientId:string (query)`, `abilityUuid:string (body/query)`, `abilityName:string (body/query)`, `targetUuid:string (body/query)`, `targetName:string (body/query)`, `userId:string (query/body)`

## Upstream compatibility

The route and protocol reference is ThreeHats' Go relay at
[`65ce83d6a534ea6d340c8a89d72251f4c6a0294e`](https://github.com/ThreeHats/foundryvtt-rest-api-relay/tree/65ce83d6a534ea6d340c8a89d72251f4c6a0294e/go-relay),
together with the unversioned [official API documentation](https://foundryrestapi.com/docs/api).
All 91 of its ordinary forwarding routes are present: 70 general and 21
D&D5e. A matching method and path does not imply identical behavior:

- **Client list.** `GET /clients` returns a bare array with `connected`. The
  reference returns `{"total":n,"clients":[...]}` with `isOnline` and other
  per-client fields.
- **Event filters.** Stream filters are ignored: `speaker`, `type`,
  `whisperOnly`, and `userId` on chat; `userId` on rolls; `hooks`;
  `encounterId`; `actorUuid`; and `sceneId`. Every subscriber receives all of
  its channel's events, so a stream is not permission-scoped. The reference
  ends streams when a world disconnects, limits the subscription count, and
  requires `clientId`; this relay keeps streams across reconnects with a
  bounded queue and selects a single online world automatically.
- **Capacity.** Request bodies and module messages are limited to 16 MiB,
  including base64 and JSON overhead. The reference accepts uploads of up to
  250 MiB. Large downloads and screenshots can exceed the module message limit.
- **Script screening.** `POST /execute-js` and Macro `POST /create` are
  forwarded without the reference's forbidden-pattern screen or scope checks.
  The single API key has full authority over every paired world.
- **Input and errors.** This relay requires typed JSON input and a data URL
  for JSON uploads. It returns 503 for an offline world, 400 for an ambiguous
  forwarding selection, and 429 at the pending limit, where the reference
  returns 404 or starts the world. Error bodies differ.
- **Canvas.** `POST /canvas/:documentType` requires an object `data`, as the
  reference does, although the official documentation also describes arrays.
- **Sessions.** The [session API](sessions.md) reuses an existing pairing
  instead of minting a connection token, keeps all session state in memory,
  and does not capture the browser console.

These reference surfaces are absent: the consumer WebSocket `GET /ws/api`,
including its subscriptions and interactive sheet control; the cross-world
module tunnel (`remote-request`); the deprecated `GET /contents/*`, which
returns 404 here; `GET /api/status` and `GET /api/health` (the local
`/health` is not schema-compatible); and `/openapi.json`, `/asyncapi.json`,
and `/api/docs`.

The service features of the reference are out of scope for this single-user
relay: delegated key requests, accounts and scoped API keys, dashboard pairing
and the credential vault, notifications and activity logs, administration,
billing, metrics, Redis clustering, and the web frontend.
`DELETE /clients/:clientId` is a local extension.
