// C NIF layer for ex_h3o. Thin translation between BEAM terms and the
// Rust staticlib's extern "C" ABI at src/lib.rs.
//
// This file is deliberately boring: decode args with enif_get_*, call
// into Rust, encode the return with enif_make_*. Every function follows
// one of a handful of templates.
//
// Pattern C error handling: Rust returns non-zero on any failure; we
// translate that directly into enif_make_badarg, which surfaces as
// ArgumentError on the Elixir side. No error atoms propagated; users
// who want soft error handling wrap call sites with try/rescue.
//
// DirtyCpu: 3 ops carry ERL_NIF_DIRTY_JOB_CPU_BOUND in nif_funcs[]:
// compact, uncompact, polyfill. The smaller collection ops (children,
// k_ring, k_ring_distances) run on normal schedulers because the
// dirty-dispatch overhead exceeds their typical per-call work. See
// the nif_funcs[] table at the bottom of this file for the rationale.
//
// OTP 26+ required: the load callback sets ERL_NIF_OPT_DELAY_HALT for
// graceful dirty-NIF shutdown on VM halt. Older OTP versions will fail
// at link time.

#include <erl_nif.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

// ===========================================================================
// Rust FFI declarations: must match native/ex_h3o_nif/src/lib.rs
// ===========================================================================

typedef struct {
    uint8_t *data;
    size_t len;
} ExH3oBuf;

extern void ex_h3o_buf_free(ExH3oBuf *buf);

// Scalar ops
extern bool     ex_h3o_is_valid(uint64_t cell);
extern int32_t  ex_h3o_get_resolution(uint64_t cell, uint8_t *out);
extern int32_t  ex_h3o_get_base_cell(uint64_t cell, uint8_t *out);
extern int32_t  ex_h3o_is_pentagon(uint64_t cell, bool *out);
extern int32_t  ex_h3o_is_class3(uint64_t cell, bool *out);

// Hex string conversion
extern int32_t  ex_h3o_from_string(const uint8_t *data, size_t len, uint64_t *out);
extern int32_t  ex_h3o_to_string(uint64_t cell, uint8_t *out_buf, size_t out_cap, size_t *out_len);

// Geo <-> cell
extern int32_t  ex_h3o_from_geo(double lat, double lng, uint8_t res, uint64_t *out);
extern int32_t  ex_h3o_to_geo(uint64_t cell, double *out_lat, double *out_lng);
extern int32_t  ex_h3o_to_geo_boundary(uint64_t cell, ExH3oBuf *out);

// Hierarchy
extern int32_t  ex_h3o_parent(uint64_t cell, uint8_t res, uint64_t *out);
extern int32_t  ex_h3o_children(uint64_t cell, uint8_t res, ExH3oBuf *out);

// Neighbors / distance / edges
extern int32_t  ex_h3o_indices_are_neighbors(uint64_t a, uint64_t b, bool *out);
extern int32_t  ex_h3o_grid_distance(uint64_t a, uint64_t b, int32_t *out);
extern int32_t  ex_h3o_get_unidirectional_edge(uint64_t origin, uint64_t destination, uint64_t *out);

// Grid disk family
extern int32_t  ex_h3o_k_ring(uint64_t cell, uint32_t k, ExH3oBuf *out);
extern int32_t  ex_h3o_k_ring_distances(uint64_t cell, uint32_t k, ExH3oBuf *out);

// Grid disk family: stack-buffer fast paths. Writes directly into a
// caller-provided u64 array instead of the ExH3oBuf heap contract.
// See the erl_k_ring and erl_k_ring_distances dispatchers below for
// how the small-k fast path is wired.
extern int32_t  ex_h3o_k_ring_into(uint64_t cell, uint32_t k, uint64_t *out_buf, size_t out_cap, size_t *out_len);
extern int32_t  ex_h3o_k_ring_distances_into(uint64_t cell, uint32_t k, uint64_t *out_buf, size_t out_cap, size_t *out_len);

