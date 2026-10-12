TITANC ?= titanc
TITAN_JOBS ?= 2
TITAN_STDLIB ?= $(abspath $(dir $(shell command -v $(TITANC)))/../lib/titan/0.6)
OPENSSL_MODE ?= system
PKG_CONFIG ?= pkg-config

ifeq ($(OPENSSL_MODE),system)
override export TITAN_EXTRA_CPPFLAGS := $(TITAN_EXTRA_CPPFLAGS) $(shell $(PKG_CONFIG) --cflags openssl 2>/dev/null)
override export TITAN_EXTRA_LDFLAGS := $(TITAN_EXTRA_LDFLAGS) $(shell $(PKG_CONFIG) --libs openssl 2>/dev/null)
else ifneq ($(OPENSSL_MODE),bundled)
$(error OPENSSL_MODE must be system or bundled and match the installed Titan SDK)
endif

ROOT := $(abspath .)
APP_SOURCES := $(wildcard relay/*.titan) main.titan
SOURCES := $(APP_SOURCES) $(wildcard tests/*.titan)
TEST_ROOTS := tests.router_test tests.store_test tests.api_test tests.protocol_test tests.integration_test tests.process_test tests.cdp_test tests.browser_test tests.spike_input_test tests.foundry_session_test tests.session_crypto_test tests.sessions_test tests.session_http_test
COVERAGE_GCOV ?= $(shell command -v gcov)
COVERAGE_GCOVR ?= $(shell command -v gcovr)
COVERAGE_FORMATS ?= html lcov cobertura
PYTHON ?= python3
COVERAGE_OPTIONS = --coverage --coverage-gcov "$(COVERAGE_GCOV)" --coverage-gcovr "$(COVERAGE_GCOVR)" $(foreach format,$(sort lcov $(COVERAGE_FORMATS)),--coverage-format $(format))
COVERAGE_RENDER = $(if $(filter html,$(COVERAGE_FORMATS)),--html-details build/coverage-report/coverage.html --html-single-page static --html-template-dir build/coverage-src/.coverage/report --html-title 'Foundry relay executable-line coverage') $(if $(filter lcov,$(COVERAGE_FORMATS)),--lcov build/coverage-report/coverage.info) $(if $(filter cobertura,$(COVERAGE_FORMATS)),--cobertura build/coverage-report/coverage.xml)

.PHONY: all test clean check-openssl build/foundry-relay build/relay-tests coverage coverage-build coverage-run headless build/foundry-relay-headless
all: build/foundry-relay

# Retained explicit spike harness; production sessions use the ordinary main.
headless: build/foundry-relay-headless

build/foundry-relay-headless: $(APP_SOURCES) headless.titan Makefile | check-openssl
	rm -rf build/headless-src
	mkdir -p build/headless-src/relay build/tmp
	cp relay/*.titan build/headless-src/relay/
	cp headless.titan build/headless-src/headless.titan
	cd build/headless-src && TMPDIR="$(ROOT)/build/tmp" $(TITANC) --static -j $(TITAN_JOBS) headless
	cp build/headless-src/headless $@

check-openssl:
ifeq ($(OPENSSL_MODE),system)
	@$(PKG_CONFIG) --print-errors --exists 'openssl >= 3.0' || { \
		printf '%s\n' 'System OpenSSL >= 3.0 development files and pkg-config are required; OPENSSL_MODE must match the installed Titan SDK.' >&2; \
		exit 1; \
	}
endif

# Recreate owned stages so SDK, flag, and source-inventory changes cannot reuse
# stale objects. Titan's incremental reuse only checks source timestamps.
build/foundry-relay: $(APP_SOURCES) Makefile | check-openssl
	rm -rf build/app-src
	mkdir -p build/app-src/relay build/tmp
	cp relay/*.titan build/app-src/relay/
	cp main.titan build/app-src/main.titan
	cd build/app-src && TMPDIR="$(ROOT)/build/tmp" $(TITANC) --static -j $(TITAN_JOBS) main
	cp build/app-src/main $@

build/relay-tests: $(SOURCES) Makefile | check-openssl
	rm -rf build/test-src
	mkdir -p build/test-src/relay build/test-src/tests build/tmp
	cp relay/*.titan build/test-src/relay/
	cp tests/*.titan build/test-src/tests/
	cd build/test-src && TMPDIR="$(ROOT)/build/tmp" $(TITANC) --static -j $(TITAN_JOBS) --test $(TEST_ROOTS)
	cp build/test-src/tests/router_test $@

test: build/foundry-relay build/relay-tests
	TITAN_PATH_0_6="$(TITAN_STDLIB)" RELAY_TEST_EXECUTABLE="$(ROOT)/build/foundry-relay" timeout 120s build/relay-tests $(TEST_ARGS)

# Coverage objects live in .coverage directories; ordinary builds are unaffected.
# Separate app/test stages also give the two executing images private counters.
coverage-build: $(SOURCES) Makefile | check-openssl
	test -n "$(COVERAGE_GCOV)" && test -n "$(COVERAGE_GCOVR)"
	rm -rf build/coverage-app-src build/coverage-src
	mkdir -p build/coverage-app-src build/coverage-src build/tmp
	cp -R relay main.titan build/coverage-app-src/
	cp -R relay tests main.titan build/coverage-src/
	cd build/coverage-app-src && env -u GCOV_PREFIX -u GCOV_PREFIX_STRIP TMPDIR="$(ROOT)/build/tmp" $(TITANC) --static -j $(TITAN_JOBS) $(COVERAGE_OPTIONS) main
	cd build/coverage-src && env -u GCOV_PREFIX -u GCOV_PREFIX_STRIP TMPDIR="$(ROOT)/build/tmp" $(TITANC) --static -j $(TITAN_JOBS) $(COVERAGE_OPTIONS) --test $(TEST_ROOTS) main

coverage-run:
	rm -rf build/coverage-report build/coverage-src/.coverage/report build/coverage-app-src/.coverage/report
	mkdir -p build/coverage-report build/coverage-src/.coverage/report build/coverage-app-src/.coverage/report
	env -u TITAN_FILTER -u GCOV_PREFIX -u GCOV_PREFIX_STRIP TITAN_PATH_0_6="$(TITAN_STDLIB)" RELAY_TEST_EXECUTABLE="$(ROOT)/build/coverage-app-src/main" timeout 120s build/coverage-src/tests/router_test > build/coverage-report/tests.log 2>&1 || { cat build/coverage-report/tests.log; exit 1; }
	cat build/coverage-report/tests.log
	$(PYTHON) scripts/coverage.py --root "$(ROOT)" --output build/coverage-report --test-log build/coverage-report/tests.log --input build/coverage-src build/coverage-src/.coverage/report/lines.json --input build/coverage-app-src build/coverage-app-src/.coverage/report/lines.json
	$(COVERAGE_GCOVR) --config build/coverage-report/gcovr.cfg --root "$(ROOT)" --add-tracefile build/coverage-report/trace-0.json --add-tracefile build/coverage-report/trace-1.json --no-markers --no-exclude-noncode-lines --json build/coverage-report/lines.json $(COVERAGE_RENDER)
ifneq ($(filter lcov,$(COVERAGE_FORMATS)),)
	sed -i -e '/^FN/d' -e '/^BR/d' -e '/^DA:/s/,None$$//' build/coverage-report/coverage.info
endif

coverage: coverage-build
	$(MAKE) coverage-run

clean:
	rm -rf build
