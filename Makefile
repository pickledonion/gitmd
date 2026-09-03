ODIN ?= odin
BIN := build/gitmd
FISH_FUNCTIONS_DIR ?= $(HOME)/.config/fish/functions

.PHONY: all build clean fish run test

all: run

build: $(BIN)

$(BIN): $(shell find src -type f)
	@mkdir -p build
	$(ODIN) build src -out:$(BIN) -o:speed

test:
	$(ODIN) test src -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false

run: $(BIN)
	$(BIN)

fish:
	@mkdir -p "$(FISH_FUNCTIONS_DIR)"
	@printf '%s\n' \
		'function gitmd' \
		'    make -C "$(CURDIR)" build' \
		'    or return' \
		'    command "$(CURDIR)/$(BIN)" $$argv' \
		'end' > "$(FISH_FUNCTIONS_DIR)/gitmd.fish"

clean:
	rm -f $(BIN) src.bin