// Compact / uncompact
extern int32_t  ex_h3o_compact(const uint64_t *cells_data, size_t cell_count, ExH3oBuf *out);
extern int32_t  ex_h3o_uncompact(const uint64_t *cells_data, size_t cell_count, uint8_t res, ExH3oBuf *out);

// Polyfill
extern int32_t  ex_h3o_polyfill(const double *coords, size_t vertex_count, uint8_t res, ExH3oBuf *out);

// Bench-only zero-work FFI baseline
extern void     ex_h3o_null_nif(void);

// Test-only
extern void     ex_h3o_dirty_sleep(uint64_t ms);

// ===========================================================================
// Static atom table (pre-created at load time)
// ===========================================================================

static ERL_NIF_TERM ATOM_TRUE;
static ERL_NIF_TERM ATOM_FALSE;
static ERL_NIF_TERM ATOM_OK;
static ERL_NIF_TERM ATOM_OUT_OF_MEMORY;

// ===========================================================================
// Shared helpers: materialize a packed buffer of results as a BEAM list.
// ===========================================================================
//
// Each helper reads a packed buffer of u64 cells (or pairs) and builds a
// BEAM list in C via direct `enif_make_list_cell` cons-cell construction.
// This matches erlang-h3's hot-path pattern and avoids the intermediate
// `enif_alloc(count * sizeof(ERL_NIF_TERM))` / `enif_free` pair that
// `enif_make_list_from_array` requires, which is a meaningful fraction
// of total call cost at small counts (e.g. `k_ring` at k=1).
//
// Two flavors of each helper:
//
//   * `make_*_from_buf`:   takes an owned `ExH3oBuf` (heap-allocated by
//                          the Rust side), reads it, frees it. Used by
//                          ops where the output size isn't bounded in
//                          advance, so the Rust side has to allocate
//                          (polyfill, compact/uncompact, children, and
//                          the k_ring large-k fallback).
//
//   * `make_*_from_u64_array`: takes a raw caller-owned `uint64_t *`
//                              (typically a C-side stack buffer the
//                              caller allocated and is about to drop
//                              when this function returns). Used by
//                              the small-k fast paths in `erl_k_ring`
//                              and `erl_k_ring_distances`, which skip
//                              the Rust-side heap allocation entirely.

// Builds a BEAM list of cell integers (u64) from an ExH3oBuf containing
// packed `<<u64, u64, ...>>` bytes. Used by the `ExH3oBuf` fallback
// path for k_ring, children, compact, uncompact, and polyfill.
static ERL_NIF_TERM
make_cell_list_from_buf(ErlNifEnv *env, ExH3oBuf *buf)
{
    if ((buf->len % 8) != 0) {
        ex_h3o_buf_free(buf);
        return enif_make_badarg(env);
    }

    size_t count = buf->len / 8;
    const uint64_t *cells = (const uint64_t *)buf->data;

    // Cons from the tail so the final list order matches the input.
    ERL_NIF_TERM list = enif_make_list(env, 0);
    for (size_t i = count; i-- > 0; ) {
        list = enif_make_list_cell(env, enif_make_uint64(env, cells[i]), list);
    }

    ex_h3o_buf_free(buf);
    return list;
}

// Builds a BEAM list of cell integers from a caller-owned `uint64_t`
// array. Used by the stack-buffer fast path in `erl_k_ring` to skip
// the `ExH3oBuf` heap contract for small k.
static ERL_NIF_TERM
make_cell_list_from_u64_array(ErlNifEnv *env, const uint64_t *cells, size_t count)
{
    ERL_NIF_TERM list = enif_make_list(env, 0);
    for (size_t i = count; i-- > 0; ) {
        list = enif_make_list_cell(env, enif_make_uint64(env, cells[i]), list);
    }
    return list;
}

