# Production executable-line coverage

The coverage workflow uses Titan's native `--coverage` support and the existing
Titan test suite. It measures both the test runner's production imports and the
real relay executable launched by the process test, then combines their line
counts. Local collection does not use a live Foundry world or upload to Codecov.

## Tools and pin

[TITAN_REVISION](../TITAN_REVISION) selects the Titan source revision for this
workflow. Prepare a separate SDK from that checkout, including its pinned Lua
and skills submodules, following that revision's build instructions. The relay
targets consume the installed SDK without installing or modifying it. Retain
its source/submodule revisions, build profile, compiler hashes and provider
identities; the pin alone does not authenticate an arbitrary installed SDK.

This workflow targets Linux with GCC 14 or newer and matching `gcov`, Python 3.9
or newer, and gcovr 8.4. Use the same OpenSSL mode as the installed SDK. System
OpenSSL requires its development files and `pkg-config`, as for the ordinary
relay build. For example, install gcovr in a private environment:

```sh
python3 -m venv /tmp/foundry-coverage-tools
/tmp/foundry-coverage-tools/bin/pip install gcovr==8.4
```

Titan's basic annotated `.gcov` output needs neither Python nor gcovr. The
relay's combined report requires both because gcovr merges the two executables'
results. See Titan's `doc/language/native-coverage.md` at the selected revision
for the native API and backend contracts.

## Build, run and report

From the relay repository, with the prepared SDK on `PATH`:

```sh
export PATH=/path/to/titan-sdk/bin:$PATH
make coverage CC=/usr/bin/gcc COVERAGE_GCOV=/usr/bin/gcov \
  COVERAGE_GCOVR=/tmp/foundry-coverage-tools/bin/gcovr
```

Use `make coverage-build` to compile separately and `make coverage-run` to run
the existing binaries and report without recompiling. Supply the same SDK and
tool settings to both commands. `TITANC`, `TITAN_STDLIB`, `TITAN_JOBS` and
`OPENSSL_MODE` work as for ordinary builds; `TITAN_JOBS` defaults to two.

`COVERAGE_GCOV` and `COVERAGE_GCOVR` default to the absolute paths found for
`gcov` and `gcovr`. Use absolute paths when overriding them: the existing
executable test deliberately gives its relay child an unusable `PATH`.
`PYTHON` selects the Python interpreter for path normalization.

`COVERAGE_FORMATS` defaults to `html lcov cobertura` and controls the merged
report formats. For example, `COVERAGE_FORMATS=html` requests only HTML in
addition to the merged line JSON. Each executable still produces the native
line JSON needed for merging, so gcovr remains required.

The two covered executables and their sources are separate:

| Image | Staged sources | Executable |
| --- | --- | --- |
| Full native test runner | `build/coverage-src` | `build/coverage-src/tests/router_test` |
| Relay child | `build/coverage-app-src` | `build/coverage-app-src/main` |

Coverage-generated C, headers and objects live in `.coverage` subdirectories
inside those stages. Ordinary application and test outputs remain under
`build/app-src` and `build/test-src`; switching to an ordinary build requires no
coverage artifact swap. Keep the covered stages at their original absolute
paths while executing them, and serialize coverage runs that share those paths.

`coverage-run` always runs the complete suite, ignores `TEST_ARGS`, and clears
inherited `TITAN_FILTER`, `GCOV_PREFIX` and `GCOV_PREFIX_STRIP`. It removes old
reports before execution. Each covered executable resets its own counters,
retains its notes, and dumps and reports after successful execution and cleanup.
The process test launches the covered relay child, exercises startup and
shutdown, waits for it to exit and joins its output reader. The test runner and
child therefore collect in separate counter paths during one full suite run.
A failed test run stops the target before merging. The summary check also
rejects empty selection, missing public cases, and skipped tests.

Each image's native report is under its stage's `.coverage/report`. The small
`scripts/coverage.py` helper checks the staged production sources against the
project originals, requires complete matching executable-line inventories,
and maps the two line reports back to project paths. gcovr then merges those
reports into `build/coverage-report`:

- `lines.json`: combined executable lines and counts;
- `coverage.html`: HTML with source detail;
- `coverage.info`: LCOV;
- `coverage.xml`: Cobertura.

The last three files follow `COVERAGE_FORMATS`. Retain both covered stages,
native reports and counters alongside the merged report for review.

## Scope

Both images measure this complete production inventory:

```text
main
relay.api
relay.config
relay.hub
relay.router
relay.server
relay.store
relay.wire
```

Titan automatically selects source imports without top-level `test_`
functions. The full runner requests all six existing test owners and `main` as
an additional source root. The first requested root remains `tests.router_test`,
which owns the test executable's name. Including `main` retains its executable
lines even though the test runner does not call the application's entry point;
the real child supplies its standalone execution hits.

The final report excludes test owners, synthetic support, SDK modules, compiler,
Lua and native dependencies. Selection follows the source graph rather than
scanning the repository. The normalization step checks the complete production
inventory against `main.titan` and the relay sources, so a missing production
module or zero-hit file cannot silently shrink the report. Merging sums counts
by original source line and includes each executable line once in the total.

## Result and limits

The native collection run on Linux x86_64 passed **235/235 cases** across all
six test owners and measured **1,140 of 1,209 executable lines (94.29%)**. The
combined total and every per-file count exactly match the previous collector's
baseline. All 69 zero-count lines remain; the real relay child contributes the
15 covered lines in `main` and 29 otherwise uncovered configuration lines.

A second direct run passed all 235 cases with the same executable-line
inventory and covered lines; counter reset prevented counts from accumulating.
An ordinary production-profile build then passed all 235 cases without removing
the instrumented outputs. All installed SDK files and application/test Titan
sources remained unchanged.

| Production source | Covered / executable lines | Coverage |
| --- | ---: | ---: |
| `main.titan` | 15 / 19 | 78.95% |
| `relay/api.titan` | 359 / 371 | 96.77% |
| `relay/config.titan` | 37 / 40 | 92.50% |
| `relay/hub.titan` | 199 / 205 | 97.07% |
| `relay/router.titan` | 182 / 183 | 99.45% |
| `relay/server.titan` | 179 / 219 | 81.74% |
| `relay/store.titan` | 155 / 158 | 98.10% |
| `relay/wire.titan` | 14 / 14 | 100.00% |

This run used Titan `0bcdaeb8` and skills pin `69f59635`. The
[baseline snapshot](coverage-baseline.json) records the exact revisions,
source hashes, tools and evidence. Individual native reports may include
source-owned SDK test support; the combined report removes that support and
retains exactly the eight production files above.

The local HTML preview and validation evidence are retained under
`build/coverage-report-0bcdaeb8`, including individual reports, counters, logs
and SDK provenance. The disposable SDK and build trees used for validation
were removed afterward; another run requires rebuilding the covered images.

The previous collector's snapshot remains in local Git history at
`c2b94a6:docs/coverage-baseline.json`. It used Titan `8609cfb` and a different
collection API; it is retained as the comparison reference rather than the
current collection instructions.

Coverage describes executable source lines under instrumented O0/no-LTO
builds. It does not measure branches, expressions or behavior completeness and
does not replace ordinary optimized or platform validation. This application
workflow has Linux validation only; it makes no Windows or macOS coverage
claim. Local socket tests use loopback ports and private temporary files, so
simultaneous relay test suites can still compete for a port.
