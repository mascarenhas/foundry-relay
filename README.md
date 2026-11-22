# Foundry relay in Titan

A single-user REST-to-WebSocket relay for the Foundry VTT REST API module,
written in Titan (~4.6k LOC across 20 modules) on top of
[`titan-mk`](https://github.com/mascarenhas/mk) (`MIT` licensed; see
[`LICENSE`](LICENSE)). It implements the core protocol of
[ThreeHats' Go relay](https://github.com/ThreeHats/foundryvtt-rest-api-relay/tree/main/go-relay),
with SQLite persistence, an environment API key, and optional headless Chromium
sessions served by the same binary.

On Linux and macOS, `luarocks make` links the application, `titan-mk`, and
Titan's standard provider into a standalone static executable installed at
`<tree>/bin/foundry-relay`. On Windows, `luarocks make` installs the launcher
and `foundry_relay.dll` via `titan-install.bat`, and
[`Makefile.windows`](docs/build-and-testing.md#windows-build) packages a
relocatable EXE launcher with application and runtime DLLs. Neither layout
invokes or depends on the Titan compiler at runtime.

## Build, install, and test

Install a prepared Titan 0.6 SDK on `PATH` (including `luarocks`, `thread`,
`http`, `websocket`, `sqlite3`, `json`, `peg`, and compiled `titan.test`),
the `titan-mk` (`~> 0.1`) rock, a C compiler, and OpenSSL 3.0+ development
headers with `pkg-config`.

```sh
export PATH=/path/to/titan-prefix/bin:$PATH
luarocks make foundry-relay-0.1.0-1.rockspec
luarocks test foundry-relay-0.1.0-1.rockspec
luarocks test foundry-relay-0.1.0-1.rockspec -- --filter='^tests[.]integration_test'
```

On Linux and macOS, `luarocks make foundry-relay-0.1.0-1.rockspec` compiles
`build/foundry-relay` via `titanc --incremental --static --output build`
against system OpenSSL and installs it as `<tree>/bin/foundry-relay` (remove
with `luarocks remove foundry-relay`). `luarocks test` builds
`build/foundry-relay` and `build/relay-tests` through
[`scripts/rock-test.lua`](scripts/rock-test.lua) and runs the native test
suite. On Windows, `luarocks make` installs `foundry-relay.exe` and publishes
`foundry_relay.dll` via `titan-install.bat` (remove with
`titan-uninstall foundry-relay`).

For `OPENSSL_MODE=bundled`, optional Chrome and OpenSSL test variables, and
Windows rockspec and relocatable payload builds, see
[Build and testing](docs/build-and-testing.md). For native executable line
coverage (`luarocks test foundry-relay-0.1.0-1.rockspec -- --coverage`), see
[Coverage](docs/coverage.md).

## Run

Choose an API key and a reusable six-character pairing code (ASCII letters and
digits; the relay uppercases it to match Foundry's code entry and compares
submitted codes exactly). Treat both values as secrets.

```sh
export FOUNDRY_REST_API_KEY='your-private-api-key'
export FOUNDRY_PAIRING_CODE='A4X9K2'
foundry-relay
```

By default the relay listens on `127.0.0.1:3010`, stores world credentials in
`relay.sqlite3` (mode `0600` on POSIX, inside an existing parent directory),
writes one JSON log object per line to `stderr`, and shuts down cleanly on
`SIGINT` and `SIGTERM`.

See [Configuration, Deployment, and Logging](docs/configuration.md) for all
environment variables, reverse-proxy TLS and browser origin rules, Windows ACL
guidance, and log collection. To run headless Chromium sessions through the
same server, configure `RELAY_CHROME` as described in
[Headless Foundry Sessions](docs/sessions.md).

## Pair a Foundry world

1. Open the Foundry world as a GM with the REST API module enabled.
2. Set the module relay URL to `ws://127.0.0.1:3010/relay` (or your configured
   `RELAY_PUBLIC_URL`).
3. Choose **Enter Code** in the module connection dialog and enter your
   `FOUNDRY_PAIRING_CODE`. The default **Pair** button expects the upstream
   browser-approval flow, which this relay omits.
4. Repeat in additional worlds with the same code.

Each world receives its own client ID and connection token, and credentials
survive relay restarts. See
[pairing and the module connection](docs/api.md#pairing-and-the-module-connection)
for re-pairing, token rotation, and revocation.

Once paired, query the relay with your API key:

```sh
curl -H "x-api-key: $FOUNDRY_REST_API_KEY" http://127.0.0.1:3010/clients
curl -H "x-api-key: $FOUNDRY_REST_API_KEY" \
  'http://127.0.0.1:3010/world-info?clientId=YOUR_CLIENT_ID'
```

Pass `clientId` when more than one world is online;
[request rules](docs/api.md#request-rules) specify world selection, and
[client list](docs/api.md#client-list) covers online and offline entries.

## Documentation

| Guide | Topics |
| --- | --- |
| [Configuration, Deployment, and Logging](docs/configuration.md) | Environment variables, reverse proxies and CORS origins, SQLite permissions, JSON stderr logs, and shutdown |
| [HTTP and WebSocket API](docs/api.md) | Local routes, pairing, event streams, deadlines, upstream differences, and all 91 forwarding routes |
| [Headless Foundry Sessions](docs/sessions.md) | Browser setup, RSA-OAEP credential encryption, Node.js and Python examples, and session lifecycle |
| [Inside `foundry-relay`](docs/index.md) | Multi-threaded Titan architecture, code walkthroughs, native and Windows builds, coverage, and retired records |