// Builds a BEAM list of `{cell, distance}` 2-tuples from an ExH3oBuf
// containing packed `<<u64 cell, u64 distance, ...>>` pairs. Used by
// the large-k fallback in `erl_k_ring_distances`.
static ERL_NIF_TERM
make_cell_distance_list_from_buf(ErlNifEnv *env, ExH3oBuf *buf)
{
    if ((buf->len % 16) != 0) {
        ex_h3o_buf_free(buf);
        return enif_make_badarg(env);
    }

    size_t count = buf->len / 16;
    const uint64_t *pairs = (const uint64_t *)buf->data;

    ERL_NIF_TERM list = enif_make_list(env, 0);
    for (size_t i = count; i-- > 0; ) {
        ERL_NIF_TERM cell = enif_make_uint64(env, pairs[i * 2]);
        ERL_NIF_TERM dist = enif_make_uint64(env, pairs[i * 2 + 1]);
        list = enif_make_list_cell(env, enif_make_tuple2(env, cell, dist), list);
    }

    ex_h3o_buf_free(buf);
    return list;
}

// Builds a BEAM list of `{cell, distance}` 2-tuples from a caller-owned
// interleaved `uint64_t` array (`[cell, distance, cell, distance, ...]`).
// `pair_count` is the number of pairs, so the array length in u64
// elements is `pair_count * 2`. Used by the stack-buffer fast path in
// `erl_k_ring_distances`.
static ERL_NIF_TERM
make_cell_distance_list_from_u64_array(ErlNifEnv *env, const uint64_t *pairs, size_t pair_count)
{
    ERL_NIF_TERM list = enif_make_list(env, 0);
    for (size_t i = pair_count; i-- > 0; ) {
        ERL_NIF_TERM cell = enif_make_uint64(env, pairs[i * 2]);
        ERL_NIF_TERM dist = enif_make_uint64(env, pairs[i * 2 + 1]);
        list = enif_make_list_cell(env, enif_make_tuple2(env, cell, dist), list);
    }
    return list;
}

// Builds a BEAM list of `{lat, lng}` float 2-tuples from an ExH3oBuf
// containing packed `<<f64 lat, f64 lng, ...>>` pairs. Used by
// to_geo_boundary.
static ERL_NIF_TERM
make_coord_list_from_buf(ErlNifEnv *env, ExH3oBuf *buf)
{
    if ((buf->len % 16) != 0) {
        ex_h3o_buf_free(buf);
        return enif_make_badarg(env);
    }

    size_t count = buf->len / 16;
    const double *pairs = (const double *)buf->data;

    ERL_NIF_TERM list = enif_make_list(env, 0);
    for (size_t i = count; i-- > 0; ) {
        ERL_NIF_TERM lat = enif_make_double(env, pairs[i * 2]);
        ERL_NIF_TERM lng = enif_make_double(env, pairs[i * 2 + 1]);
        list = enif_make_list_cell(env, enif_make_tuple2(env, lat, lng), list);
    }

    ex_h3o_buf_free(buf);
    return list;
}

// ===========================================================================
// Single-cell scalar NIFs
// ===========================================================================

static ERL_NIF_TERM
erl_is_valid(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    uint64_t cell;
    if (!enif_get_uint64(env, argv[0], (unsigned long *)&cell)) {
        return enif_make_badarg(env);
    }
    return ex_h3o_is_valid(cell) ? ATOM_TRUE : ATOM_FALSE;
}

static ERL_NIF_TERM
erl_get_resolution(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    uint64_t cell;
    if (!enif_get_uint64(env, argv[0], (unsigned long *)&cell)) {
        return enif_make_badarg(env);
    }
    uint8_t res;
    if (ex_h3o_get_resolution(cell, &res) != 0) {
        return enif_make_badarg(env);
    }
    return enif_make_uint(env, (unsigned int)res);
}

