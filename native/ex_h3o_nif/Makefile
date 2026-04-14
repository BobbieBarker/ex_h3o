# C NIF + Rust staticlib build for ex_h3o.
#
# Driven by elixir_make from mix.exs. Two stages:
#
#   1. cargo build --release  -> target/release/libex_h3o_nif.a
#   2. cc -dynamiclib c_src/*  -> $(PRIV_DIR)/ex_h3o_nif.so (links .a)
#
# ERTS include path is discovered at build time from the live Erlang
# installation so this Makefile is not tied to a specific OTP version.
#
# We write the .so into $(MIX_APP_PATH)/priv, not the source-tree
# ../../priv directory. This is the pattern elixir_make documents
# (see compile.elixir_make.ex moduledoc "Working with priv
# directories"): writing to the build-dir priv keeps things working
# under both the `mix compile` symlink path AND the
# `mix elixir_make.precompile` flow, which nukes the build-dir priv
# before running the compile and then archives from it afterward.
# If a source-tree `priv/` ever appeared here, mix would sync it
# into the build dir at compile time and mask precompile breakage.
#
# MIX_APP_PATH is always exported to the Makefile by elixir_make
# (compile.elixir_make.ex moduledoc section "MIX env variables").
# The fallback to ../../priv handles manual `make` invocations from
# this directory with no MIX_APP_PATH set, which is useful for ad
# hoc local debugging.

# --- locations -----------------------------------------------------------

ifdef MIX_APP_PATH
    PRIV_DIR   := $(MIX_APP_PATH)/priv
else
    PRIV_DIR   := ../../priv
endif
NIF_SO         := $(PRIV_DIR)/ex_h3o_nif.so
C_SOURCE       := c_src/ex_h3o_nif.c

# --- target triple handling ----------------------------------------------
#
# When cc_precompiler drives the build it exports
# CC_PRECOMPILER_CURRENT_TARGET as its own triple (e.g.
# "x86_64-linux-gnu"). Translate it to a Rust/cargo target triple
# (which uses "x86_64-unknown-linux-gnu" for the same thing) and
# invoke `cargo build --target=<rust_triple>` so the staticlib
# lands under target/<rust_triple>/release/. Native local dev
# without cc_precompiler uses the host default at target/release/.
#
# The $(error ...) fallback is deliberate: if a new target is
# added to .github/workflows/release.yml without also being added
# to this mapping, the build fails loudly instead of silently
# producing a host-triple build mislabeled as the cc_precompiler
# target.
ifdef CC_PRECOMPILER_CURRENT_TARGET
    ifeq ($(CC_PRECOMPILER_CURRENT_TARGET),aarch64-apple-darwin)
        RUST_TARGET := aarch64-apple-darwin
    else ifeq ($(CC_PRECOMPILER_CURRENT_TARGET),x86_64-apple-darwin)
        RUST_TARGET := x86_64-apple-darwin
    else ifeq ($(CC_PRECOMPILER_CURRENT_TARGET),x86_64-linux-gnu)
        RUST_TARGET := x86_64-unknown-linux-gnu
    else ifeq ($(CC_PRECOMPILER_CURRENT_TARGET),aarch64-linux-gnu)
        RUST_TARGET := aarch64-unknown-linux-gnu
    else ifeq ($(CC_PRECOMPILER_CURRENT_TARGET),x86_64-linux-musl)
        RUST_TARGET := x86_64-unknown-linux-musl
    else ifeq ($(CC_PRECOMPILER_CURRENT_TARGET),aarch64-linux-musl)
        RUST_TARGET := aarch64-unknown-linux-musl
    else
        $(error Unsupported CC_PRECOMPILER_CURRENT_TARGET: $(CC_PRECOMPILER_CURRENT_TARGET))
    endif
    RUST_TARGET_FLAG := --target=$(RUST_TARGET)
    RUST_STATIC      := target/$(RUST_TARGET)/release/libex_h3o_nif.a
else
    RUST_TARGET_FLAG :=
    RUST_STATIC      := target/release/libex_h3o_nif.a
endif

# Rust build driver. Phase 2 cross-compile jobs set
# EX_H3O_USE_ZIGBUILD=1 and install `cargo-zigbuild`, which proxies
# `cargo build` through zig's cross-compile toolchain so musl and
# foreign-arch glibc targets work from a single Ubuntu runner
# without apt cross-compilers. Native builds (and the macOS matrix)
# keep using plain `cargo build`.
#
# Uses recursive (`=`) expansion so $(CARGO) is evaluated at use
# time, AFTER the `CARGO ?= cargo` default below. Immediate
# expansion (`:=`) would resolve $(CARGO) to empty here because
# CARGO hasn't been set yet at this point in the file.
ifeq ($(EX_H3O_USE_ZIGBUILD),1)
    CARGO_SUBCMD = zigbuild
else
    CARGO_SUBCMD = build
endif

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
	$(CARGO) $(CARGO_SUBCMD) --release $(RUST_TARGET_FLAG) --manifest-path Cargo.toml

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
