# Appendix B: Executable Line Coverage

Executable-line coverage for `foundry-relay` builds directly on Titan's native
`--coverage` compiler mode and the existing `titan.test` suite. Each
instrumented binary prints a Titan executable-line summary and writes its own
annotated `.gcov` report without Python, `gcovr`, or relay-specific
post-processing scripts.

## Tools

Use the prepared Titan SDK selected for
[Build and test](../README.md#build-and-test) and
[Appendix A: POSIX build](build-and-testing.md#posix-build); it must support
native `--coverage`.

On Linux, install GCC 14 or newer and the matching `gcov` binary. Match
`OPENSSL_MODE` to the installed SDK (system OpenSSL requires OpenSSL 3.0+
development headers and `pkg-config`). `make coverage-run` enforces the same
`TEST_TIMEOUT` budget and requires the same `timeout` command on `PATH` as
`make test`.

## Build and run

From the repository root, with the prepared SDK on `PATH`:

```sh
export PATH=/path/to/titan-sdk/bin:$PATH
make coverage CC=/usr/bin/gcc COVERAGE_GCOV=/usr/bin/gcov
```

[`Makefile`](../Makefile) splits coverage into two targets:

- `make coverage-build` removes and recompiles `build/coverage-app` and
  `build/coverage-tests` cleanly without `--incremental`, unsetting inherited
  `GCOV_PREFIX` and `GCOV_PREFIX_STRIP`.
- `make coverage-run` runs the compiled coverage binaries and their native
  reporters without recompiling, clearing inherited `TITAN_FILTER`,
  `GCOV_PREFIX`, and `GCOV_PREFIX_STRIP` and ignoring `TEST_ARGS`.

Keep authored sources unchanged and tool variables identical between separate
`coverage-build` and `coverage-run` invocations. `TITANC`, `TITAN_STDLIB`,
`TITAN_JOBS`, and `OPENSSL_MODE` behave identically to
[POSIX build](build-and-testing.md#posix-build). `COVERAGE_GCOV` defaults to
`command -v gcov`; always pass an absolute path when overriding it, because
`test_relocated_executable_runs_without_compiler_or_provider` in
[`tests/process_test.titan`](../tests/process_test.titan) launches the relay
child with `PATH=/nonexistent-foundry-relay-tools`.

Each covered image compiles into its own `--output` tree:

| Image | Executable | Native report |
| --- | --- | --- |
| Full native test runner | `build/coverage-tests/tests/router_test` | `build/coverage-tests/.coverage/report/coverage.gcov` |
| Relay child | `build/coverage-app/main` | `build/coverage-app/.coverage/report/coverage.gcov` |

Instrumented C, headers, objects, `.gcno` notes, and `.gcda` counters live in
`.coverage` subdirectories inside each tree, leaving ordinary uninstrumented
objects under `build/` untouched. Separate output trees are mandatory because
both executables run concurrently during `make coverage-run`: each binary
resets its own `.gcda` counters on startup and dumps them at exit through
Titan's embedded reporter. Sharing one `--output` directory would let the
spawned child overwrite the test runner's live counters.

During `coverage-run`, Make sets `RELAY_TEST_EXECUTABLE` to
`$(ROOT)/build/coverage-app/main` and `RELAY_TEST_COVERAGE_REPORT` to
`$(ROOT)/build/coverage-app/.coverage/report`.
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
SDK and native dependencies. Both covered images include all 22 production
modules in their source graph.

The coverage test link passes `main` as an explicit source root alongside
`--test --tree . --test-dir tests`: even though the test runner never invokes
`main` in [`main.titan`](../main.titan), naming `main` keeps its executable
lines visible with zero hits in the runner's denominator instead of silently
omitting the entrypoint from the report.

The runner report measures production code exercised across the native suite,
while the child report measures standalone process startup and signal shutdown
in [`main.titan`](../main.titan) and the server runtime. Both reports retain
unexecuted lines mapped back to the original `.titan` source files.

See Titan's `doc/language/toolchain.md#native-source-coverage` at the selected
SDK revision for coverage backend selection (`gcc-gcov` and `llvm-gcov`),
`--coverage-module` filters, and optional `gcovr` report formats (`html`,
`lcov`, `cobertura`).

---

← Previous: [Appendix A: Native Builds, Windows Packaging, Testing, and Retired Records](build-and-testing.md) | [Table of Contents](index.md)
