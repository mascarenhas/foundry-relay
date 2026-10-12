# Logging validation

Validated implementation: commit `2e26b4c240cfe62a72c649d819da5f03211ba8df`,
stacked on the session API. The same executable includes headless sessions;
the obsolete spike executable, fixture parser and build target were removed.

## Linux x86_64

The full native Titan suite ran 336 cases: **335 passed, one Windows-only
exclusive-file fixture skipped**. This includes actual installed Chrome normal
close and aborted-CDP recovery, plus the relocated executable without a compiler
or provider on its runtime search path.

Logging checks cover default/error/info/debug filtering, malformed levels, JSON
escaping, nonyielding bounded admission, slow/failed sinks, dropped-record
reporting and cancellation-insensitive drain. Real HTTP/WebSocket tests cover
13 request admissions including rejected, malformed, unmatched, OPTIONS and
PROPFIND requests; pairing and disconnect lifecycle; forwarding/results;
subscriptions; timeouts; malformed module messages; live SSE admission; and
credential/payload/Close-reason redaction. Both empty and code-1000 peer Close
during heartbeat are covered. These heartbeat cases also passed the earlier
snapshot and are not evidence of a failing negative control.

A live-WebSocket SIGTERM check exposed a missing disconnect record before the
owner fix. Disconnect logging now occurs in the idempotent logical-offline
transition before transport retirement yields; the executable regression keeps
its world connected during SIGTERM and verifies exactly one disconnect record.
Separate startup checks verified error JSON and exit status 1 for missing
configuration and an invalid log level, without echoing that invalid value.

The prepared SDK reports `production`; application/test compilation used
`-O0 -fno-lto`. No Titan compiler or standard-library source changed in this
update. Exact SHA-256 values:

| Artifact | SHA-256 |
| --- | --- |
| Installed `titanc` | `77868b858e8459eccf4a0155fd06216732170516a889fdeb0402c42bdc9b6da0` |
| Installed `titan.so` | `3b6b0af63625a6f5d39665b60293874be4cc297991dc92b7e83b085b067947b7` |
| Installed `titan.a` | `5b215b1a45259b9ef99af2894efd53509669f43531e8bae2999e43b6b68cdeec` |
| Relay executable | `12e67a75adb85f54eb9624bc1f1f0372a2719dc48c0ab08856274b5a70524245` |
| Native test executable | `d9eccc5a7820f125eed37ec5bf7e37bdb979fb1a36f2da6a7342c0759392b9ad` |

## Windows 11 x64

The final allowlisted source snapshot compiled the application DLL/EXE and
13-root native test executable. The suite ran 335 cases: **317 passed, 18
expected POSIX skips**, including the logging, crypto, session/API and
exclusive-file-sharing regressions. Both installed Edge lifecycle tests passed;
afterward no Edge process or owned browser profile remained.

All 18 application/test PE images passed direct x64 and regular/delayed-import
closure checks, without toolchain runtime DLLs entering delivery. From a Unicode
NTFS relocation with only Windows system directories on `PATH`, the relay passed
health, SQLite pairing and authenticated clients checks. Its smoke test parsed
five JSON info records, including three request admissions, without synthetic
API keys, pairing codes or tokens.

The guest's existing PowerShell execution policy blocked running
`scripts/check-windows.ps1` as a file. The checks above ran through direct
ordinary commands and native process pipe capture; they do not claim execution
of that script. The execution policy and browser security settings were left
unchanged. The prepared SDK was reused rather than rebuilt.

The non-administrator run used Edge `154.0.4258.53`, Clang `22.1.8`, Make `4.4.1`
and application/test `-O0`. All 31 allowlisted guest source files matched the
final implementation, including both staged Hub copies. Owned relay, test and
Edge process counts were zero at cleanup; temporary relocation and smoke
directories were removed. Exact SHA-256 values:

| Artifact | SHA-256 |
| --- | --- |
| Final source archive | `bdb828da6aef261fdcf1606bcb5677f5191e8dc436d94a2f96e410222c7697e0` |
| Reused `titan.dll` | `f56df0c4e5a4734c7c4e459a8481e2a3fab2dedb3ea36e47a9d4dd97920bcbb1` |
| Relay EXE | `51dfe6855320ca48d6695961320fecc3c7c6b55fa2c9e0b5e397186349ff7135` |
| Application `main.dll` | `356f9a01c97cfb5e12784e1d63b9bf6e3e02a1b2607f968a6d94d4c8af83e12f` |
| Native test log | `356677604479a5732732641c387157616d6622d1f628e9811cdb419886908bed` |
| Final local evidence record | `5195fc2dbe7416a9ab509f3e9422cabb941555d9aeac8cc1ba4c7b256f76875d` |

## Independent review

The logger and its tests received reviews independent of their author. Separate
reviews covered request/connection integration, the new integration tests,
headless cleanup and origin validation, spike removal, and documentation.
Findings about graceful Close classification, disconnect logging at shutdown,
JSON size wording, and underlying runtime/stream boundaries were resolved.
See [logging configuration and limits](../README.md#logs).
