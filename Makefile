ODIN ?= odin
BIN := build/gitmd
FISH_FUNCTIONS_DIR ?= $(HOME)/.config/fish/functions

.PHONY: all clean compile fish run test

all: compile
	$(BIN) "$${GITMD_TARGET:-.}"

compile: $(BIN)

$(BIN): $(shell find src -type f)
	@mkdir -p build
	$(ODIN) build src -out:$(BIN) -o:speed

test:
	$(ODIN) test src -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false

run:
	$(BIN)

fish:
	@mkdir -p "$(FISH_FUNCTIONS_DIR)"
	@printf '%s\n' \
		'function gitmd' \
		'    if test (count $$argv) -gt 1' \
		'        echo "usage: gitmd [repository-or-markdown-path]" >&2' \
		'        return 2' \
		'    end' \
		'    set -lx GITMD_TARGET $$PWD' \
		'    if test (count $$argv) -eq 1' \
		'        set GITMD_TARGET $$argv[1]' \
		'    end' \
		'    make -C "$(CURDIR)"' \
		'end' > "$(FISH_FUNCTIONS_DIR)/gitmd.fish"

clean:
	rm -f $(BIN) src.bin
