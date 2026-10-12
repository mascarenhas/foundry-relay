TITANC ?= titanc
TITAN_JOBS ?= 2
TITAN_PREFIX ?= $(abspath $(dir $(shell command -v $(firstword $(TITANC)) 2>/dev/null))/..)
TITAN_STDLIB ?= $(TITAN_PREFIX)/lib/titan/0.6
export TITAN_ROCKS_ROOT := $(TITAN_PREFIX)
export TITAN_PATH_0_6 := $(TITAN_STDLIB)
OPENSSL_MODE ?= system
PKG_CONFIG ?= pkg-config

ifeq ($(OPENSSL_MODE),system)
override export TITAN_EXTRA_CPPFLAGS := $(strip $(TITAN_EXTRA_CPPFLAGS) $(shell $(PKG_CONFIG) --cflags openssl 2>/dev/null))
override export TITAN_EXTRA_LDFLAGS := $(strip $(TITAN_EXTRA_LDFLAGS) $(shell $(PKG_CONFIG) --libs openssl 2>/dev/null))
OPENSSL_INPUTS := $(wildcard $(shell $(PKG_CONFIG) --variable=includedir openssl 2>/dev/null)/openssl/*.h $(shell $(PKG_CONFIG) --variable=libdir openssl 2>/dev/null)/libssl.* $(shell $(PKG_CONFIG) --variable=libdir openssl 2>/dev/null)/libcrypto.*)
else ifneq ($(OPENSSL_MODE),bundled)
$(error OPENSSL_MODE must be system or bundled and match the installed Titan SDK)
endif

ROOT := $(abspath .)
APP_SOURCES := main.titan $(sort $(wildcard relay/*.titan))
TEST_SOURCES := $(sort $(wildcard tests/*.titan))
SOURCES := $(APP_SOURCES) $(TEST_SOURCES)
MODULES := $(SOURCES:.titan=)
APP_OBJECTS := $(APP_SOURCES:.titan=.o)
TEST_OBJECTS := $(filter-out main.o,$(SOURCES:.titan=.o))
TEST_ROOTS := tests.router_test tests.store_test tests.api_test tests.protocol_test tests.integration_test tests.process_test tests.cdp_test tests.browser_test tests.foundry_session_test tests.session_crypto_test tests.sessions_test tests.session_http_test tests.log_test tests.logging_http_test
BUILD_FLAGS := --source-first --static --incremental
BUILD_CONFIG := build/config

include Makefile.modules

# Compiler/SDK and native inputs are ordinary Make prerequisites. A changed
# setting or source inventory updates the small configuration stamp below.
SDK_INPUTS := $(wildcard $(TITAN_PREFIX)/bin/titanc $(TITAN_PREFIX)/bin/lua $(TITAN_PREFIX)/lib/luarocks/rocks-5.5/titan/0.6.0-1/bin/titanc $(TITAN_PREFIX)/etc/titan/build-profile $(TITAN_STDLIB)/* $(TITAN_PREFIX)/lib/liblua.a $(TITAN_PREFIX)/lib/libbacktrace.a $(TITAN_PREFIX)/include/*.h $(TITAN_PREFIX)/include/titan/*.h $(TITAN_PREFIX)/include/openssl/*.h $(TITAN_PREFIX)/src/lua-5.5.1/*.h $(TITAN_PREFIX)/share/lua/5.5/titan-compiler/*.lua $(TITAN_PREFIX)/share/lua/5.5/titan-compiler/*/*.lua $(TITAN_PREFIX)/share/lua/5.5/c-parser/*.lua)
TOOL_INPUTS := $(foreach tool,$(CC) $(AR) $(RANLIB) $(PKG_CONFIG),$(shell command -v $(firstword $(tool)) 2>/dev/null))
BUILD_INPUTS := Makefile Makefile.modules $(BUILD_CONFIG) $(SDK_INPUTS) $(OPENSSL_INPUTS) $(TOOL_INPUTS)
shell_quote = '$(subst ','"'"',$(1))'

COVERAGE_GCOV ?= $(shell command -v gcov)
COVERAGE_GCOVR ?= $(shell command -v gcovr)
COVERAGE_FORMATS ?= html lcov cobertura
PYTHON ?= python3
COVERAGE_OPTIONS = --coverage --coverage-gcov "$(COVERAGE_GCOV)" --coverage-gcovr "$(COVERAGE_GCOVR)" $(foreach format,$(sort lcov $(COVERAGE_FORMATS)),--coverage-format $(format))
COVERAGE_RENDER = $(if $(filter html,$(COVERAGE_FORMATS)),--html-details build/coverage-report/coverage.html --html-single-page static --html-template-dir build/coverage-src/.coverage/report --html-title 'Foundry relay executable-line coverage') $(if $(filter lcov,$(COVERAGE_FORMATS)),--lcov build/coverage-report/coverage.info) $(if $(filter cobertura,$(COVERAGE_FORMATS)),--cobertura build/coverage-report/coverage.xml)

.DELETE_ON_ERROR:
.PHONY: all test clean check-sdk check-openssl FORCE coverage coverage-check coverage-build coverage-run
all: build/foundry-relay

check-sdk:
	@test -f "$(TITAN_PREFIX)/bin/titanc" -a -f "$(TITAN_STDLIB)/titan.a" || { \
		printf '%s\n' 'Use a prepared Titan SDK with compiled titan.test Case/run support; set TITANC to its bin/titanc.' >&2; exit 1; \
	}

check-openssl:
ifeq ($(OPENSSL_MODE),system)
	@$(PKG_CONFIG) --print-errors --exists 'openssl >= 3.0' || { \
		printf '%s\n' 'System OpenSSL >= 3.0 development files and pkg-config are required; OPENSSL_MODE must match the installed Titan SDK.' >&2; \
		exit 1; \
	}
endif

FORCE:

$(BUILD_CONFIG): FORCE | check-sdk check-openssl
	@mkdir -p build/tmp
	@printf '%s\n' $(call shell_quote,TITANC=$(TITANC)) $(call shell_quote,TITAN_PREFIX=$(TITAN_PREFIX)) \
		$(call shell_quote,TITAN_STDLIB=$(TITAN_STDLIB)) $(call shell_quote,CC=$(CC)) \
		$(call shell_quote,AR=$(AR)) $(call shell_quote,RANLIB=$(RANLIB)) \
		$(call shell_quote,OPENSSL_MODE=$(OPENSSL_MODE)) $(call shell_quote,PKG_CONFIG=$(PKG_CONFIG)) \
		$(call shell_quote,BUILD_FLAGS=$(BUILD_FLAGS)) $(call shell_quote,TITAN_BUILD_PROFILE=$(TITAN_BUILD_PROFILE)) \
		$(call shell_quote,TITAN_EXTRA_CPPFLAGS=$(TITAN_EXTRA_CPPFLAGS)) \
		$(call shell_quote,TITAN_EXTRA_CFLAGS=$(TITAN_EXTRA_CFLAGS)) \
		$(call shell_quote,TITAN_EXTRA_LDFLAGS=$(TITAN_EXTRA_LDFLAGS)) \
		$(call shell_quote,TITAN_NO_LINE_DIRECTIVES=$(TITAN_NO_LINE_DIRECTIVES)) \
		$(call shell_quote,SOURCES=$(SOURCES)) $(call shell_quote,TEST_ROOTS=$(TEST_ROOTS)) \
		$(call shell_quote,SDK_INPUTS=$(SDK_INPUTS)) $(call shell_quote,TOOL_INPUTS=$(TOOL_INPUTS)) > "$@.tmp"
	@if test -r "$@" && cmp -s "$@.tmp" "$@"; then rm "$@.tmp"; else mv "$@.tmp" "$@"; fi

# Each logical module owns one shared object and generated companion set.
# Dependencies finish before consumers, so parallel roots only reuse them.
define module_rule
$(1).o $(1).c $(1).ffi.h &: $(1).titan $$(BUILD_INPUTS) \
	$$(foreach dependency,$$(MODULE_IMPORTS_$(1)),$$(dependency).o $$(dependency).ffi.h)
	TMPDIR="$$(ROOT)/build/tmp" $$(TITANC) $$(BUILD_FLAGS) -j $$(TITAN_JOBS) \
		$$(if $$(filter tests/%,$(1)),--test) -c $$(subst /,.,$(1))
endef
$(foreach module,$(MODULES),$(eval $(call module_rule,$(module))))

build/foundry-relay: $(APP_OBJECTS) $(BUILD_INPUTS)
	cd build && TMPDIR="$(ROOT)/build/tmp" $(TITANC) $(BUILD_FLAGS) -j $(TITAN_JOBS) --tree "$(ROOT)" main
	mv build/main $@

build/relay-tests: $(TEST_OBJECTS) $(BUILD_INPUTS)
	cd build && TMPDIR="$(ROOT)/build/tmp" $(TITANC) $(BUILD_FLAGS) -j $(TITAN_JOBS) --tree "$(ROOT)" --test $(TEST_ROOTS)
	mv build/tests/router_test $@

test: build/foundry-relay build/relay-tests
	TITAN_PATH_0_6="$(TITAN_STDLIB)" RELAY_TEST_EXECUTABLE="$(ROOT)/build/foundry-relay" timeout 120s build/relay-tests $(TEST_ARGS)

# Coverage objects live in .coverage directories; ordinary builds are unaffected.
# These two images reset/dump counters independently while the suite is active,
# so coverage alone retains private stages for separate .gcda ownership.
coverage-check:
	$(PYTHON) scripts/coverage_test.py

coverage-build: $(SOURCES) Makefile | check-openssl coverage-check
	test -n "$(COVERAGE_GCOV)" && test -n "$(COVERAGE_GCOVR)"
	rm -rf build/coverage-app-src build/coverage-src
	mkdir -p build/coverage-app-src/relay build/coverage-src/relay build/coverage-src/tests build/tmp
	cp relay/*.titan build/coverage-app-src/relay/
	cp main.titan build/coverage-app-src/
	cp relay/*.titan build/coverage-src/relay/
	cp tests/*.titan build/coverage-src/tests/
	cp main.titan build/coverage-src/
	cd build/coverage-app-src && env -u GCOV_PREFIX -u GCOV_PREFIX_STRIP TMPDIR="$(ROOT)/build/tmp" $(TITANC) --source-first --static -j $(TITAN_JOBS) $(COVERAGE_OPTIONS) main
	cd build/coverage-src && env -u GCOV_PREFIX -u GCOV_PREFIX_STRIP TMPDIR="$(ROOT)/build/tmp" $(TITANC) --source-first --static -j $(TITAN_JOBS) $(COVERAGE_OPTIONS) --test $(TEST_ROOTS) main

coverage-run:
	rm -rf build/coverage-report build/coverage-src/.coverage/report build/coverage-app-src/.coverage/report
	mkdir -p build/coverage-report build/coverage-src/.coverage/report build/coverage-app-src/.coverage/report
	env -u TITAN_FILTER -u GCOV_PREFIX -u GCOV_PREFIX_STRIP TITAN_PATH_0_6="$(TITAN_STDLIB)" RELAY_TEST_EXECUTABLE="$(ROOT)/build/coverage-app-src/main" RELAY_TEST_COVERAGE_REPORT="$(ROOT)/build/coverage-app-src/.coverage/report" timeout 120s build/coverage-src/tests/router_test > build/coverage-report/tests.log 2>&1 || { cat build/coverage-report/tests.log; exit 1; }
	cat build/coverage-report/tests.log
	$(PYTHON) scripts/coverage.py --root "$(ROOT)" --output build/coverage-report --test-log build/coverage-report/tests.log --input build/coverage-src build/coverage-src/.coverage/report/lines.json --input build/coverage-app-src build/coverage-app-src/.coverage/report/lines.json
	$(COVERAGE_GCOVR) --config build/coverage-report/gcovr.cfg --root "$(ROOT)" --add-tracefile build/coverage-report/trace-0.json --add-tracefile build/coverage-report/trace-1.json --no-markers --no-exclude-noncode-lines --json build/coverage-report/lines.json $(COVERAGE_RENDER)
ifneq ($(filter lcov,$(COVERAGE_FORMATS)),)
	sed -i -e '/^FN/d' -e '/^BR/d' -e '/^DA:/s/,None$$//' build/coverage-report/coverage.info
endif

coverage: coverage-build
	$(MAKE) coverage-run
clean:
	rm -f $(foreach module,$(MODULES),$(module).o $(module).c $(module).ffi.h $(module).titan.h)
	rm -rf build
