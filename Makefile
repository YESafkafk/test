# chezterm -- a Wayland terminal emulator written in Chez Scheme.

SCHEME   ?= scheme
C2FFI    ?= c2ffi
# Extra c2ffi options, e.g. `--nostdinc -i DIR ...` where headers are not in /usr/include.
C2FFI_FLAGS ?=
PREFIX   ?= /usr/local
BUILD    := build
FT_INC   ?= $(shell pkg-config --variable=includedir freetype2 2>/dev/null || echo /usr/include)/freetype2
PIXMAN_INC ?= $(shell pkg-config --variable=includedir pixman-1 2>/dev/null || echo /usr/include)/pixman-1

# Shared objects the FFI loads, as SONAME=PATH overrides of the sonames in
# ffi/spec.ss (e.g. libfreetype.so.6=/opt/ft/lib/libfreetype.so.6).  Used by
# `make bindings` and `make relink`; empty means load by soname.
SHARED_OBJECTS ?=
# Directories appended to PATH by the launcher (for xdg-open, say).
RUNTIME_PATH ?=
# ncurses' terminfo compiler; the terminfo entry is skipped without it.
TIC      ?= $(shell command -v tic 2>/dev/null)
TERMINFO_SRC := terminfo/chezterm.terminfo

SRC      := $(wildcard src/chezterm/*.ss) src/main.ss
FFI_LIB  := src/chezterm/ffi.ss
PROTO_LIB := src/chezterm/protocols.ss
PROTOCOLS := protocols/wayland.xml protocols/xdg-shell.xml \
             protocols/xdg-decoration-unstable-v1.xml \
             protocols/primary-selection-unstable-v1.xml \
             protocols/cursor-shape-v1.xml

.PHONY: all bindings protocols relink check-generated run test check clean install terminfo \
        bench bench-quick bench-compare bench-ab

all: $(BUILD)/chezterm terminfo

# The chezterm terminfo entries, compiled into $(BUILD)/terminfo.  The
# launcher passes that directory to chezterm (CHEZTERM_TERMINFO), which then
# sets TERM=chezterm for its programs; see term-setting in src/chezterm/app.ss.
terminfo: $(BUILD)/terminfo/c/chezterm

$(BUILD)/terminfo/c/chezterm: $(TERMINFO_SRC)
ifneq ($(TIC),)
	@mkdir -p $(BUILD)/terminfo
	$(TIC) -x -o $(BUILD)/terminfo $(TERMINFO_SRC)
else
	@echo "tic not found: not compiling the terminfo entry (TERM will be xterm-256color)"
endif

# ---------------------------------------------------------------------------
# FFI bindings: c2ffi -> JSON -> Scheme.  The generated library is committed
# so building does not require c2ffi; `make bindings` regenerates it.

bindings:
	@mkdir -p $(BUILD)
	$(C2FFI) $(C2FFI_FLAGS) -i $(FT_INC) -i $(PIXMAN_INC) --fail-on-error -M $(BUILD)/macros.h \
	    -o $(BUILD)/decls.json ffi/bindings.h
	$(SCHEME) --libdirs tools --script tools/c2ffi-gen.ss macros \
	    ffi/spec.ss $(BUILD)/macros.h $(CURDIR)/ffi/bindings.h $(BUILD)/consts.h
	$(C2FFI) $(C2FFI_FLAGS) -i $(FT_INC) -i $(PIXMAN_INC) --fail-on-error -o $(BUILD)/consts.json $(BUILD)/consts.h
	$(SCHEME) --libdirs tools --script tools/c2ffi-gen.ss library \
	    ffi/spec.ss $(BUILD)/decls.json $(BUILD)/consts.json $(FFI_LIB) $(SHARED_OBJECTS)

# Point the committed bindings at SHARED_OBJECTS without running c2ffi
# (same result as `make bindings SHARED_OBJECTS=...`).
relink:
	$(SCHEME) --libdirs tools --script tools/c2ffi-gen.ss relink \
	    $(FFI_LIB) $(FFI_LIB) $(SHARED_OBJECTS)

# Wayland protocol descriptions: XML -> Scheme (our own wayland-scanner).
protocols:
	$(SCHEME) --libdirs tools --script tools/wl-scanner.ss $(PROTO_LIB) $(PROTOCOLS)

# Regenerate both into $(BUILD)/gen and compare with the committed files.
check-generated:
	@mkdir -p $(BUILD)/gen
	$(MAKE) bindings protocols SHARED_OBJECTS= \
	    FFI_LIB=$(BUILD)/gen/ffi.ss PROTO_LIB=$(BUILD)/gen/protocols.ss
	diff -u $(FFI_LIB) $(BUILD)/gen/ffi.ss
	diff -u $(PROTO_LIB) $(BUILD)/gen/protocols.ss

# ---------------------------------------------------------------------------

# $(call launcher,LIBDIR,PROGRAM) prints the script that runs PROGRAM (main.so).
# $(3) is the directory holding the compiled terminfo entry.
launcher = printf '\#!/bin/sh\nCHEZTERM_EXE="$$0" CHEZTERM_TERMINFO="%s" %sexec %s --libdirs "%s" --program "%s" "$$@"\n' \
	    "$(3)" '$(if $(RUNTIME_PATH),PATH="$$PATH:$(RUNTIME_PATH)" )' "$(SCHEME)" "$(1)" "$(2)"

$(BUILD)/chezterm: $(SRC)
	@mkdir -p $(BUILD)/lib/chezterm
	$(SCHEME) -q --libdirs src::$(BUILD)/lib --script tools/build.ss
	@$(call launcher,$(CURDIR)/$(BUILD)/lib,$(CURDIR)/$(BUILD)/main.so,$(CURDIR)/$(BUILD)/terminfo) > $@
	@chmod +x $@

run: all
	$(BUILD)/chezterm

# The suite runs twice: from source, and against the compiled build.
test: all
	$(SCHEME) -q --libdirs src --script tests/run.ss
	$(SCHEME) -q --libdirs $(BUILD)/lib --script tests/run.ss
	TERMINFO=$(CURDIR)/$(BUILD)/terminfo $(SCHEME) -q --libdirs $(BUILD)/lib --script tests/terminfo.ss

check: test

# Benchmarks (see docs/BENCHMARKS.md).  Results go to $(BENCH_OUT) as JSON;
# pass options with BENCH_ARGS, e.g. BENCH_ARGS="--only parse --iterations 11".
BENCH_OUT  ?= $(BUILD)/bench.json
BENCH_ARGS ?=
bench: all
	$(SCHEME) -q --libdirs $(BUILD)/lib:. --script bench/run.ss --out $(BENCH_OUT) $(BENCH_ARGS)

bench-quick: all
	$(SCHEME) -q --libdirs $(BUILD)/lib:. --script bench/run.ss --quick $(BENCH_ARGS)

# make bench-compare OLD=before.json NEW=after.json
bench-compare:
	$(SCHEME) -q --libdirs tools --script bench/compare.ss $(OLD) $(NEW)

# make bench-ab BASE=<git revision> [BENCH_ARGS="--only render"] [ROUNDS=5]
# Builds BASE in $(BUILD)/base and compares it with the working tree,
# interleaving the runs (bench/ab.sh).  Both sides use this checkout's
# bench/run.ss, so BASE must have the library interfaces it uses.
ROUNDS ?= 5
bench-ab: all
	@test -n "$(BASE)" || { echo "usage: make bench-ab BASE=<git revision>"; exit 2; }
	rm -rf $(BUILD)/base && mkdir -p $(BUILD)/base
	git archive "$(BASE)" | tar -x -C $(BUILD)/base
	$(MAKE) -C $(BUILD)/base SCHEME="$(SCHEME)" TIC=
	sh bench/ab.sh -r $(ROUNDS) -o $(BUILD)/ab -- \
	    "$(SCHEME) -q --libdirs $(BUILD)/base/build/lib:. --script bench/run.ss" \
	    "$(SCHEME) -q --libdirs $(BUILD)/lib:. --script bench/run.ss" $(BENCH_ARGS)

install: all
	install -d $(DESTDIR)$(PREFIX)/lib/chezterm $(DESTDIR)$(PREFIX)/bin
	cp -r $(BUILD)/lib/. $(DESTDIR)$(PREFIX)/lib/chezterm/
	install -m644 $(BUILD)/main.so $(DESTDIR)$(PREFIX)/lib/chezterm/main.so
	$(call launcher,$(PREFIX)/lib/chezterm,$(PREFIX)/lib/chezterm/main.so,$(PREFIX)/share/terminfo) > $(DESTDIR)$(PREFIX)/bin/chezterm
	chmod 755 $(DESTDIR)$(PREFIX)/bin/chezterm
ifneq ($(TIC),)
	install -d $(DESTDIR)$(PREFIX)/share/terminfo
	$(TIC) -x -o $(DESTDIR)$(PREFIX)/share/terminfo $(TERMINFO_SRC)
endif
	install -Dm644 $(TERMINFO_SRC) $(DESTDIR)$(PREFIX)/share/chezterm/chezterm.terminfo
	install -Dm644 chezterm.desktop $(DESTDIR)$(PREFIX)/share/applications/chezterm.desktop
	install -Dm644 chezterm.scm.example $(DESTDIR)$(PREFIX)/share/doc/chezterm/chezterm.scm.example

clean:
	rm -rf $(BUILD)
