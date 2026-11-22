# Appendix A: Native Builds, Windows Packaging, Testing, and Retired Records

Both the `foundry-relay` server and its 15-module test suite compile directly
to native code with `titanc`, orchestrated by
[`foundry-relay-0.1.0-1.rockspec`](../foundry-relay-0.1.0-1.rockspec) (format
`3.0`, `MIT` license, dependencies `lua ~> 5.5`, `titan ~> 0.6`, and
`titan-mk ~> 0.1`) and [`scripts/rock-test.lua`](../scripts/rock-test.lua).
Neither artifact depends on the Titan compiler at runtime. On POSIX, the server
and test runner link statically against `titan-mk` and Titan's standard
provider; on Windows, each image ships as a launcher executable plus
application and runtime DLLs.

## POSIX build

Build on Linux or macOS against a prepared Titan 0.6 SDK containing `luarocks`,
`thread`, `http`, `websocket`, `sqlite3`, `json`, `peg`, and compiled
`titan.test`, with the `titan-mk` (`~> 0.1`) rock installed in the same tree.
Prepending the SDK's `bin` directory to `PATH` selects its compiler, LuaRocks,
and matching providers without pinning a Titan source revision; see
[Build, install, and test](../README.md#build-install-and-test) for quickstart
commands.

[`foundry-relay-0.1.0-1.rockspec`](../foundry-relay-0.1.0-1.rockspec) and
[`scripts/rock-test.lua`](../scripts/rock-test.lua) compile two native images
under `build/`:

- `luarocks make foundry-relay-0.1.0-1.rockspec` compiles root module
  `foundry_relay` (`--incremental --static --output build --exe
  build/foundry-relay foundry_relay`) and installs the standalone executable to
  `<tree>/bin/foundry-relay`. Remove it with `luarocks remove foundry-relay`.
- `luarocks test foundry-relay-0.1.0-1.rockspec` invokes
  [`scripts/rock-test.lua`](../scripts/rock-test.lua), which compiles both
  `build/foundry-relay` and the native `titan.test` runner `build/relay-tests`
  (`--incremental --static --output build --test --tree . --test-dir tests
  --exe build/relay-tests`), collecting every `tests/*_test.titan` module, and
  runs `RELAY_TEST_EXECUTABLE=build/foundry-relay build/relay-tests`. Pass
  runner arguments after `--`, such as
  `luarocks test foundry-relay-0.1.0-1.rockspec -- --filter='^tests[.]api_test'`.

Both commands invoke `titanc` directly; the compiler owns import discovery,
dependency scheduling, object certification, and final-link reuse. An unchanged
build compiles and links nothing; the server and test runner share unchanged
certified production `.o` files under `build/` and link against the installed
static providers (`titan.a`, `mk.a`) in the tree's `lib/titan/0.6`. Generated
C, headers, and objects preserve the repository layout under `build/`, while
target-specific synthetic runner and entrypoint files live under
`build/.titan-links/<key>/synthetic/`. Delete `build/` to force a clean rebuild.

The compiler keeps a disposable precise-stat digest cache at
`build/.titan/digests`, separate from object and link certificates. Missing or
malformed cache files are ignored and recomputed. Keep the `--tree` root
spelling consistent across invocations so generated source locations do not
shift and miss, and use distinct `--output` directories for incompatible tool
or flag configurations.

### OpenSSL modes and build variables

POSIX builds default to `OPENSSL_MODE=system`, matching Titan's default SDK.
Install OpenSSL 3.0 or newer development files and `pkg-config`. Both the
rockspec `build_command` and [`scripts/rock-test.lua`](../scripts/rock-test.lua)
verify `openssl >= 3.0` and export `pkg-config --cflags openssl` /
`pkg-config --libs openssl` via `TITAN_EXTRA_CPPFLAGS` and
`TITAN_EXTRA_LDFLAGS`. The resulting executable embeds `titan-mk` and Titan's
standard provider and dynamically links system OpenSSL at runtime.

When the installed Titan SDK was built with bundled OpenSSL, pass
`OPENSSL_MODE=bundled` in the environment to `luarocks make` and
`luarocks test`. Bundled mode links the OpenSSL objects carried by the SDK
without invoking `pkg-config`. `OPENSSL_MODE` must match the installed SDK; it
does not rebuild or reconfigure that SDK.

| Variable | Default | Purpose |
| --- | --- | --- |
| `OPENSSL_MODE` | `system` | `system` (`pkg-config`) or `bundled` (SDK-bundled OpenSSL) |
| `COVERAGE_GCOV` / `GCOV` | `gcov` | Coverage backend command resolved by [`scripts/rock-test.lua`](../scripts/rock-test.lua) when `--coverage` is passed |
| `TITAN_PROBE_CACHE_DISABLE` | unset | Set to `1` on restricted hosts so native-header probes do not write into an immutable SDK |

On restricted hosts, point `CCACHE_DIR` at a writable directory and set
`TITAN_PROBE_CACHE_DISABLE=1` so persistent native-header probes do not write
into an immutable SDK (also useful after a failed sandboxed probe).

[`titan-config.lua`](../titan-config.lua) sets `include = { "./" }` and
`source_module_roots = { "./" }` so the Titan language server resolves
`relay.*` and `tests.*` modules from the repository root. For instrumented
executable-line coverage, see [Appendix B: Executable Line Coverage](coverage.md).

## Windows build

Windows builds target an experimentally supported native x64 Titan Windows SDK
with WebSocket, compiled `titan.test.Case`/`run`, and `titan-mk` (`mk.dll`)
installed. Because `--static` is unsupported on Windows, the root entry module
is named `foundry_relay` ([`foundry_relay.titan`](../foundry_relay.titan)) so
its compiled provider is `foundry_relay.dll` rather than colliding as
`main.dll` inside shared `lib/titan/0.6`.

### LuaRocks install and test on Windows

[`foundry-relay-0.1.0-1.rockspec`](../foundry-relay-0.1.0-1.rockspec) defines
`platforms.windows` build, install, and `post_install` hooks:

- `luarocks make foundry-relay-0.1.0-1.rockspec` builds
  `build\bin\foundry-relay.exe` and `build\lib\titan\0.6\foundry_relay.dll`
  with `titanc.exe`, installs `foundry-relay.exe` into `<tree>\bin`, stages
  `foundry_relay.dll` into `$(PREFIX)\dist\modules\`, and runs
  `titan-install.bat --path "$(PREFIX)"` to publish `foundry_relay.dll` into
  `<tree>\lib\titan\0.6`. Remove the rock and published DLL cleanly with
  `titan-uninstall foundry-relay`.
- `luarocks test foundry-relay-0.1.0-1.rockspec` builds
  `build\bin\foundry-relay.exe` and `build\bin\relay-tests.exe`
  (`--test-exclude tests.process_test`) via
  [`scripts/rock-test.lua`](../scripts/rock-test.lua) and runs the suite with
  `PATH` and `TITAN_PATH_0_6` pointing at the SDK (`--coverage` is Linux and
  macOS only).

### Relocatable payload packaging (`Makefile.windows`)

To assemble and verify self-contained, compiler-free Windows payloads from an
MSYS2 `CLANG64` shell in a separate local NTFS checkout, supply the absolute
SDK prefix to [`Makefile.windows`](../Makefile.windows):

```sh
make -f Makefile.windows PREFIX=/c/Titan/sdk
make -f Makefile.windows test PREFIX=/c/Titan/sdk
```

`Makefile.windows` requires `titan.dll` and `mk.dll` in `$(PREFIX)/lib/titan/0.6`,
selects `clang`, `llvm-ar`, `llvm-ranlib`, and `llvm-rc`, sets
`TITAN_JOBS := 1`, `TITAN_RUNTIME_PREBUILT := 1`,
`TITAN_PROBE_CACHE_DISABLE := 1`, `MSYS2_ARG_CONV_EXCL := *`,
`-DUSING_UV_SHARED=1`, `-lcrypto`, and `--ldflag=-Wl,--stack,8388608`, and
invokes the SDK's `bin/titanc.exe` directly (which locates its installation
root and `share/lua/5.5/titan-compiler` frontend itself). Both targets pass
`--incremental --output`, sharing certified objects under `build/windows/out`
while assembling two self-contained, compiler-free payloads without modifying
the SDK:

- **Application payload (`build/windows/app`)**: `bin/foundry-relay.exe`, six
  adjacent runtime DLLs (`lua55.dll`, `libuv-1.dll`, `libllhttp-9.4.dll`,
  `libsqlite3-0.dll`, `libcrypto-3-x64.dll`, `libssl-3-x64.dll`),
  `lib/titan/0.6/foundry_relay.dll`, `mk.dll`, and `titan.dll`,
  [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md), and SDK notices under
  `licenses/`. Run `bin/foundry-relay.exe` and retain the full `bin`, `lib`,
  and license layout.
- **Test payload (`build/windows/test`)**: `bin/relay-tests.exe`, the same six
  runtime DLLs, `lib/titan/0.6/titan.dll`, `lib/titan/0.6/mk.dll`, and
  `lib/titan/0.6/tests/api_test.dll`. `core-test-build` discovers test modules
  with `--test-dir tests --test-exclude tests.process_test` and passes the
  explicit root `tests.api_test` so the packaged test provider keeps a
  deterministic DLL path.

`make -f Makefile.windows test` runs
[`scripts/check-windows.ps1`](../scripts/check-windows.ps1) (local PowerShell
policy must allow script execution; the target does not modify it), performing
four end-to-end delivery checks:

1. **PE import audit**: Verifies all six runtime DLLs, `titan.dll`, and
   `mk.dll` exist in both payloads, then runs `llvm-readobj --coff-imports` on
   every `.exe` and `.dll` across both trees to confirm `COFF-x86-64` format
   and reject any regular or delay-loaded import outside the six private DLLs,
   the 15 allowlisted Windows system DLLs, and `api-ms-win-crt-*.dll`.
2. **Unicode relocation without toolchain `PATH`**: Verifies local NTFS scratch
   storage, copies `build/windows/app` into a Unicode directory
   (`relay Windows 世界`), and launches `foundry-relay.exe` from a separate
   working directory with `PATH` reduced to `System32` and `%SystemRoot%` and
   all `LUA_*` and `TITAN_*` variables removed.
3. **Live smoke and log audit**: Verifies `server_started` on `stderr`, empty
   `stdout`, `GET /health`, SQLite-backed `POST /auth/pair`, authenticated
   `GET /clients`, three `http_request` JSON lines, and complete absence of the
   API key, pairing code, and pairing token from every log line, then ends the
   smoke process with `Process.Kill` (graceful shutdown is covered by native
   tests).
4. **Native suite**: Runs `relay-tests.exe` in the same stripped
   environment—forwarding `RELAY_TEST_OPENSSL` and `RELAY_TEST_CHROME` and
   placing `RELAY_TEST_BROWSER_PROFILES` in its scratch directory—and checks
   the `[==========] ... tests ran.` / `[  PASSED  ]` summary. Production
   sessions call OpenSSL directly through `libcrypto-3-x64.dll`.

## Test architecture

`luarocks test foundry-relay-0.1.0-1.rockspec` executes `build/relay-tests`
with `RELAY_TEST_EXECUTABLE=build/foundry-relay` on POSIX (or
`build\bin\relay-tests.exe` on Windows). The 15 native `tests/*_test.titan`
modules partition across four verification layers (routing, logging, `413`
body-limit, and `WWW-Authenticate` `401` middleware primitives are covered by
`titan-mk`'s own suites):

| Layer | Test modules | Coverage focus |
| --- | --- | --- |
| Unit & boundaries | `api_test`, `store_test`, `session_crypto_test`, `cdp_test` | 91-endpoint `mk.router` integration, parameter validation, and Base64 framing, SQLite schema/mode/pairing reuse, RSA-OAEP interop, single-flight CDP timeouts and error sanitization |
| Concurrency & lifecycle | `store_concurrency_test`, `replies_test`, `protocol_test`, `threading_test`, `sessions_test` | 4-thread `SQLITE_BUSY` retry, 4-lease reply pool FIFO and channel replacement, WebSocket world engine and reconnect quiescence, `mk` pool/session dispatch and cancelled credential revocation, `sessions.Manager` admission and cleanup quarantine |
| Browser & HTTP/WS integration | `browser_test`, `foundry_session_test`, `integration_test`, `logging_http_test`, `session_http_test` | Fake-child and installed-Chromium lifecycle, Foundry preload/join/readiness verification, loopback REST/WebSocket/SSE forwarding, `mk.middleware.logger` admission + single-timeout logging, two-phase HTTP session publication |
| Standalone delivery | `process_test` | Relocated static binary launched with stripped `PATH`/`TITAN_*`/`LUA_*`, live pair/WS/SSE lifecycle, graceful `SIGTERM` shutdown, credential-free JSON `stderr`, and child coverage report check |

Every production module (`foundry_relay.titan` and all 19 `relay/*.titan`
files) uses ordinary compiled imports with zero `.titan` source imports,
enforcing strict public interfaces across the codebase. White-box tests
selectively use explicit `.titan` source imports (such as
`import "relay.store.titan"`, `import "relay.server.titan"`,
`import "relay.replies.titan"`, and `import "relay.sessions.titan"`) to reach
`local` internals deterministically:
[`tests/threading_test.titan`](../tests/threading_test.titan) to cancel a
credential transition mid-SQLite wait, asserting `#f.pool.waiters` and
`#f.pool.leases` in [`tests/replies_test.titan`](../tests/replies_test.titan),
or invoking `Store:operation` and `store.execute` directly in
[`tests/store_concurrency_test.titan`](../tests/store_concurrency_test.titan)—alongside
nominal `sessions.Client` interface fakes in
[`tests/sessions_test.titan`](../tests/sessions_test.titan).

```titan
function test_busy_retries_roll_back_the_complete_write(context: test.Context)
  local database = fixture(context)
  local client = database:pair("world", "Before")
  local attempts = 0
  database:operation<|nil|>(true, function(db: sqlite3.Connection): nil
    attempts = attempts + 1
    store.execute(db, "UPDATE clients SET world_title = world_title || '!' WHERE client_id = ?",
                  client.client_id)
    if attempts == 1 then
      raise sqlite3.Error("BUSY after an uncommitted mutation", 5, 5, "test.retry")
    end
    return nil
  end)
  test.assert(attempts == 2 and database:get(client.client_id).world_title == "Before!",
              "BUSY retry retained a partial mutation or failed to retry")
end
```
*Source: [`tests/store_concurrency_test.titan`](../tests/store_concurrency_test.titan) — `test_busy_retries_roll_back_the_complete_write`*

[GitHub Actions](../.github/workflows/ci.yml) runs `luarocks lint`, `luarocks test`, and an install, standalone-run, and removal smoke ([`.github/scripts/package-smoke.sh`](../.github/scripts/package-smoke.sh)) on Linux x64, macOS arm64, and Windows x64 (MSYS2 CLANG64). Each job builds the pinned Titan release SDK and installs the `titan-mk` source rock from its GitHub release (`MK_RELEASE`), checking both release digests; the Windows job also runs `make -f Makefile.windows test`.

### Optional test capabilities and platform skips

| Variable | Effect |
| --- | --- |
| `RELAY_TEST_CHROME` and `RELAY_TEST_BROWSER_PROFILES` | Enable installed-Chromium lifecycle ([`tests/browser_test.titan`](../tests/browser_test.titan)) and Foundry login/readiness DOM cases ([`tests/foundry_session_test.titan`](../tests/foundry_session_test.titan)); both must be set. With Flatpak Chrome, point `RELAY_TEST_BROWSER_PROFILES` at a workspace-local directory accessible to the sandbox rather than `/tmp`. |
| `RELAY_TEST_OPENSSL` | OpenSSL CLI executable for independent-client RSA-OAEP cases in [`tests/session_crypto_test.titan`](../tests/session_crypto_test.titan); defaults to `openssl` and skips when missing (`ENOENT`). |
| `RELAY_TEST_EXECUTABLE` | Server binary tested by [`tests/process_test.titan`](../tests/process_test.titan); set automatically by `luarocks test` (`scripts/rock-test.lua`). |

POSIX runs skip the Windows exclusive-file-sharing case in
[`tests/browser_test.titan`](../tests/browser_test.titan). Windows runs skip
POSIX permission-bit checks in
[`tests/store_test.titan`](../tests/store_test.titan) and fake-child shell
fixtures in [`tests/browser_test.titan`](../tests/browser_test.titan), and omit
[`tests/process_test.titan`](../tests/process_test.titan) at link time. The
4-thread pool-saturation regression in
[`tests/store_concurrency_test.titan`](../tests/store_concurrency_test.titan)
skips when `UV_THREADPOOL_SIZE` is set to anything other than `4`.

## Provenance

Route and wire-protocol compatibility was researched from the upstream Go relay
at `65ce83d6a534ea6d340c8a89d72251f4c6a0294e` and the locally installed Foundry
module's source map, and checked live against Foundry 14.368 with REST API
module 3.4.1. `foundry-relay` itself is licensed under the MIT License
([`LICENSE`](../LICENSE)), and [Third-party notices](../THIRD_PARTY_NOTICES.md)
preserve the upstream MIT notice. HTTP routing, middleware, worker pools,
ephemeral session workers, and structured logging are supplied directly by the
installed [`titan-mk`](https://github.com/mascarenhas/mk) framework.

## Retired records

Validation logs, audits, and measurement records describe past runs rather than
current behavior. Their lasting conclusions live in this book and the usage
guides; their final snapshots remain archived:

- [`docs/master-validation.md`](https://github.com/mascarenhas/foundry-relay/blob/25271a4d5581b1a65a0184a9518318d15d85e85f/docs/master-validation.md): 2026-10-25 Titan-master validation on Linux and M1 macOS, including the headless login and timeout-logging regressions.
- [`docs/validation.md`](https://github.com/mascarenhas/foundry-relay/blob/2903378391888e0737819920abe8d15c7bda9875/docs/validation.md): Linux, Windows, and live Foundry validation of the relay before it used worker threads.
- [`docs/logging-validation.md`](https://github.com/mascarenhas/foundry-relay/blob/2903378391888e0737819920abe8d15c7bda9875/docs/logging-validation.md): validation of structured logging.
- [`docs/session-validation.md`](https://github.com/mascarenhas/foundry-relay/blob/2903378391888e0737819920abe8d15c7bda9875/docs/session-validation.md): validation of the headless session API, including the live HTTPS Foundry run.
- [`docs/thread-validation.md`](https://github.com/mascarenhas/foundry-relay/blob/2903378391888e0737819920abe8d15c7bda9875/docs/thread-validation.md): Linux, macOS, and Windows validation of the threaded relay.
- [`docs/api-audit.md`](https://github.com/mascarenhas/foundry-relay/blob/2903378391888e0737819920abe8d15c7bda9875/docs/api-audit.md): the upstream API audit, with evidence links and the follow-up checklist.
- [`docs/coverage-baseline.json`](https://github.com/mascarenhas/foundry-relay/blob/2903378391888e0737819920abe8d15c7bda9875/docs/coverage-baseline.json): a coverage snapshot from an earlier collection workflow.
- [Channel cost measurements](https://github.com/mascarenhas/foundry-relay/blob/2903378391888e0737819920abe8d15c7bda9875/docs/threading.md#channel-cost-measurements), archived from `docs/threading.md`: the reply-channel benchmark behind the lease pool.

---

← Previous: [Chapter 4: Headless Browser Automation and the OpenSSL FFI Boundary](headless-sessions.md) | [Table of Contents](index.md) | Next: [Appendix B: Executable Line Coverage](coverage.md) →
