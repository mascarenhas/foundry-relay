# REST relay API

The relay implements 91 declarative forwarding routes from the reference Go relay. Authenticated requests use `x-api-key: $FOUNDRY_REST_API_KEY`. Normal endpoints live at the root URL, for example `/search` and `/get`.

Pass `clientId` in the query string when several Foundry worlds are connected. With exactly one connected world, the server selects it automatically. Use `userId` (a Foundry user ID or username) to request permission-scoped operations; omission uses the connected GM's authority.

Each route extracts only its declared parameters, validates their types, and forwards them as top-level WebSocket fields. The relay owns `type` and `requestId`. Unknown fields, client-supplied protocol fields, and `_scopes` are ignored. `data` is the entity data object. Explicit nested JSON nulls and trailing array nulls survive the round trip.

Query values accept case-insensitive `true`/`false`, finite JSON numbers, and JSON arrays/objects where declared. URL-encode structured query values. The parameter inventory lists source precedence: `body/query` checks the body first, while `query/body` checks the query first. False and zero body values remain present; empty query values are omitted. Object body parameters require actual JSON objects, rather than JSON strings containing object text. Most behavioral defaults are applied by the Foundry module.

Ordinary responses preserve the complete Foundry result object, including its `<action>-result` type and relay-generated request ID. A top-level `error` field produces HTTP 400. Timeouts are 10 seconds by default; filesystem listings allow 15 seconds, JavaScript and sheets 20 seconds, scene/canvas changes, uploads and scene screenshots 30 seconds, and downloads 45 seconds.

Canvas document types are `tokens`, `tiles`, `drawings`, `lights`, `sounds`, `notes`, `templates`, `walls`, and `regions`. The relay adds the corresponding Foundry `className`.

`GET /download` decodes base64 `fileData` to binary and supplies `Content-Type` and `Content-Disposition`; `?format=base64` preserves JSON. `/sheet` and `/scene/image` return decoded image bytes with `X-Image-Width` and `X-Image-Height`; `?format=base64` also preserves their JSON. `/scene/image/raw` returns the module's ordinary JSON result. Screenshots default to PNG and quality 0.9; sheets default to scale 1.

`POST /upload` accepts JSON `path`, `filename`, and `fileData` formatted as `data:<mime>;base64,<bytes>`. `source` defaults to `data`. The server also adapts raw binary request bodies to a data URL. Files pass through Foundry's file API and are not persisted in the relay database.

Six separate SSE endpoints subscribe to module events: `/chat/subscribe`, `/rolls/subscribe`, `/hooks/subscribe`, `/encounters/subscribe`, `/actor/subscribe`, and `/scene/subscribe`. Subscriptions activate Foundry hooks only while consumers are present. The server handles these outside the ordinary request/response catalog.

## Forwarding routes

Required parameter names are listed below. Path parameters are decoded independently; an encoded slash cannot create another path segment.

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

Names marked `*` are required. `speaker` accepts both strings and Foundry speaker objects. Source order is significant.

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
- `GET /canvas/:documentType`: `documentType*:string (params)`, `clientId:string (query)`, `sceneId:string (query)`, `documentId:string (query)`, `userId:string (query/body)`
- `GET /measure-distance`: `clientId:string (query)`, `originX:number (body/query)`, `originY:number (body/query)`, `targetX:number (body/query)`, `targetY:number (body/query)`, `originUuid:string (body/query)`, `originName:string (body/query)`, `targetUuid:string (body/query)`, `targetName:string (body/query)`, `sceneId:string (body/query)`, `userId:string (query/body)`
- `POST /canvas/:documentType`: `documentType*:string (params)`, `data*:object (body)`, `clientId:string (query)`, `sceneId:string (body/query)`, `userId:string (query/body)`
- `PUT /canvas/:documentType`: `documentType*:string (params)`, `documentId*:string (body/query)`, `data*:object (body)`, `clientId:string (query)`, `sceneId:string (body/query)`, `userId:string (query/body)`
- `DELETE /canvas/:documentType`: `documentType*:string (params)`, `documentId*:string (query)`, `clientId:string (query)`, `sceneId:string (query)`, `userId:string (query/body)`
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

## Pairing compatibility

Use the Foundry module's manual pairing-code flow with six-character `FOUNDRY_PAIRING_CODE`. The environment code can pair multiple worlds. Each exchange creates a distinct connection token bound to its persistent world registration.

The module posts `/auth/pair` with `code`, `worldId`, `worldTitle`, `serverFingerprint`, `existingClientId`, and `serverOrigin`. It receives `token`, `clientId`, and `relayUrl`. It connects to `/relay?id=<clientId>` with nonsecret world/system query metadata, sends `{"type":"auth","token":"..."}` as its first text frame, then waits for `{"type":"auth-success"}`. Tokens never appear in URLs. SQLite preserves registrations and tokens across relay restarts; the database is created with mode `0600` on POSIX. Windows deployments require a private user directory protected by its ACL.

Public `GET /api/clients/:clientId/active` returns `{"active":true|false}` for registered clients and 404 for unknown IDs. `POST /api/self-unpair` uses its body connection token to revoke that browser's token while preserving the world registration.

The reference frontend, accounts, scoped-key tenancy, billing, external notifications, Redis clustering, browser-driven headless sessions, and interactive screenshot-control transport are outside this single-user application's scope. The D&D5e forwarding routes are included and require a compatible D&D5e world.
