# Headless Foundry client spike

This opt-in executable tests a real, long-lived Foundry browser client driven by
native Titan code. `relay/cdp.titan` implements a private, single-command-at-a-time
Chrome DevTools Protocol transport over Titan WebSocket. `relay/browser.titan`
owns Chrome, its temporary profile, output drains and shutdown. The Foundry
session policy takes explicit options; it does not depend on a particular world
or on a production configuration file.

The original spike uses a local fixture in place of caller-supplied inputs.
The ordinary relay now implements the [session API](sessions.md), including
the RSA handshake, encrypted start payload, registry, and HTTP lifecycle.
This retained harness uses its explicit fixture inputs
only during this experiment.

## Build and run

Use the same installed Titan SDK and OpenSSL mode as the ordinary application:

```sh
make headless TITANC=/path/to/sdk/bin/titanc
mkdir -p build/browser-profiles
build/foundry-relay-headless /path/to/local-fixture /path/to/chrome \
  "$PWD/build/browser-profiles"
```

The executable inherits the existing relay configuration, including API key,
pairing code, database, bind address, public relay URL and allowed origins.
Choose a free relay port for isolated testing, or stop the existing relay before
using its port. The executable does not install itself or replace an installed
binary. The browser profile parent must already exist and be visible to the
Chrome process; a directory under the repository works with a home-enabled
Flatpak installation.

Fixture lines are literal `KEY=value` data, with blank lines and `#` comments.
A bare key means an empty value. The required keys are `FOUNDRY_URL`,
`WORLD_NAME` (world ID), and `GM_USER`. `GM_PASSWORD` may be empty.
`ADMIN_PASSWORD` is accepted for the local fixture but is unused: this spike
requires an already launched world and does not administer Foundry setup.
Quoted strings, variable expansion and shell commands are not interpreted.
`.world` is ignored by Git; pass its path explicitly if using that local name.
Keep fixture credentials out of commits, logs and copied build evidence.

## Ownership and readiness

Chrome uses its normal sandbox and certificate checks, a new private profile,
and an ephemeral debugging port bound to `127.0.0.1`. There is no public CDP or
evaluation endpoint. The browser child inherits desktop launch settings, with
the relay API key and pairing code overridden to empty values. Browser output,
console messages, CDP expressions and page exception text are not logged.
Failure logs use a fixed set of configuration and lifecycle reasons; unfamiliar
errors produce a generic failure message.

The Foundry page runs in a separate off-the-record browser context, created
through [CDP](https://chromedevtools.github.io/devtools-protocol/tot/Target/#method-createBrowserContext)
with `disposeOnDetach`. Its cookies and local storage stay in memory;
the context ends when its owning CDP connection detaches. This also avoids
waiting for the desktop keyring to initialize the unused profile's disk cookie
store. Chrome's password-store configuration remains unchanged. The temporary
profile still holds Chrome's ordinary process state and must be retired.

The client must already be paired in the relay database. The spike selects an
unambiguous existing pairing for the requested world and Foundry origin and
refuses to start when that client is already online. In the disposable profile,
it verifies the exact world, configured full GM and both existing relay URL
pointers before placing the existing connection token in client-local storage.
It creates no pairing grant and writes no world-scoped relay settings.

Readiness requires the module's authentication hook in the owned page, the
matching authenticated relay connection, and a successful read-only
`world-info` response. An open WebSocket alone is insufficient. The session
continues checking browser and relay liveness after readiness.

`SIGTERM` or `SIGINT` stops the owned session and relay. Browser cleanup runs in
a normal cleanup Task before Runtime shutdown: it attempts `Browser.close`,
using one fresh connection to the same private endpoint if the original CDP
connection has failed. After an acknowledged close, it allows up to two seconds
for its child to exit naturally before escalating to termination. It aborts CDP,
reaps its child, drains captured streams and removes the owned profile without
following symlinks. Once the private debugging endpoint has been observed, if
neither CDP close attempt succeeds, cleanup reports failure and retains the
profile for owned-instance recovery. It does not promise recovery after
process-wide crashes or abrupt Runtime failure. With a browser wrapper such as
Flatpak, live validation must additionally establish that the dedicated Chrome
instance exits; reaping the wrapper alone is insufficient evidence.

## Validation scope

Native Titan tests cover CDP correlation and sanitized failures, deadlines and
cancellation, browser startup failures and process/profile retirement, fixture
validation, and existing-pairing selection. The fake browser process tests use
POSIX shell fixtures and skip on Windows. This spike's live browser validation
targets Linux; it does not extend the application's earlier Windows evidence.

The installed SDK used for this spike is recorded separately from the repository
`TITAN_REVISION` coverage pin. Passing with an installed compiler is not proof
that the exact pinned compiler produced the executable. Coverage baseline
figures in `coverage.md` describe the earlier measured ordinary application;
they are not new measurements of these spike modules.

## Local validation, 2026-10-11

The complete native executable passed 278 cases. The final focused browser suite
passed 18 cases, including the startup deadline while awaiting Page activation.
Independent reviewers checked the CDP transport, browser ownership, Foundry
policy and documentation.

Live probes used Google Chrome 155.0.8059.39 on x86_64 Linux through its installed
Flatpak launcher. The configured HTTPS Foundry join page loaded with normal TLS
verification and sandboxing. Normal shutdown and recovery after an aborted CDP
transport each retired the dedicated Chrome instance and profile. A controlled
comparison confirmed that `Page.enable` is required for preload execution in
this Chrome build; the owned session now enables it during startup.

The authenticated test reached the module's relay-authentication hook, the
matching online relay client and a successful `world-info` response. Six
additional authenticated REST `world-info` requests returned HTTP 200 over a
one-minute observation period. `SIGTERM` then stopped the headless executable
with exit 0; the dedicated Chrome process tree, debugger listener and temporary
profile retired. The installed relay was restored afterward. The fixture and
existing pairing credentials were unchanged by the test. Only fixed flags and
status codes were inspected; no credentials or notification text were recorded.

These builds used the installed SDK at `/home/mascarenhas/.local/titan`, whose
provider profile is `production`, with application/test consumers compiled using
`-O0 -fno-lto`. Its compiler predates the repository's coverage pin. The consumed
files had these SHA-256 digests:

| SDK file | SHA-256 |
| --- | --- |
| `bin/titanc` | `77868b858e8459eccf4a0155fd06216732170516a889fdeb0402c42bdc9b6da0` |
| `share/lua/5.5/titan-compiler/driver.lua` | `048716414084c788b1c66be53e13cfb3b49e7e9f5f67e9606e7f9a2d8118ce0d` |
| `lib/titan/0.6/titan.so` | `c76e16ca9f2008ea033c5e4c1265758bf8ef03dd423aa60b71c42c1ea8a970f4` |
| `lib/titan/0.6/titan.a` | `de1998774d08f98dd996d72cb9be3a5f99258da6370df2d6ddd19ec99a55cb4c` |
