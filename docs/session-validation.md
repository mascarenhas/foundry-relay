# Session API validation

Validated on 2026-10-11. These checks extend the historical
[relay validation](validation.md).
The production server and native tests are Titan; the live experiment's
temporary client driver is validation tooling under ignored `build/`.

## Linux x86_64

The final 13-root native executable selected **328 tests: 327 passed and one
Windows-only exclusive-file-sharing regression skipped**. The earlier session
implementation passed 326 tests with no skips before the endpoint regressions
were added. The application and test translation units used `-O0 -fno-lto`;
the existing installed
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
- Preservation of unrelated endpoint-file errors. The deterministic Windows
  exclusive-publisher regression runs on Windows below.
- The existing static-executable relocation, SQLite, HTTP/WebSocket, routing,
  and SSE regressions.

The installed Chrome launcher uses Flatpak. The first aggregate invocation used
the tool's different D-Bus/runtime-directory environment and both Chrome children
exited during startup. Repeating with the working desktop integration variables
used by the live relay passed all 326 original cases. The final follow-up also
passed all applicable cases in that environment. Browser security settings were not
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
| Live-tested relay executable before the Windows endpoint fix | `67cdb2fd14e1feb6ce49aa2a9fedf302bd2961c86966c45d7a3c85a0a7ed00c4` |
| Final native-tested relay executable | `6225b2a2678927c66997ef867b5f64e0cbef7289bb38ab3d896d90f0824fd242` |

## Live HTTPS Foundry

The session implementation was tested against Foundry **14.368**, REST API module
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

After the authorized VM restart, the final Windows 11 x64 application and
12-root native suite compiled against the existing NTFS SDK. The fixed suite
selected **327 cases: 309 passed, 18 POSIX platform cases skipped, no failures**.
All crypto, session-manager, and enabled HTTP tests ran. Both installed Edge
lifecycle cases passed, including process/profile cleanup and refusal of the
owned debugging port after close.

Four additional normal-close/aborted-CDP pairs passed, making ten actual Edge
startups across the full suite and repeated checks. Each checked debugging-port
retirement; no additional Edge processes or owned profiles remained after the
observed runs.

All 18 application/test PE images passed the x64/import audit. The relocated
application answered health, SQLite-backed pairing, and authenticated client
listing from a Unicode path and another working directory with only Windows
system directories on `PATH`. Chromium remains a separately installed runtime
dependency.

The final 30-file source archive is
`7296b3e0bd7cd13d909bfff645ab28e536341b5110e17c04b28c738df9696d39`.
Application/test translation units used `-O0`. The reused prepared standard
provider was verified before the fixed build at SHA256
`f56df0c4e5a4734c7c4e459a8481e2a3fab2dedb3ea36e47a9d4dd97920bcbb1`.
The independent crypto client was MSYS2 OpenSSL **3.6.5**; the application used
the SDK's OpenSSL DLLs. Installed Edge was **154.0.4258.53**. These are
prepared-SDK checks, not a fresh build of `TITAN_REVISION`.

The pre-fix archive
`c05af68fc5d24dd9e9bd290b47a75f4ae18f4e60ac9d969581c4a2277302f4ba`
compiled but its full run had 306 passes, 18 skips, and one browser startup
failure. Failure-only diagnostics then captured `EBUSY` from `fs.open` while
reading `DevToolsActivePort`: Edge exposes the file while its publisher still
holds an exclusive write handle. The relay now treats only that exact busy open
as pending readiness, polling within the original startup deadline. Unrelated
errors and malformed endpoint contents still fail; browser security settings
and the startup timeout were not relaxed.

A deterministic native Windows fixture holds a real exclusive writer, first
verifies the underlying `EBUSY`/`fs.open`, then checks pending readiness and
successful reading after release. The regression failed with the pre-fix read
behavior and passed with the fix. A separate regression verifies that `ENOENT`
is preserved. The Linux timeout/cancellation tests and the actual Edge lifecycle
cases cover the surrounding startup and retirement behavior.

The live Foundry REST experiment above ran on Linux; Windows validation used
native HTTP/CDP fixtures and installed Edge lifecycle checks.

The final per-run cleanup checks passed, but later SSH resets prevented an
additional global VM rescan and confirmation that two original-source backup
files were removed. Diagnostic source and generated payloads had already been
restored/removed, and the negative-control tree was removed before the fixed
build. The tested application/test payloads remain in the VM's owned
`foundry-relay-session-api-20261011/source-fixed/build/windows` tree; the VM was
left running. The sanitized local receipt is
`build/windows-session-validation-20261011/final-fixed-receipt.json`.

## Independent review

Independent reviewers checked the API audit, source, ownership/cancellation
behavior, crypto boundary, native tests, client examples, and documentation.
The stale-reservation regression was observed failing before its fix and passing
afterward. Review also led to preserving failed browser retirement in the
ordinary executable's shutdown exit status and checking debugging-port retirement.
