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
TEST_ROOTS := tests.router_test tests.store_test tests.api_test tests.protocol_test tests.integration_test tests.process_test

.PHONY: all test clean check-openssl build/foundry-relay build/relay-tests
all: build/foundry-relay

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

clean:
	rm -rf build
