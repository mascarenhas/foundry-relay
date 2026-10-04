# Validation record

Validated on 2026-10-04 against Titan's WebSocket branch at
`cdf8f330777a608f1aeeaea87ebe17632bd70922`.

## Linux x86_64

The application used Titan's default optimized static build. The native test
translation units used `TITAN_EXTRA_CFLAGS=-O0`; the installed standard provider
remained optimized. `make test` passed **223 tests with no skips**.

The executable was copied outside its build and SDK directories. Its child
environment made the compiler, Titan provider, and Lua module paths unavailable.
HTTP health, SQLite-backed pairing, uppercase pairing-code normalization, and a
clean SIGTERM exit passed. ELF imports contain only the operating-system
`libm`, `libgcc_s`, and `libc` dependencies.

Executable SHA256:
`e43906cc3dd9c982a62d1e8638d451253535f603bb1a4814b4b97b3785c7b0a0`.
The complete native output is retained in `build/linux-test.log`.

## Local Windows VM

Native Windows 11 x64 testing used the local `titan-win11pro` VM and private
NTFS source, SDK, and output copies. The application compiled to one launcher
EXE and one application DLL, with Titan's standard provider and six adjacent
runtime DLL dependencies. No existing SDK or protected installation was changed.
Application translation units used `-O2`; the standard provider used `-O3`.

The five common Titan test roots selected **222 cases: 221 passed and one
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
`6fca75ec21e4998bc92bd4d8aa0811aae992c1340aae79d52e2bfd2f89aaed66`.
All 174 recorded compiler/runtime/standard-library source files matched the
current Titan source authority; the final 14 relay/test source files also
matched the shared project.

The VM's unchanged PowerShell policy blocks script-file execution. Validation
used permitted ordinary PowerShell commands over the pinned SSH connection.
`Makefile.windows test` requires a policy that permits its `-File` invocation.
Payloads, commands, logs, hashes, and source receipts are retained under
`build/windows-validated/`.

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

## Live Foundry boundary

The locally installed Foundry module's source map informed the protocol adapter.
The supplied Foundry instance started successfully, but the browser tool's
administrative-policy check prevented UI access and pairing. No live REST
mutation was performed. Actual Foundry-world end-to-end validation remains
unverified; the temporary Foundry and relay test processes were stopped.

The HTTP shutdown limitation described in the README remains: there is no
public request/response transport-abort operation for permanently stalled body
reads or response writes.
