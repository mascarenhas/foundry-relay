# Session API validation

Validated on 2026-10-11. These checks extend the historical
[relay validation](validation.md) and [headless spike](headless-spike.md).
The production server and native tests are Titan; the live experiment's
temporary client driver is validation tooling under ignored `build/`.

## Linux x86_64

The final 13-root native executable passed **326 tests with no skips**. The
application and test translation units used `-O0 -fno-lto`; the existing installed
Titan standard provider retained its production profile. This does not claim
a fully instrumented or validation-profile SDK rebuild. The suite includes:

- Independent OpenSSL-client RSA-OAEP/SHA-256/MGF1 interoperability, Unicode
  credentials, malformed Base64, wrong digests, closed keys, and key reuse.
- One-shot and expired handshakes, nonce/type validation, admission bounds,
  existing-pairing selection, concurrent starts, cancellation before controller
  entry, stale handler cleanup, failed response publication, quarantine after
  cleanup failure, monitoring, and shutdown.
- Real loopback HTTP handling of handshake/start/list/end, replay and duplicate
  starts, sanitized startup failure and retry, duplicate headers, and failed
  cleanup with shared-resource teardown.
- Two installed Chrome lifecycle cases: normal close and recovery after an
  aborted CDP connection. Both verify process/profile retirement and refusal of
  the owned loopback debugging port after close.
- The existing static-executable relocation, SQLite, HTTP/WebSocket, routing,
  and SSE regressions.

The installed Chrome launcher uses Flatpak. The first aggregate invocation used
the tool's different D-Bus/runtime-directory environment and both Chrome children
exited during startup. Repeating with the working desktop integration variables
used by the live relay passed all 326 cases. Browser security settings were not
weakened. An operator must run a desktop-dependent launcher in its supported
environment; a native Chromium executable need not use that launcher.

The prepared SDK at `/home/mascarenhas/.local/titan` predates the coverage compiler
pin in `TITAN_REVISION`. These session checks used that installed SDK; they did
not validate the newer coverage workflow or update the pin. Identifying SHA256s:

| Input | SHA256 |
| --- | --- |
| Installed `titanc` | `77868b858e8459eccf4a0155fd06216732170516a889fdeb0402c42bdc9b6da0` |
| Installed `driver.lua` | `048716414084c788b1c66be53e13cfb3b49e7e9f5f67e9606e7f9a2d8118ce0d` |
| Installed `titan.so` | `c76e16ca9f2008ea033c5e4c1265758bf8ef03dd423aa60b71c42c1ea8a970f4` |
| Installed `titan.a` | `de1998774d08f98dd996d72cb9be3a5f99258da6370df2d6ddd19ec99a55cb4c` |
| Tested relay executable | `67cdb2fd14e1feb6ce49aa2a9fedf302bd2961c86966c45d7a3c85a0a7ed00c4` |

## Live HTTPS Foundry

The final executable was tested against Foundry **14.368**, REST API module
**3.4.1**, and Chrome **155.0.8059.39**. The existing world pairing was reused;
the full GM account was supplied through the authorized private test fixture.
The application itself does not read that fixture.

The experiment passed handshake, encrypted start, replay rejection, and six
session-list plus read-only `world-info` checks over 60 seconds. Ending the
session removed its owned browser process tree and private profile; the list was
empty and a repeated end returned 404. A fresh handshake then started a second
session. SIGTERM exited with code zero and retired that active session's browser
tree and profile. This proves fresh startup after end, not automatic session
resume across a relay restart.

The installed ordinary relay was restored with its saved binary, environment,
and working directory, under a retained pipe supervisor. Fixture bytes and the
persisted client IDs, pairing tokens, world IDs, and origins were unchanged.
No world documents or module settings were mutated. The sanitized observation
receipt is `build/session-live-receipt.json`; private credentials and launch
configuration are excluded from Git.

## Local Windows VM

Native Windows 11 x64 compilation and Unicode relocation passed using the
existing, unchanged NTFS SDK. All 18 application/test PE images passed the
import audit. The relocated application answered health, SQLite-backed pairing,
and authenticated client listing from another working directory with only
Windows system directories on `PATH`.

The tested source archive was
`8b79aaf2b0f9af9950428f38e3406caaf95fcaafb20c4b5e69482f2be0857a2a`.
Its 11-root suite rerun selected **321 cases: 303 passed and 18 platform cases
skipped**. The six crypto test functions and all 16 session-manager functions
ran, using an explicitly selected MSYS2 OpenSSL client. The standard provider
remained unchanged at SHA256
`f56df0c4e5a4734c7c4e459a8481e2a3fab2dedb3ea36e47a9d4dd97920bcbb1`.

Installed Edge **154.0.4258.53** startup failed intermittently. Both normal
retirement and aborted-CDP recovery passed on the full rerun, but isolated
runs reproduced startup failure. Successful starts took roughly 0.5–0.7 seconds;
there is no evidence that increasing the startup timeout fixes this issue.
Owned processes and profiles were removed after the observed test runs.
Compilation and those successful runs do not establish reliable Windows browser
startup.

The final 30-file source archive
`c05af68fc5d24dd9e9bd290b47a75f4ae18f4e60ac9d969581c4a2277302f4ba`
adds the enabled HTTP tests, debugging-port assertion, shutdown-error handling,
and Windows summary-stream correction. It is staged on the VM but remains
unvalidated there: the pinned SSH transport began resetting connections and the
guest agent is disconnected. Temporary diagnostic source edits in the owned VM
test directory still need restoration from their exact backup. Neither the
prepared SDK nor browser installation was changed; no service, network, or VM
restart was attempted to work around the transport failure.

## Independent review

Independent reviewers checked the API audit, source, ownership/cancellation
behavior, crypto boundary, native tests, client examples, and documentation.
The stale-reservation regression was observed failing before its fix and passing
afterward. Review also led to preserving failed browser retirement in the
ordinary executable's shutdown exit status and checking debugging-port retirement.