static ERL_NIF_TERM
erl_get_base_cell(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    uint64_t cell;
    if (!enif_get_uint64(env, argv[0], (unsigned long *)&cell)) {
        return enif_make_badarg(env);
    }
    uint8_t base;
    if (ex_h3o_get_base_cell(cell, &base) != 0) {
        return enif_make_badarg(env);
    }
    return enif_make_uint(env, (unsigned int)base);
}

static ERL_NIF_TERM
erl_is_pentagon(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    uint64_t cell;
    if (!enif_get_uint64(env, argv[0], (unsigned long *)&cell)) {
        return enif_make_badarg(env);
    }
    bool result;
    if (ex_h3o_is_pentagon(cell, &result) != 0) {
        return enif_make_badarg(env);
    }
    return result ? ATOM_TRUE : ATOM_FALSE;
}

static ERL_NIF_TERM
erl_is_class3(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    uint64_t cell;
    if (!enif_get_uint64(env, argv[0], (unsigned long *)&cell)) {
        return enif_make_badarg(env);
    }
    bool result;
    if (ex_h3o_is_class3(cell, &result) != 0) {
        return enif_make_badarg(env);
    }
    return result ? ATOM_TRUE : ATOM_FALSE;
}

// ===========================================================================
// Hex string conversion
// ===========================================================================

static ERL_NIF_TERM
erl_from_string(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin)) {
        return enif_make_badarg(env);
    }
    uint64_t cell;
    if (ex_h3o_from_string(bin.data, bin.size, &cell) != 0) {
        return enif_make_badarg(env);
    }
    return enif_make_uint64(env, cell);
}

static ERL_NIF_TERM
erl_to_string(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    uint64_t cell;
    if (!enif_get_uint64(env, argv[0], (unsigned long *)&cell)) {
        return enif_make_badarg(env);
    }
    // H3 cells are at most 16 hex digits; 17 gives us a byte of slack.
    uint8_t buf[17];
    size_t len = 0;
    if (ex_h3o_to_string(cell, buf, sizeof(buf), &len) != 0) {
        return enif_make_badarg(env);
    }
    ErlNifBinary out;
    if (!enif_alloc_binary(len, &out)) {
        return enif_raise_exception(env, ATOM_OUT_OF_MEMORY);
    }
    memcpy(out.data, buf, len);
    return enif_make_binary(env, &out);
}

// ===========================================================================
// Geo <-> cell conversion
// ===========================================================================

static ERL_NIF_TERM
erl_from_geo(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    double lat, lng;
    unsigned int res;
    if (!enif_get_double(env, argv[0], &lat) ||
        !enif_get_double(env, argv[1], &lng) ||
        !enif_get_uint(env, argv[2], &res) ||
        res > 15) {
        return enif_make_badarg(env);
    }
    uint64_t cell;
    if (ex_h3o_from_geo(lat, lng, (uint8_t)res, &cell) != 0) {
        return enif_make_badarg(env);
    }
    return enif_make_uint64(env, cell);
}

static ERL_NIF_TERM
erl_to_geo(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    uint64_t cell;
    if (!enif_get_uint64(env, argv[0], (unsigned long *)&cell)) {
        return enif_make_badarg(env);
    }
    double lat, lng;
    if (ex_h3o_to_geo(cell, &lat, &lng) != 0) {
        return enif_make_badarg(env);
    }
    return enif_make_tuple2(env,
        enif_make_double(env, lat),
        enif_make_double(env, lng));
}

static ERL_NIF_TERM
erl_to_geo_boundary(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    uint64_t cell;
    if (!enif_get_uint64(env, argv[0], (unsigned long *)&cell)) {
        return enif_make_badarg(env);
    }
    ExH3oBuf buf = {0};
    if (ex_h3o_to_geo_boundary(cell, &buf) != 0) {
        ex_h3o_buf_free(&buf);
        return enif_make_badarg(env);
    }
    return make_coord_list_from_buf(env, &buf);
}

// ===========================================================================
// Hierarchy
// ===========================================================================

