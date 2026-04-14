# C NIF + Rust staticlib build for ex_h3o.
#
# Driven by elixir_make from mix.exs. Two stages:
#
#   1. cargo build --release  -> target/release/libex_h3o_nif.a
#   2. cc -dynamiclib c_src/*  -> ../../priv/ex_h3o_nif.so (links .a)
#
# ERTS include path is discovered at build time from the live Erlang
# installation so this Makefile is not tied to a specific OTP version.

# --- locations -----------------------------------------------------------

PRIV_DIR       := ../../priv
NIF_SO         := $(PRIV_DIR)/ex_h3o_nif.so
C_SOURCE       := c_src/ex_h3o_nif.c
RUST_STATIC    := target/release/libex_h3o_nif.a

ERTS_INCLUDE_DIR := $(shell erl -noinput -eval 'io:format("~s/erts-~s/include", [code:root_dir(), erlang:system_info(version)])' -s init stop)

# --- toolchain -----------------------------------------------------------

CC             ?= cc
CARGO          ?= cargo

CFLAGS          = -O3 -fPIC -Wall -Wextra -I$(ERTS_INCLUDE_DIR)

# Host-specific linker flags. macOS needs -undefined dynamic_lookup to
# defer resolution of enif_* symbols until NIF load time, plus the
# Security and CoreFoundation frameworks for h3o's transitive deps
# (getrandom / ring family). Linux permits undefined symbols in .so
# files by default and doesn't use Apple frameworks.
UNAME_S        := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
    LDFLAGS    = -dynamiclib -undefined dynamic_lookup
    FRAMEWORKS = -framework Security -framework CoreFoundation
else
    LDFLAGS    = -shared
    FRAMEWORKS =
endif

# --- targets -------------------------------------------------------------

.PHONY: all clean rust

all: $(NIF_SO)

rust:
	$(CARGO) build --release --manifest-path Cargo.toml

$(RUST_STATIC): rust

$(NIF_SO): $(C_SOURCE) $(RUST_STATIC) | $(PRIV_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) \
	    -o $(NIF_SO) \
	    $(C_SOURCE) \
	    $(RUST_STATIC) \
	    $(FRAMEWORKS)

$(PRIV_DIR):
	mkdir -p $(PRIV_DIR)

clean:
	$(CARGO) clean --manifest-path Cargo.toml
	rm -f $(NIF_SO)
