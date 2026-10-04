# Validation record

Validated on 2026-10-04 against Titan's WebSocket implementation plus the HTTP
response-abort change, represented by `codex/foundry-relay-build-docs` at
`4987078d`. The isolated SDK rebuilds used the same compiler/runtime inputs as
`cdf8f330777a608f1aeeaea87ebe17632bd70922`, with the two changed HTTP source
files; source receipts record their exact hashes. The follow-up from
`dc3f3e99` to `4987078d` only refreshes the pinned public metadata fixture;
compiled inputs and delivered artifacts are unchanged. Its focused metadata
check passed across all 22 standard providers.

## Linux x86_64

The application used Titan's default optimized static build. The native test
translation units used `TITAN_EXTRA_CFLAGS=-O0`; the installed standard provider
remained optimized. The complete native relay suite passed **224 tests with no
skips**. The native Titan HTTP root also passed **142 checks**, including five
new abort/header cases, verified TLS cancellation, and the child-process
SSL/HTTP composition fixture.

The executable was copied outside its build and SDK directories. Its child
environment made the compiler, Titan provider, and Lua module paths unavailable.
HTTP health, SQLite-backed pairing, uppercase pairing-code normalization, SSE
disconnect cleanup with empty stderr, and a clean SIGTERM exit passed. The SSE
regression failed against the old executable with the observed uncaught
"HTTP response headers have already been sent" error and passed with the final
executable. ELF imports contain only the operating-system
`libm`, `libgcc_s`, and `libc` dependencies.

Executable SHA256:
`64e8a46103a6e2c82c65fc3c5deea9ac21e2edeb302ee31ce0dbd9afa922ce27`.
Optimized standard archive SHA256:
`2f81fc005a4bbac5109e62104e241ce3a435679c589250f2bdfe1d4b97429ee8`.
The complete native output is retained in `build/linux-test.log` and
`build/http-abort-native-final.log`; the expected pre-fix failure is in
`build/http-abort-before-regression.log`.

## Local Windows VM

Native Windows 11 x64 testing used the local `titan-win11pro` VM and private
NTFS source, SDK, and output copies. The application compiled to one launcher
EXE and one application DLL, with Titan's standard provider and six adjacent
runtime DLL dependencies. No existing SDK or protected installation was changed.
Application translation units used `-O2`; the standard provider used `-O3`.

The five common Titan test roots selected **223 cases: 222 passed and one
skipped**. Only the separate POSIX permission-bit assertion was skipped;
credential persistence and all HTTP/WebSocket integration cases ran. The Unix
static-executable/SIGTERM fixture is separate from Windows validation.

All **18 x64 PE images** across the application and test payloads passed the
regular/delay-import audit. No MSYS2 or LLVM runtime dependency was required.
The application also passed health, pairing, and authenticated client-list
checks after relocation to a Unicode path, from another working directory,
with only Windows system directories on PATH and no SDK/compiler module-path
settings. Its stderr was empty.

The optimized Windows standard provider SHA256 was
`f56df0c4e5a4734c7c4e459a8481e2a3fab2dedb3ea36e47a9d4dd97920bcbb1`.
Application ZIP SHA256:
`d59fd9e2d04288d22b34374a18278c2896151459576b909ffa6f2712253818c6`.
All 174 recorded compiler/runtime/standard-library source files matched the
current Titan source authority; all 13 compiled relay/test source files also
matched the shared project. The POSIX-only process fixture is excluded from
that Windows compilation.

The VM's unchanged PowerShell policy blocks script-file execution. Validation
used permitted ordinary PowerShell commands over the pinned SSH connection.
`Makefile.windows test` requires a policy that permits its `-File` invocation.
Payloads, commands, logs, hashes, and source receipts are retained under
`build/windows-validated/` and `build/windows-http-abort-validation/`.
Native tests intentionally emit generic "Foundry WebSocket session ended"
lines while testing failed sessions; they are checked separately from the
standalone application's empty stderr.

## Coverage and review