static ERL_NIF_TERM
erl_parent(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    uint64_t cell;
    unsigned int res;
    if (!enif_get_uint64(env, argv[0], (unsigned long *)&cell) ||
        !enif_get_uint(env, argv[1], &res) ||
        res > 15) {
        return enif_make_badarg(env);
    }
    uint64_t parent;
    if (ex_h3o_parent(cell, (uint8_t)res, &parent) != 0) {
        return enif_make_badarg(env);
    }
    return enif_make_uint64(env, parent);
}

static ERL_NIF_TERM
erl_children(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    uint64_t cell;
    unsigned int res;
    if (!enif_get_uint64(env, argv[0], (unsigned long *)&cell) ||
        !enif_get_uint(env, argv[1], &res) ||
        res > 15) {
        return enif_make_badarg(env);
    }
    ExH3oBuf buf = {0};
    if (ex_h3o_children(cell, (uint8_t)res, &buf) != 0) {
        ex_h3o_buf_free(&buf);
        return enif_make_badarg(env);
    }
    return make_cell_list_from_buf(env, &buf);
}

// ===========================================================================
// Neighbors / distance / edges
// ===========================================================================

static ERL_NIF_TERM
erl_indices_are_neighbors(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    uint64_t a, b;
    if (!enif_get_uint64(env, argv[0], (unsigned long *)&a) ||
        !enif_get_uint64(env, argv[1], (unsigned long *)&b)) {
        return enif_make_badarg(env);
    }
    bool result;
    if (ex_h3o_indices_are_neighbors(a, b, &result) != 0) {
        return enif_make_badarg(env);
    }
    return result ? ATOM_TRUE : ATOM_FALSE;
}

static ERL_NIF_TERM
erl_grid_distance(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    uint64_t a, b;
    if (!enif_get_uint64(env, argv[0], (unsigned long *)&a) ||
        !enif_get_uint64(env, argv[1], (unsigned long *)&b)) {
        return enif_make_badarg(env);
    }
    int32_t dist;
    if (ex_h3o_grid_distance(a, b, &dist) != 0) {
        return enif_make_badarg(env);
    }
    return enif_make_int(env, (int)dist);
}

static ERL_NIF_TERM
erl_get_unidirectional_edge(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    uint64_t origin, destination;
    if (!enif_get_uint64(env, argv[0], (unsigned long *)&origin) ||
        !enif_get_uint64(env, argv[1], (unsigned long *)&destination)) {
        return enif_make_badarg(env);
    }
    uint64_t edge;
    if (ex_h3o_get_unidirectional_edge(origin, destination, &edge) != 0) {
        return enif_make_badarg(env);
    }
    return enif_make_uint64(env, edge);
}

// ===========================================================================
// Grid disk family
// ===========================================================================
//
// Both `k_ring` and `k_ring_distances` implement a stack-buffer fast
// path for small k that skips the `ExH3oBuf` heap roundtrip entirely.
// The Rust staticlib writes cells directly into a caller-owned C
// stack buffer via `ex_h3o_k_ring_into` / `ex_h3o_k_ring_distances_into`,
// and the BEAM list is cons'd from that buffer without going through
// `enif_alloc_binary` + `memcpy` + `ex_h3o_buf_free`.
//
// For small k the fixed overhead of the heap path dominates total
// cost (at k=1 with 7 cells the packed-binary dance accounts for
// more than the actual h3o work), so the fast path is a meaningful
// win on exactly the workloads most applications hit. Above the
// stack threshold the heap `ExH3oBuf` path is strictly better
// because the stack buffer would be oversized.

// Stack buffer sized for k up to 12 (k=12 gives 3*144 + 36 + 1 = 469
// cells, comfortably under 512). 512 u64 entries = 4 KB on the stack,
// well within safe usage on BEAM dirty CPU scheduler threads (default
// OS thread stacks are MB-scale). Picked to cover the common
// "k_ring at k <= 10" workload with margin.
#define EX_H3O_KRING_STACK_CAP 512

