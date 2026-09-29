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

SRC      := $(wildcard src/chezterm/*.ss) src/main.ss
FFI_LIB  := src/chezterm/ffi.ss
PROTO_LIB := src/chezterm/protocols.ss
PROTOCOLS := protocols/wayland.xml protocols/xdg-shell.xml \
             protocols/xdg-decoration-unstable-v1.xml \
             protocols/primary-selection-unstable-v1.xml \
             protocols/cursor-shape-v1.xml

.PHONY: all bindings protocols relink check-generated run test check clean install

all: $(BUILD)/chezterm

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
launcher = printf '\#!/bin/sh\nCHEZTERM_EXE="$$0" %sexec %s --libdirs "%s" --program "%s" "$$@"\n' \
	    '$(if $(RUNTIME_PATH),PATH="$$PATH:$(RUNTIME_PATH)" )' "$(SCHEME)" "$(1)" "$(2)"

$(BUILD)/chezterm: $(SRC)
	@mkdir -p $(BUILD)/lib/chezterm
	$(SCHEME) -q --libdirs src::$(BUILD)/lib --script tools/build.ss
	@$(call launcher,$(CURDIR)/$(BUILD)/lib,$(CURDIR)/$(BUILD)/main.so) > $@
	@chmod +x $@

run: all
	$(BUILD)/chezterm

# The suite runs twice: from source with run-time checks, and against the
# optimized build (hot paths at optimize-level 3).
test: all
	$(SCHEME) -q --libdirs src --script tests/run.ss
	$(SCHEME) -q --libdirs $(BUILD)/lib --script tests/run.ss

check: test

install: all
	install -d $(DESTDIR)$(PREFIX)/lib/chezterm $(DESTDIR)$(PREFIX)/bin
	cp -r $(BUILD)/lib/. $(DESTDIR)$(PREFIX)/lib/chezterm/
	install -m644 $(BUILD)/main.so $(DESTDIR)$(PREFIX)/lib/chezterm/main.so
	$(call launcher,$(PREFIX)/lib/chezterm,$(PREFIX)/lib/chezterm/main.so) > $(DESTDIR)$(PREFIX)/bin/chezterm
	chmod 755 $(DESTDIR)$(PREFIX)/bin/chezterm
	install -Dm644 chezterm.desktop $(DESTDIR)$(PREFIX)/share/applications/chezterm.desktop
	install -Dm644 chezterm.scm.example $(DESTDIR)$(PREFIX)/share/doc/chezterm/chezterm.scm.example

clean:
	rm -rf $(BUILD)
