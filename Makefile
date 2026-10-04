TITANC ?= titanc
TITAN_JOBS ?= 2
TITAN_STDLIB ?= $(abspath $(dir $(shell command -v $(TITANC)))/../lib/titan/0.6)
ROOT := $(abspath .)
APP_SOURCES := $(wildcard relay/*.titan) main.titan
SOURCES := $(APP_SOURCES) $(wildcard tests/*.titan)
TEST_ROOTS := tests.router_test tests.store_test tests.api_test tests.protocol_test tests.integration_test tests.process_test

.PHONY: all test clean
all: build/foundry-relay

build/foundry-relay: $(APP_SOURCES) Makefile
	mkdir -p build/app-src/relay build/tmp
	cp relay/*.titan build/app-src/relay/
	cp main.titan build/app-src/main.titan
	cd build/app-src && TMPDIR="$(ROOT)/build/tmp" $(TITANC) --static --incremental -j $(TITAN_JOBS) main
	cp build/app-src/main $@

build/relay-tests: $(SOURCES) Makefile
	mkdir -p build/test-src/relay build/test-src/tests build/tmp
	cp relay/*.titan build/test-src/relay/
	cp tests/*.titan build/test-src/tests/
	cd build/test-src && TMPDIR="$(ROOT)/build/tmp" $(TITANC) --static --incremental -j $(TITAN_JOBS) --test $(TEST_ROOTS)
	cp build/test-src/tests/router_test $@

test: build/foundry-relay build/relay-tests
	TITAN_PATH_0_6="$(TITAN_STDLIB)" RELAY_TEST_EXECUTABLE="$(ROOT)/build/foundry-relay" timeout 120s build/relay-tests $(TEST_ARGS)

clean:
	rm -rf build