// Two u64s per pair, so 512 pairs = 1024 u64 entries = 8 KB. Same
// k<=12 threshold as k_ring_stack_cap above (k=12 gives 469 pairs).
#define EX_H3O_KRING_DISTANCES_STACK_CAP 1024

static ERL_NIF_TERM
erl_k_ring(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    uint64_t cell;
    unsigned int k;
    if (!enif_get_uint64(env, argv[0], (unsigned long *)&cell) ||
        !enif_get_uint(env, argv[1], &k)) {
        return enif_make_badarg(env);
    }

    // H3 max-k-ring formula: 3k² + 3k + 1. When the output fits in
    // our stack buffer, call the `_into` FFI and build the BEAM list
    // directly from the stack bytes. Skips the ExH3oBuf / memcpy /
    // ex_h3o_buf_free sequence.
    size_t expected = (size_t)(3u * k * k) + (size_t)(3u * k) + 1u;
    if (expected <= EX_H3O_KRING_STACK_CAP) {
        uint64_t stack_buf[EX_H3O_KRING_STACK_CAP];
        size_t out_len = 0;
        if (ex_h3o_k_ring_into(cell, (uint32_t)k, stack_buf, EX_H3O_KRING_STACK_CAP, &out_len) != 0) {
            return enif_make_badarg(env);
        }
        return make_cell_list_from_u64_array(env, stack_buf, out_len);
    }

    // Large-k fallback: heap-allocated ExH3oBuf path.
    ExH3oBuf buf = {0};
    if (ex_h3o_k_ring(cell, (uint32_t)k, &buf) != 0) {
        ex_h3o_buf_free(&buf);
        return enif_make_badarg(env);
    }
    return make_cell_list_from_buf(env, &buf);
}

static ERL_NIF_TERM
erl_k_ring_distances(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    uint64_t cell;
    unsigned int k;
    if (!enif_get_uint64(env, argv[0], (unsigned long *)&cell) ||
        !enif_get_uint(env, argv[1], &k)) {
        return enif_make_badarg(env);
    }

    // 2 u64 elements per pair (cell + distance), so the stack cap in
    // elements is `pair_cap * 2`. Pair count bounded by the same
    // max-k-ring formula as k_ring.
    size_t expected_pairs = (size_t)(3u * k * k) + (size_t)(3u * k) + 1u;
    if (expected_pairs * 2 <= EX_H3O_KRING_DISTANCES_STACK_CAP) {
        uint64_t stack_buf[EX_H3O_KRING_DISTANCES_STACK_CAP];
        size_t out_len = 0;
        if (ex_h3o_k_ring_distances_into(
                cell, (uint32_t)k, stack_buf, EX_H3O_KRING_DISTANCES_STACK_CAP, &out_len) != 0) {
            return enif_make_badarg(env);
        }
        return make_cell_distance_list_from_u64_array(env, stack_buf, out_len / 2);
    }

    // Large-k fallback: heap-allocated ExH3oBuf path.
    ExH3oBuf buf = {0};
    if (ex_h3o_k_ring_distances(cell, (uint32_t)k, &buf) != 0) {
        ex_h3o_buf_free(&buf);
        return enif_make_badarg(env);
    }
    return make_cell_distance_list_from_buf(env, &buf);
}

// ===========================================================================
// Compact / uncompact: DirtyCpu
// ===========================================================================

static ERL_NIF_TERM
erl_compact(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    ErlNifBinary in;
    if (!enif_inspect_binary(env, argv[0], &in) || (in.size % 8) != 0) {
        return enif_make_badarg(env);
    }
    ExH3oBuf buf = {0};
    // BEAM binaries are naturally 8-byte-aligned for our purposes; the
    // cast to (const uint64_t*) is safe.
    int32_t rc = ex_h3o_compact((const uint64_t *)in.data, in.size / 8, &buf);
    if (rc != 0) {
        ex_h3o_buf_free(&buf);
        return enif_make_badarg(env);
    }
    return make_cell_list_from_buf(env, &buf);
}