The Titan suite covers the PEG route parser and labeled diagnostics, all 91
forwarding declarations, coercion and binary responses, JSON null preservation,
SQLite identity and persistence, and cancellation of database waiters.

Integration cases use real loopback HTTP and WebSocket connections with test
worlds. They exercise multiple-world selection, wrong-token rejection,
out-of-order replies, timeout and late-reply handling, disconnect settlement,
fragmented Unicode JSON, Ping/Pong, SSE, normal replacement closure, a stalled
incumbent's bounded retirement, complete event-channel snapshots, subscriber
overflow, and cancellation before queued mutation admission.

Independent reviewers checked the implementation, API mappings, documentation,
and Windows packaging. The queued-mutation cancellation regression was also
verified to fail with the old cleanup order and pass with the final code.

## Live Foundry validation

The user paired the running world manually while automated browser control was
unavailable. Live relay API checks ran against Foundry **14.368**, REST
API module **3.4.1**, and the `dark-sun` world using the `wwn` system. The module's
source map also informed the protocol adapter.

Live checks passed REST authentication, explicit world selection, a deterministic
roll without creating a chat message, JournalEntry CRUD, a **90,112-byte UTF-8**
property with nested and trailing JSON nulls, **16 distinct concurrent request
correlations**, and real Scene create/update/delete hook events over SSE. Relay
restart preserved the client identity and the module reconnected automatically.

Only uniquely marked scratch documents were mutated. Both were deleted, and
direct `/get` requests confirmed "Entity not found" with null data:

- `JournalEntry.79DXYPYwEWnOsbxB`
- `Scene.Ber3E9T6BTDtYKzO`

The scratch Scene was created inactive. The final executable also reconnected,
rechecked both documents' absence, accepted an SSE connection that the client
closed, and answered a subsequent world-info request after 35 seconds of stream
keepalive activity. Its stderr was empty after shutdown.

The sanitized live receipt and ephemeral API driver are retained in the ignored
`build/live-foundry/` directory. This driver is validation tooling; the project's
test suite and runner are Titan. The user confirmed that the local world is for
testing and authorized stopping without restoring its module settings. The
temporary Foundry and relay processes were stopped, and the temporary API-key
file and SQLite credentials database were removed.

A subsequent live UI pass used Computer Use in Chrome against the same local
test world. The module paired through **Enter Code** with the reusable code,
then connected after reloading. A REST-created JournalEntry appeared in the
Journal sidebar with an embedded Unicode HTML text page. Updating its title
and its page by UUID through REST changed the already-open journal window,
including the rendered Unicode body, without reopening it.

An inactive, non-navigation scratch Scene appeared in the Scenes sidebar. Its
name was edited and saved in Foundry's configuration UI while a pre-established
`/hooks/subscribe` stream listened. The received `updateScene` matched the exact
Scene ID, scratch nonce, and saved name; REST readback agreed and still showed
`active: false` and `navigation: false`. The active Scene remained
`Seedhouse` (`Y21NIRCmWfGc7sYN`) in the before/after world-info snapshots.

Each scratch root document was deleted separately through REST. Foundry removed
the Scene and Journal from filtered sidebar lists and closed the open journal
window. Direct `/get` requests confirmed absence of both root documents and the
embedded page:

- `JournalEntry.R2RUQiRYFia6B2xR`
- `JournalEntry.R2RUQiRYFia6B2xR.JournalEntryPage.ysr9YQSD4O2UpWbo`
- `Scene.AHRIvlxDp7SfVBhW`

The UI receipt, SSE event, screenshots, accessibility readbacks, and ephemeral
validation driver are retained under ignored `build/live-foundry-ui/`. The
plan and driver were independently reviewed. The temporary browser tab and
Foundry/relay processes were closed, both local ports were checked closed, and
the temporary API-key file and SQLite credentials database were removed. Relay
stderr was empty.

Failed committed HTTP streams are now aborted. The README's remaining shutdown
limitation is that the relay does not track and abort every accepted HTTP
exchange when stopping; a permanently stalled body/output operation can still
prevent bounded shutdown.
