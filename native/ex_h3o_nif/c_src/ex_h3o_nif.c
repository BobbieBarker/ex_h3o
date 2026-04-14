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
// Shared helpers: materialize an ExH3oBuf as a BEAM term, freeing the
// Rust-side allocation on the way out (success or failure).
// ===========================================================================
//
// Each helper decodes a packed byte buffer produced by the Rust staticlib
// and constructs a BEAM list in C: boxed u64 cells for grid_disk-style
// ops, 2-tuples for cell/distance pairs, and float 2-tuples for
// coordinate rings. Same allocation shape as erlang-h3's C NIF: N boxed
// terms plus N cons cells on the calling process heap.

// Builds a BEAM list of cell integers (u64) from an ExH3oBuf containing
// packed `<<u64, u64, ...>>` bytes. Used by k_ring, children, compact,
// uncompact, polyfill: all the ops that return cell lists.
static ERL_NIF_TERM
make_cell_list_from_buf(ErlNifEnv *env, ExH3oBuf *buf)
{
    if (buf->len == 0) {
        ex_h3o_buf_free(buf);
        return enif_make_list(env, 0);
    }
    if ((buf->len % 8) != 0) {
        ex_h3o_buf_free(buf);
        return enif_make_badarg(env);
    }

    size_t count = buf->len / 8;
    ERL_NIF_TERM *terms = enif_alloc(count * sizeof(ERL_NIF_TERM));
    if (terms == NULL) {
        ex_h3o_buf_free(buf);
        return enif_raise_exception(env, ATOM_OUT_OF_MEMORY);
    }

    const uint64_t *cells = (const uint64_t *)buf->data;
    for (size_t i = 0; i < count; i++) {
        terms[i] = enif_make_uint64(env, cells[i]);
    }

    ERL_NIF_TERM list = enif_make_list_from_array(env, terms, (unsigned)count);
    enif_free(terms);
    ex_h3o_buf_free(buf);
    return list;
}

// Builds a BEAM list of `{cell, distance}` 2-tuples from an ExH3oBuf
// containing packed `<<u64 cell, u64 distance, ...>>` pairs. Used by
// k_ring_distances.
static ERL_NIF_TERM
make_cell_distance_list_from_buf(ErlNifEnv *env, ExH3oBuf *buf)
{
    if (buf->len == 0) {
        ex_h3o_buf_free(buf);
        return enif_make_list(env, 0);
    }
    if ((buf->len % 16) != 0) {
        ex_h3o_buf_free(buf);
        return enif_make_badarg(env);
    }

    size_t count = buf->len / 16;
    ERL_NIF_TERM *terms = enif_alloc(count * sizeof(ERL_NIF_TERM));
    if (terms == NULL) {
        ex_h3o_buf_free(buf);
        return enif_raise_exception(env, ATOM_OUT_OF_MEMORY);
    }

    const uint64_t *pairs = (const uint64_t *)buf->data;
    for (size_t i = 0; i < count; i++) {
        ERL_NIF_TERM cell = enif_make_uint64(env, pairs[i * 2]);
        ERL_NIF_TERM dist = enif_make_uint64(env, pairs[i * 2 + 1]);
        terms[i] = enif_make_tuple2(env, cell, dist);
    }

    ERL_NIF_TERM list = enif_make_list_from_array(env, terms, (unsigned)count);
    enif_free(terms);
    ex_h3o_buf_free(buf);
    return list;
}

// Builds a BEAM list of `{lat, lng}` float 2-tuples from an ExH3oBuf
// containing packed `<<f64 lat, f64 lng, ...>>` pairs. Used by
// to_geo_boundary.
static ERL_NIF_TERM
make_coord_list_from_buf(ErlNifEnv *env, ExH3oBuf *buf)
{
    if (buf->len == 0) {
        ex_h3o_buf_free(buf);
        return enif_make_list(env, 0);
    }
    if ((buf->len % 16) != 0) {
        ex_h3o_buf_free(buf);
        return enif_make_badarg(env);
    }

    size_t count = buf->len / 16;
    ERL_NIF_TERM *terms = enif_alloc(count * sizeof(ERL_NIF_TERM));
    if (terms == NULL) {
        ex_h3o_buf_free(buf);
        return enif_raise_exception(env, ATOM_OUT_OF_MEMORY);
    }

    const double *pairs = (const double *)buf->data;
    for (size_t i = 0; i < count; i++) {
        ERL_NIF_TERM lat = enif_make_double(env, pairs[i * 2]);
        ERL_NIF_TERM lng = enif_make_double(env, pairs[i * 2 + 1]);
        terms[i] = enif_make_tuple2(env, lat, lng);
    }

    ERL_NIF_TERM list = enif_make_list_from_array(env, terms, (unsigned)count);
    enif_free(terms);
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
// Grid disk family: DirtyCpu
// ===========================================================================

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
