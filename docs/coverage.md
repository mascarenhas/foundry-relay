# Production executable-line coverage

The coverage workflow measures the relay's production Titan sources with
Titan's `titan-coverage` build/seal/run/report pipeline. It runs the existing
native Titan tests; it does not use a live Foundry world or upload to Codecov.

## Tools and pin

[TITAN_REVISION](../TITAN_REVISION) selects the Titan source revision used for
this workflow. Prepare a separate SDK from that checkout, including its pinned
Lua and skills submodules. Follow that revision's own build instructions, and
keep its source tree and SDK separate from another Titan development checkout.
The helper consumes an installed SDK and does not install or modify it.

This helper currently targets Linux with system OpenSSL, GCC 14 or newer,
matching `gcov`, Python 3.9 or newer, and gcovr 8.4. OpenSSL development files and
`pkg-config` are required, as for the ordinary relay build. Install gcovr in a
private environment:

```sh
python3 -m venv /tmp/foundry-coverage-tools
/tmp/foundry-coverage-tools/bin/pip install gcovr==8.4
```

From the relay repository, run:

```sh
python3 scripts/coverage.py \
  --titan-source /path/to/clean/pinned-titan-checkout \
  --sdk /path/to/separate/titan-sdk \
  --output /tmp/foundry-coverage-run-1 \
  --cc /usr/bin/gcc --gcov /usr/bin/gcov \
  --gcovr /tmp/foundry-coverage-tools/bin/gcovr
```

The output directory must be new and outside the application, SDK, and Titan
source trees. Use a different directory for every attempt, including retries
after a failure. The helper provides separate temporary, cache, preparation
counter, image, and run directories. It clears inherited test filters,
profiling settings, and relay configuration before invoking the real tests.
`--jobs` defaults to two generated-C workers, and `--timeout` to 120 seconds per
capture. Run `--help` for the remaining options.

The source checkout must match `TITAN_REVISION`, and its coverage host script
must match the installed one. These checks do not authenticate the entire SDK
as a build of that revision. Retain its preparation provenance as well:
source/submodule revisions, build profile and inputs, installed compiler file
hashes, and provider identities. The sealed manifests bind the actual executed
compiler, toolchain, SDK inputs, and images used by the measurement.

## Scope and collection

Both measured images explicitly select the same complete production inventory:

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

All six native test owners run in the full capture: router, store, API,
protocol, integration, and process tests. Test owners, synthetic test support,
the SDK, compiler, Lua, and native dependencies are unmeasured. Source-private
imports of a production module remain in the production inventory. Uncalled
functions and zero-count executable lines remain in the denominator.

The process test copies and launches the actual relay executable, requests
SIGTERM, waits for its exit, and joins its output reader. The workflow therefore
needs two measured images and two separate captures:

| Capture | Test executable | Relay child | Purpose |
| --- | --- | --- | --- |
| A | Measured, all six roots | Uninstrumented | Unit and integration coverage, plus the full native suite |
| B | Uninstrumented, existing process test only | Measured | Real executable startup, configuration, and shutdown |

The ordinary images are built from separate private source copies using the
project Makefile. The measured images use source mappings back to the original
tracked files. All inputs and ordinary consumer executables are hashed before
collection and sealed as unmeasured inputs where appropriate.

Each capture uses its own sealed version-1 build manifest and fresh version-2
run receipt. `titan-coverage run` owns a private process group; acceptance requires
normal completion, confirmed group emptiness, expected counters, and passing
nonempty test selection. Build/probe counters stay in separate preparation
directories. Mixing two differently instrumented images into one capture would
produce counters outside that manifest's inventory and is rejected.

Reporting explicitly supplies both manifests and both runs. Titan verifies
compatible source/tool/platform provenance and merges counts by original source
line, retaining zero hits and counting each executable line once. The helper
refuses incomplete reports and checks that exactly the eight production files
are present. It does not use `--allow-incomplete` or impose a percentage target.

## Results and limits

The October 9, 2026 Linux x86_64 baseline covers **1,140 of 1,209 executable
lines (94.29%)**. The full capture passed 235/235 cases, including all six test
owners and 81 public cases; the separate process capture passed 1/1. Both
version-2 receipts completed with exit zero, empty process groups, and eight
expected counter files. The source tree and recorded SDK inputs were unchanged.

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

All 69 zero-count lines remain. The largest group is in `relay.server`: selected
HTTP authentication/error responses, Origin/CORS handling, unpair/client deletion,
SSE keepalive/failure paths, and binary upload adaptation. `main` retains its
unexecuted SIGINT and failure-reporting lines. Capture A retained all 19 `main`
lines at zero before capture B supplied its executable hits.

The baseline used Titan `8609cfb`, its fetched skills pin `df1e7837`, GCC/gcov
16.2.1, gcovr 8.4, system OpenSSL 3.5.9, and a separate validation-profile SDK.
An independent artifact review recomputed the merged lines from retained raw
gcov data and checked LCOV/Cobertura, sealed inputs, exclusions, selection, and
counter ownership. [The baseline snapshot](coverage-baseline.json) records exact
revisions, source hashes, run identities, tool versions, and evidence digests.
The local HTML preview is `build/coverage-report-8609cfb/coverage.html`; the
snapshot also identifies the original private output and SDK preparation receipt.

The output includes `result.json`, input configuration, command and test logs,
selection audits, both build manifests, both run receipts, and raw counters.
`report/` contains `coverage.html`, `coverage.info`, `coverage.xml`, `lines.json`,
`summary.json`, and raw reader evidence. Retain the complete output directory;
moving or changing sealed sources, SDK inputs, images, or counters can invalidate
later reporting.

Coverage describes executable source lines under the instrumented O0/no-LTO
build. It does not measure branch, expression, or behavior coverage, and it does
not replace ordinary optimized or platform validation. The selected Titan pin
does not support Windows coverage; no Windows or macOS coverage is implied by
the Linux result. Local socket tests use private temporary files and loopback
ports, so simultaneous relay test suites can still compete for a port.
