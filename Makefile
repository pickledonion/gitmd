ODIN ?= odin
BIN := build/gitmd
PREFIX ?= $(HOME)/.local

.PHONY: all clean install test

all: $(BIN)

$(BIN): $(shell find src -type f)
	@mkdir -p build
	$(ODIN) build src -out:$(BIN) -o:speed

test:
	$(ODIN) test src -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false

install: $(BIN)
	@mkdir -p "$(PREFIX)/bin"
	install -m 0755 $(BIN) "$(PREFIX)/bin/gitmd"

clean:
	rm -f $(BIN) src.bin
