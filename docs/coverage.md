# Native production source coverage

The relay uses Titan's native `--coverage` support and the existing test suite.
Each executable prints a Titan executable-line summary and writes its annotated
report directly. The workflow requires a matching C coverage toolchain; it has
no Python, gcovr, or relay-specific report-processing dependency.

## Tools

Use the Titan SDK selected for the [ordinary build](../README.md#build-and-test);
it must support native `--coverage`.

On Linux, use GCC 14 or newer and the matching `gcov`. Use the same OpenSSL mode
as the installed SDK. System OpenSSL needs its development files and
`pkg-config`, as for the ordinary build. `make coverage-run` uses the
`TEST_TIMEOUT` execution budget and the same `timeout` command as `make test`.

## Build and run

From the relay repository, with the prepared SDK on `PATH`:

```sh
export PATH=/path/to/titan-sdk/bin:$PATH
make coverage CC=/usr/bin/gcc COVERAGE_GCOV=/usr/bin/gcov
```

`make coverage-build` removes and recompiles both coverage trees; it does not
reuse incremental objects. `make coverage-run` runs the existing binaries and
their native reporters without recompiling. Keep authored sources unchanged
between those commands, and supply the same SDK and tool settings. `TITANC`,
`TITAN_STDLIB`, `TITAN_JOBS`, and `OPENSSL_MODE` work as for ordinary builds.

`COVERAGE_GCOV` defaults to the absolute path found for `gcov`. Use an absolute
path when overriding it: the executable test deliberately gives its relay child
an unusable `PATH`.

Both executables compile authored sources directly using `--output`:

| Image | Executable | Native report |
| --- | --- | --- |
| Full native test runner | `build/coverage-tests/tests/router_test` | `build/coverage-tests/.coverage/report/coverage.gcov` |
| Relay child | `build/coverage-app/main` | `build/coverage-app/.coverage/report/coverage.gcov` |

Instrumented production C, headers, objects, and counters live in `.coverage` subdirectories
inside those output trees. The two covered images use separate counter paths
because each resets and dumps its own counters. Ordinary application and test
links continue to share uninstrumented objects under `build`.

`coverage-run` runs the full suite, ignores `TEST_ARGS`, and clears inherited
`TITAN_FILTER`, `GCOV_PREFIX`, and `GCOV_PREFIX_STRIP`. `tests/process_test.titan`
launches the covered relay child through `RELAY_TEST_EXECUTABLE`, exercises
startup and shutdown, checks the child's coverage summary and report path, and
joins it before the runner finishes. Each executable then collects and reports
through Titan's embedded reporter. Test failures retain their normal failing
exit status.

Repeated executions reset counters while retaining the `.gcno` notes. Keep the
build outputs at their original absolute paths while running them, and serialize
runs that share counter paths. Local tests use loopback fixtures and private
files, without a live Foundry world.

## Source selection and reports

Titan selects production modules imported from source, excluding modules with
top-level `test_` functions and prebuilt SDK/native dependencies. Both images
retain all production modules in their source graph. The coverage test link also
names `main` as a source root so its executable lines remain visible with zero
hits when the runner does not call the application entry point.

The runner's report describes production behavior exercised by the tests. The
child's report describes the standalone startup/shutdown execution. Each report
retains unexecuted lines and refers to the original `.titan` sources. Read the
printed summaries and annotated `coverage.gcov` files directly.

See Titan's `doc/language/native-coverage.md` at the selected revision for
backend selection, source filters, and optional report formats.
