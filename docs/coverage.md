# Appendix B: Executable Line Coverage

Executable-line coverage for `foundry-relay` builds directly on Titan's native
`--coverage` compiler mode and the existing `titan.test` suite. Each
instrumented binary prints a Titan executable-line summary and writes its own
annotated `.gcov` report without Python, `gcovr`, or relay-specific
post-processing scripts.

## Tools

Use the prepared Titan SDK and installed `titan-mk` rock selected for
[Build, install, and test](../README.md#build-install-and-test) and
[Appendix A: POSIX build](build-and-testing.md#posix-build); the SDK must
support native `--coverage`. Coverage mode is supported on Linux and macOS.

On Linux, install GCC 14 or newer and the matching `gcov` binary (or Clang with
`llvm-cov gcov`). Match `OPENSSL_MODE` to the installed SDK (system OpenSSL
requires OpenSSL 3.0+ development headers and `pkg-config`).

## Build and run

From the repository root, with the prepared SDK on `PATH`:

```sh
export PATH=/path/to/titan-sdk/bin:$PATH
luarocks test foundry-relay-0.1.0-1.rockspec -- --coverage
```

[`scripts/rock-test.lua`](../scripts/rock-test.lua) handles `--coverage` by
removing and cleanly rebuilding `build/coverage-app` and `build/coverage-tests`
without `--incremental`, unsetting inherited `TITAN_FILTER`, `GCOV_PREFIX`, and
`GCOV_PREFIX_STRIP`, and running the instrumented test runner (forwarding any
extra arguments placed after `--coverage`).

`OPENSSL_MODE` behaves identically to
[POSIX build](build-and-testing.md#posix-build). To select the `gcov` backend,
set `COVERAGE_GCOV` (checked first) or `GCOV` (default `gcov`).
`scripts/rock-test.lua` resolves the leading program name to an absolute path
(while keeping trailing arguments such as `llvm-cov gcov`'s `gcov` intact) so
`test_relocated_executable_runs_without_compiler_or_provider` in
[`tests/process_test.titan`](../tests/process_test.titan) can emit its coverage
report even though it launches the relay child with
`PATH=/nonexistent-foundry-relay-tools`.

Each covered image compiles into its own `--output` tree:

| Image | Executable | Native report |
| --- | --- | --- |
| Full native test runner | `build/coverage-tests/relay-tests` | `build/coverage-tests/.coverage/report/coverage.gcov` |
| Relay child | `build/coverage-app/foundry-relay` | `build/coverage-app/.coverage/report/coverage.gcov` |

Instrumented C, headers, objects, `.gcno` notes, and `.gcda` counters live in
`.coverage` subdirectories inside each tree, leaving ordinary uninstrumented
objects under `build/` untouched. Separate output trees are mandatory because
both executables run concurrently during the test run: each binary resets its
own `.gcda` counters on startup and dumps them at exit through Titan's embedded
reporter. Sharing one `--output` directory would let the spawned child
overwrite the test runner's live counters.

During a `--coverage` run, [`scripts/rock-test.lua`](../scripts/rock-test.lua)
sets `RELAY_TEST_EXECUTABLE=build/coverage-app/foundry-relay` and
`RELAY_TEST_COVERAGE_REPORT=<root>/build/coverage-app/.coverage/report`.
[`tests/process_test.titan`](../tests/process_test.titan) launches the covered
relay child, exercises live pairing, WebSocket, and SSE traffic, shuts it down
with `SIGTERM`, verifies both the child's executable-line summary and report
path on `stdout` (`assert_stdout`), and joins the child before the runner exits
and emits its own summary. Test failures preserve their normal non-zero exit
status.

Repeated runs reset `.gcda` counters while keeping `.gcno` notes. Leave
coverage outputs at their original absolute build paths while executing them,
and serialize runs that target the same counter tree. Local cases use loopback
fixtures and private temporary files without requiring a live Foundry world.

## Source selection and reports

Titan automatically instruments every production module imported from source,
excluding modules that declare top-level `test_` functions as well as prebuilt
SDK and installed provider dependencies (`titan`, `titan-mk`). Both covered
images include all 20 relay production modules in their source graph.

The coverage test link passes `foundry_relay` as an explicit source root
alongside `--test --tree . --test-dir tests`: even though the test runner never
invokes `main` in [`foundry_relay.titan`](../foundry_relay.titan), naming
`foundry_relay` keeps its executable lines visible with zero hits in the
runner's denominator instead of silently omitting the entrypoint from the
report.

The runner report measures production code exercised across the native suite,
while the child report measures standalone process startup and signal shutdown
in [`foundry_relay.titan`](../foundry_relay.titan) and the server runtime. Both
reports retain unexecuted lines mapped back to the original `.titan` source
files.

See Titan's `doc/language/toolchain.md#native-source-coverage` at the selected
SDK revision for coverage backend selection (`gcc-gcov` and `llvm-gcov`),
`--coverage-module` filters, and optional `gcovr` report formats (`html`,
`lcov`, `cobertura`).

---

← Previous: [Appendix A: Native Builds, Windows Packaging, Testing, and Retired Records](build-and-testing.md) | [Table of Contents](index.md)