static ERL_NIF_TERM
erl_uncompact(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    ErlNifBinary in;
    unsigned int res;
    if (!enif_inspect_binary(env, argv[0], &in) || (in.size % 8) != 0 ||
        !enif_get_uint(env, argv[1], &res) ||
        res > 15) {
        return enif_make_badarg(env);
    }
    ExH3oBuf buf = {0};
    int32_t rc = ex_h3o_uncompact(
        (const uint64_t *)in.data, in.size / 8, (uint8_t)res, &buf);
    if (rc != 0) {
        ex_h3o_buf_free(&buf);
        return enif_make_badarg(env);
    }
    return make_cell_list_from_buf(env, &buf);
}

// ===========================================================================
// Polyfill: DirtyCpu
//
// The Elixir wrapper packs vertices into a `<<lat::float-64-native,
// lng::float-64-native, ...>>` binary via pack_coords/1. We inspect
// the binary, validate the byte length is a multiple of 16 (each
// vertex is 2x f64 = 16 bytes), and pass the raw pointer + vertex
// count to Rust. No list walking inside the dirty NIF body, no
// interleave buffer allocation, no per-vertex term decoding.
//
// Packing happens on the calling process's normal scheduler before
// the dirty dispatch, keeping the dirty thread free of per-term decode
// work. Same input-binary pattern as compact/uncompact.
// ===========================================================================

static ERL_NIF_TERM
erl_polyfill(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;

    ErlNifBinary in;
    unsigned int res;
    if (!enif_inspect_binary(env, argv[0], &in) ||
        (in.size % 16) != 0 ||
        in.size < 48 ||  // minimum 3 vertices = 48 bytes
        !enif_get_uint(env, argv[1], &res) ||
        res > 15) {
        return enif_make_badarg(env);
    }

    size_t vertex_count = in.size / 16;
    ExH3oBuf buf = {0};
    int32_t rc = ex_h3o_polyfill((const double *)in.data, vertex_count, (uint8_t)res, &buf);
    if (rc != 0) {
        ex_h3o_buf_free(&buf);
        return enif_make_badarg(env);
    }
    return make_cell_list_from_buf(env, &buf);
}

// ===========================================================================
// Bench-only: null_nif and null_nif_dirty
//
// Both call the same empty Rust function. Only the scheduler flag in
// the nif_funcs[] table differs. Together they let a benchmark measure
// the BEAM's dirty-CPU dispatch overhead in isolation from any actual
// algorithm work: subtract null_nif from null_nif_dirty timings to get
// the per-call dirty-dispatch cost.
// ===========================================================================

static ERL_NIF_TERM
erl_null_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)env;
    (void)argc;
    (void)argv;
    ex_h3o_null_nif();
    return ATOM_OK;
}

static ERL_NIF_TERM
erl_null_nif_dirty(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)env;
    (void)argc;
    (void)argv;
    ex_h3o_null_nif();
    return ATOM_OK;
}

// ===========================================================================
// Test-only: dirty_sleep
// ===========================================================================

static ERL_NIF_TERM
erl_dirty_sleep(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    unsigned long ms;
    if (!enif_get_ulong(env, argv[0], &ms)) {
        return enif_make_badarg(env);
    }
    ex_h3o_dirty_sleep((uint64_t)ms);
    return ATOM_OK;
}

// ===========================================================================
// Load callback: atom table + ERL_NIF_OPT_DELAY_HALT
// ===========================================================================

