# chezterm -- a Wayland terminal emulator written in Chez Scheme.

SCHEME   ?= scheme
C2FFI    ?= c2ffi
PREFIX   ?= /usr/local
BUILD    := build
FT_INC   ?= $(shell pkg-config --variable=includedir freetype2 2>/dev/null || echo /usr/include)/freetype2

SRC      := $(wildcard src/chezterm/*.ss) src/main.ss
FFI_LIB  := src/chezterm/ffi.ss
PROTO_LIB := src/chezterm/protocols.ss
PROTOCOLS := protocols/wayland.xml protocols/xdg-shell.xml \
             protocols/xdg-decoration-unstable-v1.xml \
             protocols/primary-selection-unstable-v1.xml \
             protocols/cursor-shape-v1.xml

.PHONY: all bindings protocols run test clean install

all: $(BUILD)/chezterm

# ---------------------------------------------------------------------------
# FFI bindings: c2ffi -> JSON -> Scheme.  The generated library is committed
# so building does not require c2ffi; `make bindings` regenerates it.

bindings:
	@mkdir -p $(BUILD)
	$(C2FFI) -i $(FT_INC) --fail-on-error -M $(BUILD)/macros.h \
	    -o $(BUILD)/decls.json ffi/bindings.h
	$(SCHEME) --libdirs tools --script tools/c2ffi-gen.ss macros \
	    ffi/spec.ss $(BUILD)/macros.h $(CURDIR)/ffi/bindings.h $(BUILD)/consts.h
	$(C2FFI) -i $(FT_INC) --fail-on-error -o $(BUILD)/consts.json $(BUILD)/consts.h
	$(SCHEME) --libdirs tools --script tools/c2ffi-gen.ss library \
	    ffi/spec.ss $(BUILD)/decls.json $(BUILD)/consts.json $(FFI_LIB)

# Wayland protocol descriptions: XML -> Scheme (our own wayland-scanner).
protocols:
	$(SCHEME) --libdirs tools --script tools/wl-scanner.ss $(PROTO_LIB) $(PROTOCOLS)

# ---------------------------------------------------------------------------

$(BUILD)/chezterm: $(SRC)
	@mkdir -p $(BUILD)/lib
	$(SCHEME) -q --libdirs src::$(BUILD)/lib --compile-imported-libraries \
	    --optimize-level 2 < tools/build.ss
	@printf '#!/bin/sh\nexec %s --libdirs "%s" --program "%s" "$$@"\n' \
	    "$(SCHEME)" "$(CURDIR)/src::$(CURDIR)/$(BUILD)/lib" "$(CURDIR)/$(BUILD)/main.so" > $@
	@chmod +x $@

run: all
	$(BUILD)/chezterm

test:
	$(SCHEME) --libdirs src::$(BUILD)/lib --script tests/run.ss

install: all
	install -d $(DESTDIR)$(PREFIX)/lib/chezterm $(DESTDIR)$(PREFIX)/bin
	cp -r $(BUILD)/lib/. $(DESTDIR)$(PREFIX)/lib/chezterm/
	install -m644 $(BUILD)/main.so $(DESTDIR)$(PREFIX)/lib/chezterm/main.so
	printf '#!/bin/sh\nexec %s --libdirs "%s" --program "%s" "$$@"\n' \
	    "$(SCHEME)" "$(PREFIX)/lib/chezterm" "$(PREFIX)/lib/chezterm/main.so" \
	    > $(DESTDIR)$(PREFIX)/bin/chezterm
	chmod 755 $(DESTDIR)$(PREFIX)/bin/chezterm

clean:
	rm -rf $(BUILD)
