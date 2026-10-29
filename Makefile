TITANC ?= titanc
TITAN_JOBS ?= 2
TEST_TIMEOUT ?= 300
TITAN_PREFIX ?= $(abspath $(dir $(shell command -v $(firstword $(TITANC)) 2>/dev/null))/..)
TITAN_STDLIB ?= $(TITAN_PREFIX)/lib/titan/0.6
export TITAN_ROOT := $(TITAN_PREFIX)
export TITAN_PATH_0_6 := $(TITAN_STDLIB)
OPENSSL_MODE ?= system
PKG_CONFIG ?= pkg-config

ifeq ($(OPENSSL_MODE),system)
OPENSSL_FLAGS = $(foreach flag,$(shell $(PKG_CONFIG) --cflags openssl 2>/dev/null),$(if $(filter -I% -D%,$(flag)),$(flag),--cflag=$(flag))) \
	$(foreach flag,$(shell $(PKG_CONFIG) --libs openssl 2>/dev/null),$(if $(filter -L% -l%,$(flag)),$(flag),--ldflag=$(flag)))
else ifneq ($(OPENSSL_MODE),bundled)
$(error OPENSSL_MODE must be system or bundled and match the installed Titan SDK)
endif

ROOT := $(abspath .)
BUILD_FLAGS = --incremental --static --output build -j $(TITAN_JOBS) $(OPENSSL_FLAGS)

COVERAGE_GCOV ?= $(shell command -v gcov)
COVERAGE_OPTIONS = --coverage --coverage-gcov "$(COVERAGE_GCOV)"

.DELETE_ON_ERROR:
.PHONY: all build/foundry-relay build/relay-tests test clean check-sdk check-openssl coverage coverage-build coverage-run
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

build/foundry-relay: | check-sdk check-openssl
	+$(TITANC) $(BUILD_FLAGS) --exe $@ main

build/relay-tests: | check-sdk check-openssl
	+$(TITANC) $(BUILD_FLAGS) --test --tree . --test-dir tests --exe $@

test: build/foundry-relay build/relay-tests
	TITAN_PATH_0_6="$(TITAN_STDLIB)" RELAY_TEST_EXECUTABLE="$(ROOT)/build/foundry-relay" timeout $(TEST_TIMEOUT)s build/relay-tests $(TEST_ARGS)

# Coverage objects live in .coverage directories; ordinary builds are unaffected.
# These two images reset/dump counters independently while the suite is active,
# so each has its own output tree for separate .gcda ownership.
coverage-build: | check-sdk check-openssl
	test -n "$(COVERAGE_GCOV)"
	rm -rf build/coverage-app build/coverage-tests
	+env -u GCOV_PREFIX -u GCOV_PREFIX_STRIP $(TITANC) --output build/coverage-app --static -j $(TITAN_JOBS) $(OPENSSL_FLAGS) $(COVERAGE_OPTIONS) --exe build/coverage-app/main main
	+env -u GCOV_PREFIX -u GCOV_PREFIX_STRIP $(TITANC) --output build/coverage-tests --static -j $(TITAN_JOBS) $(OPENSSL_FLAGS) $(COVERAGE_OPTIONS) --test --tree . --test-dir tests --exe build/coverage-tests/tests/router_test main

coverage-run:
	rm -rf build/coverage-tests/.coverage/report build/coverage-app/.coverage/report
	mkdir -p build/coverage-tests/.coverage/report build/coverage-app/.coverage/report
	env -u TITAN_FILTER -u GCOV_PREFIX -u GCOV_PREFIX_STRIP TITAN_PATH_0_6="$(TITAN_STDLIB)" RELAY_TEST_EXECUTABLE="$(ROOT)/build/coverage-app/main" RELAY_TEST_COVERAGE_REPORT="$(ROOT)/build/coverage-app/.coverage/report" timeout $(TEST_TIMEOUT)s build/coverage-tests/tests/router_test

coverage: coverage-build
	$(MAKE) coverage-run
clean:
	rm -rf build