static int
load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info)
{
    (void)priv_data;
    (void)load_info;

    ATOM_TRUE          = enif_make_atom(env, "true");
    ATOM_FALSE         = enif_make_atom(env, "false");
    ATOM_OK            = enif_make_atom(env, "ok");
    ATOM_OUT_OF_MEMORY = enif_make_atom(env, "out_of_memory");

    // OTP 26+: request graceful dirty-NIF shutdown. Best-effort: log
    // on failure but don't block the NIF load, since the NIF is still
    // usable without it (the VM will just halt less gracefully on
    // Ctrl+C during heavy dirty-NIF load).
    int rc = enif_set_option(env, ERL_NIF_OPT_DELAY_HALT);
    if (rc != 0) {
        fprintf(stderr,
            "ex_h3o: enif_set_option(ERL_NIF_OPT_DELAY_HALT) failed (rc=%d). "
            "Dirty NIFs may not complete gracefully on VM shutdown. "
            "Requires OTP 26.0+.\n",
            rc);
    }

    return 0;
}

// ===========================================================================
// NIF function table
//
// Fourth field is the flags: 0 = normal scheduler,
// ERL_NIF_DIRTY_JOB_CPU_BOUND = runs on dirty CPU scheduler threads.
// ===========================================================================

static ErlNifFunc nif_funcs[] = {
    // Scalar ops (normal scheduler)
    {"is_valid",                  1, erl_is_valid,                  0},
    {"get_resolution",            1, erl_get_resolution,            0},
    {"get_base_cell",             1, erl_get_base_cell,             0},
    {"is_pentagon",               1, erl_is_pentagon,               0},
    {"is_class3",                 1, erl_is_class3,                 0},
    {"from_string",               1, erl_from_string,               0},
    {"to_string",                 1, erl_to_string,                 0},
    {"parent",                    2, erl_parent,                    0},
    {"from_geo",                  3, erl_from_geo,                  0},
    {"to_geo",                    1, erl_to_geo,                    0},
    {"to_geo_boundary",           1, erl_to_geo_boundary,           0},
    {"indices_are_neighbors",     2, erl_indices_are_neighbors,     0},
    {"grid_distance",             2, erl_grid_distance,             0},
    {"get_unidirectional_edge",   2, erl_get_unidirectional_edge,   0},

    // Collection-returning ops.
    //
    // Scheduler choice matches erlang-h3's nif_funcs[] verbatim. Dirty
    // CPU dispatch costs ~1-2 µs of fixed overhead per call (state copy
    // + thread switch); for sub-µs operations like k_ring at small k,
    // that overhead exceeds the actual algorithm work. Ops below
    // BEAM's 1ms "should be dirty" threshold therefore run on normal
    // schedulers.
    //
    //   normal scheduler (fast path, sub-ms work):
    //     - children:         small/medium descents are fast
    //     - k_ring:           always normal in erlang-h3, regardless of k
    //     - k_ring_distances: same
    //
    //   dirty CPU scheduler (slow path, can exceed 1ms):
    //     - compact/uncompact: input list size is unbounded
    //     - polyfill:          polygon area is unbounded
    {"children",                  2, erl_children,                  0},
    {"k_ring",                    2, erl_k_ring,                    0},
    {"k_ring_distances",          2, erl_k_ring_distances,          0},
    {"compact",                   1, erl_compact,                   ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"uncompact",                 2, erl_uncompact,                 ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"polyfill",                  2, erl_polyfill,                  ERL_NIF_DIRTY_JOB_CPU_BOUND},

    // Bench-only zero-work FFI baselines. null_nif on the normal
    // scheduler matches the dispatch path of all the scalar ops;
    // null_nif_dirty on the dirty CPU scheduler matches polyfill /
    // compact / uncompact. Subtract one from the other for the
    // dirty-dispatch overhead in isolation.
    {"null_nif",                  0, erl_null_nif,                  0},
    {"null_nif_dirty",            0, erl_null_nif_dirty,            ERL_NIF_DIRTY_JOB_CPU_BOUND},

    // Test-only (dirty CPU so it exercises the graceful-shutdown path)
    {"dirty_sleep",               1, erl_dirty_sleep,               ERL_NIF_DIRTY_JOB_CPU_BOUND},
};

ERL_NIF_INIT(Elixir.ExH3o.Native, nif_funcs, load, NULL, NULL, NULL);
