# Titan master validation

Validated on 2026-10-25 against Titan `master` at
`14e07d16bec4efadfbad54f280415f49b8500923`, with Lua 5.5.1 at
`025bfc35df0885656de347fb7a7c377e90042a75`. The relay continues to select
`titanc` from `PATH`; no compiler-source pin or compiler API adaptation was
needed. Both platforms used a matching validation-profile SDK and system
OpenSSL 3.5.9, with application-generated files in their own `build/` trees.

Linux used a freshly built isolated SDK. All 92 installed compiler/parser Lua
files matched the producer sources. The M1 Mac reused an existing SDK as a
read-only consumer input: its source rock matched the exact producer revision,
all 86 installed compiler files matched, and its Lua sources matched the pinned
fork. No existing SDK was replaced.

## Complete suites

| Platform | Toolchain | Selected | Passed | Skipped | Failed |
| --- | --- | ---: | ---: | ---: | ---: |
| Linux x86_64 | GCC 16.2.1 | 406 | 405 | 1 | 0 |
| Apple M1 Max, macOS 27.0.1 (26A434), arm64 | Apple Clang 21.0.0 | 406 | 405 | 1 | 0 |

Both runs built the application and all 17 native test roots with the final
source. Installed Chromium checks, independent OpenSSL-client crypto checks,
loopback HTTP/WebSocket integration, threading, SQLite concurrency, logging
privacy, and executable relocation were enabled. Only the Windows-exclusive
file-sharing fixture was skipped. The SDK inventories remained unchanged:
1,600 regular files on Linux and 1,605 on macOS.

Linux used `make -j4 test` with the master SDK's `bin` first on `PATH`,
`TITAN_BUILD_PROFILE=validation`, `TITAN_PROBE_CACHE_DISABLE=1`, a writable
compiler cache, and the working desktop D-Bus environment for Flatpak Chrome.
`RELAY_TEST_CHROME` and `RELAY_TEST_BROWSER_PROFILES` enabled real browser cases.

The Mac used GNU Make 4.4.1 to build `all build/relay-tests`, then ran the complete
`build/relay-tests` image with the same SDK, executable, browser and OpenSSL
fixture environment. Because that host lacks GNU `timeout`, a Python
`subprocess.run(..., timeout=300)` supervisor provided the equivalent bound.
The final run exited zero after 102.45 seconds, using Chrome 156.0.8078.48.
No browser or logging assertions were weakened for platform validation.

## Session regression

The installed Foundry 14.369 join template uses `select[name="userId"]` with
internal account IDs as values and account names as option text. The relay
previously looked for `username` and assigned the display name directly. Login
now finds the exact displayed account name, verifies that it is selectable, and
submits its internal ID through the ordinary join form.

The current administrator login template has an unnamed form containing
`adminPassword`. The relay previously recognized only `form[name="auth"]`, so
this page remained pending until the startup deadline. It now recognizes the
current form and reports the finite `administrator_login_required` cause.

A controlled request to the existing relay reproduced HTTP 408 after 120.39
seconds. Its owned browser reached `/auth` with “Administrator Access Required.”
The local Foundry `/join` response independently confirmed that no game session
was active. The attempt left no active headless session or owned profile.
Launching the intended world remains an operator prerequisite; the relay does
not authenticate to Foundry administration or launch a world.

New native regressions use real Chromium CDP with synthetic HTML to execute the
production login/readiness JavaScript. They check opaque user IDs, password and
submitter preservation, selection events, unavailable/ambiguous accounts,
incomplete forms, origin rejection, and both administrator form shapes. A
separate case checks that logs retain only the finite administrator-login cause.
These DOM checks do not establish authentication to a running Foundry world.

An isolated relay built with the new master SDK repeated the same live request.
It returned the generic HTTP 500 startup error after 3.50 seconds and logged only
`foundry_readiness` / `administrator_login_required`. Its session list remained
empty, its owned profiles were removed, and it exited successfully. The ordinary
relay and its database were left unchanged.

## Forwarding timeout logs

The M1 suite exposed a scheduler-dependent logging gap: a forwarded request
could return HTTP 408 without a `request_timeout` record when the caller's timer
closed its reply channel and cancelled the world's pending timer first. Only
the world timer had emitted the event. Timeout logging now belongs to the reply
pool's final 408 result, covering both caller expiry and a world timeout reply.
The event is emitted once, and its type remains restricted to the request
catalog, with unknown actions recorded as `unknown`.

Deterministic reply-pool tests hold a request without any world timer, return an
early world 408, expire a zero-budget request without delivery, and check unknown
action privacy. All 18 reply-pool cases passed. Restoring the old pool made
exactly these four new cases fail, while the other 14 passed. A separate old-code
browser control failed exactly the three opaque-ID/current-admin-form assertions
that pass with the session fix.

The original 120-second POSIX suite watchdog expired during the first Linux run
with the validation SDK and enabled Chromium cases. A subsequent complete run
passed under the configurable 300-second budget; per-operation deadlines and
test assertions were unchanged.

One initial M1 run also had a transient `OperationError` in the unchanged
100-millisecond fake-browser timeout case. It did not recur in a focused rerun,
ten diagnostic repetitions, or later complete runs. Its original cause was not
established, and neither the fixture nor browser cleanup behavior was changed.
