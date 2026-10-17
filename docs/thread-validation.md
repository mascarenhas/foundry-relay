# Threaded relay validation

Validated on 2026-10-17. Native application and test inputs are commit
`ce01300e68ed89e2dc73ee29b7f709ead37dcbc3`; subsequent delivery changes update
documentation only. All 59 authored files were checked against that commit in
each platform's isolated build source. The 39 Titan sources are identical
across platforms.

[TITAN_REVISION](../TITAN_REVISION) pins
`92ff87a0b68415f6be7c68078c813bd4f838b10b`, the portable connection-handoff
prerequisite in [Titan #249](https://github.com/mascarenhas/titan/pull/249),
stacked on [Titan #248](https://github.com/mascarenhas/titan/pull/248).
The skills pin at that producer revision is
`375651e77e3a6bfcaa8a64bc9588db69fb4ff356`. The final producer commit changes
only that pin relative to the compiled `f07fab4d` inputs.

## Complete consumer suites

| Platform | Profile and toolchain | Selected | Passed | Skipped | Failed |
| --- | --- | ---: | ---: | ---: | ---: |
| Linux x86_64 | Validation, GCC, system OpenSSL | 385 | 382 | 3 | 0 |
| Linux x86_64 | Production, GCC/LTO, system OpenSSL 3.5.9 | 385 | 382 | 3 | 0 |
| Local macOS 15.7.7 x86_64 VM | Validation, Apple Clang 17, system OpenSSL 3.6.5 | 385 | 382 | 3 | 0 |
| Local Windows 11 Pro AMD64 VM, NTFS | CLANG64/UCRT, LLVM 22.1.8 | 386 | 368 | 18 | 0 |

The POSIX runs build the application and all 17 test roots. The Windows run
builds the application and all 16 Windows core roots; the separate POSIX static
process/SIGTERM root is replaced by native PE and PowerShell application checks.
Conditional native subcases account for the different selected counts.

On Linux and macOS, two installed-Chromium cases require an explicitly
configured browser/profile capability, and one case requires Windows exclusive
file sharing. The Windows skips are 17 POSIX fake-child fixtures and one POSIX
permission-bit assertion. Windows installed-Edge cases ran. There are no
threading, reply-pool, or concurrent-Store skips.

The new coverage includes nine real network/threading cases, fourteen reply
pool cases, and six concurrent-Store cases. It verifies persistent workers,
per-request round robin including keep-alive requests, separate world threads,
worker failure, pending-call settlement, accepted-connection retirement, and
subscription cancellation before and after reply publication. Nineteen world
protocol cases cover request correlation, admission, reconnect quiescence,
subscription counts, and captured connection ownership. Four session HTTP cases
also verify that session identifiers remain strings and shutdown is idempotent.

Two cancellation regressions hold the real Store FIFO after a security
transition is admitted, then cancel its coordinator request. Both credential
mutation and captured-world retirement still complete. The tests fail against
the old Server. Ordinary Store operations retain their cancellation/rollback
behavior. Two writer regressions verify retirement before a quiescence ACK and
avoid self-join on writer-origin failure. Restoring the old quiescence body
fails the retirement assertion; all other protocol cases still pass. Graceful
reconnect Close 1000 and a usable replacement are covered by integration tests.

## Executable delivery and configuration

Both Linux profiles passed the relocated executable fixture, which runs without
compiler, SDK, or Titan module-path access. macOS repeated that fixture with
`sandbox-exec` denying reads of the complete SDK prefix for the runner and its
child. The macOS executable imports only libSystem and the selected system
OpenSSL libraries.

Windows passed regular and delay-import PE audits and ordinary PowerShell
relocation into a Unicode path. Its child PATH contained Windows system
directories; compiler and SDK settings were absent. Health, SQLite pairing,
authenticated client listing, and clean structured application logs passed.
The VM policy disallows script-file execution, so the authored check script's
body and parameters ran through ordinary PowerShell commands without changing
the policy.

Installed SDK inputs remained immutable. Full before/after manifests matched
for Linux validation (2,335 files and links), Linux production (1,510), macOS
(2,372), and Windows (2,771). Separate sources,
output roots, prefixes, and writable compiler caches prevented build overlap.

A Linux CLI smoke checked the actual `RELAY_API_CONCURRENCY` environment path.
An absent value produced one API worker; setting it to 3 added exactly two OS
threads. Both processes served health and exited cleanly on SIGTERM. Values
`0`, `-1`, `1.5`, and `workers` each failed configuration before creating the
database or opening the listener, with one sanitized failure event.

## Producer prerequisites

The original thread-library branch at `315ca927` passed complete local macOS
and Windows gates before relay implementation began. On Windows, both native
profiles passed 1,492 tests with 32 expected skips, and the mixed compiler and
integration suites passed 4,382 tests with 110 expected pending/skipped cases.
macOS passed 1,533 native tests with five platform skips and the complete
compiler/package gates. Hosted Linux PR248 jobs also passed, including
ASan/UBSan and coverage.

The handoff prerequisite passed complete native suites on Linux
(1,560 passed, one platform skip), macOS (1,556 passed, five platform skips), and
Windows (1,519 passed, 30 classified skips), plus metadata, build-inventory,
and source-free consumer checks. Windows demand-read tests exercise established
TLS and post-read connection movement on IOCP.
Hosted Linux CI also passed for the exact handoff head:
[run 39050671093](https://github.com/mascarenhas/titan/actions/runs/39050671093).

The nil-message iterator review finding was reproduced and fixed with native
regressions. Abandoned thread-result endpoint cleanup was already corrected in
the reviewed branch; its retain/discard paths and regressions were verified.

These consumer integration runs use real local HTTP/WebSocket connections and
fixture worlds. Earlier live Foundry checks are retained in
[validation](validation.md). The measured channel costs and their limits are
recorded with the [thread design](threading.md#channel-cost-measurements).
