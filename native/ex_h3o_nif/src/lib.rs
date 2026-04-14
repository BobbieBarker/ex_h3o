//! FFI layer exposing `h3o` to the C NIF via a stable `extern "C"` ABI.
//!
//! This crate never imports `erl_nif.h` or touches BEAM types. The C NIF
//! at `c_src/ex_h3o_nif.c` owns that side of the boundary. All Rust
//! functions here take scalar args and out-params, return an `i32` status
//! (0 = ok, non-zero = error), and wrap every body in `catch_unwind` so
//! Rust panics cannot cross the `extern "C"` boundary.
//!
//! ## Binary ownership model
//!
//! Variable-length outputs (k_ring, children, polyfill, etc.) use the
//! `ExH3oBuf` struct: Rust allocates a `Box<[u8]>`, transfers ownership
//! to the C caller by stashing a raw pointer + length in `*out`, and
//! the C caller MUST call `ex_h3o_buf_free` exactly once to release it.
//! `ex_h3o_buf_free` is idempotent and double-free safe; it zeroes out
//! the struct after dropping, so a second call is a no-op.
//!
//! ## Error handling
//!
//! All fallible functions return `i32`:
//!   * `0` = success, out-params populated
//!   * non-zero = error, out-params unspecified
//!
//! The C NIF translates non-zero returns into `enif_make_badarg` so users
//! see `ArgumentError` on the Elixir side. There is no information loss
//! worth preserving; every error is a programming error or user-data
//! bug, which is exactly what badarg is for.
//!
//! ## Safety conventions
//!
//! Every `unsafe fn` body uses explicit `unsafe { ... }` blocks around
//! the individual unsafe operations, each annotated with a `SAFETY:`
//! comment describing which caller invariant justifies the operation.
//! This is enforced crate-wide via `#![deny(unsafe_op_in_unsafe_fn)]`
//! so the pattern cannot regress.

#![deny(unsafe_op_in_unsafe_fn)]

use std::panic::{catch_unwind, AssertUnwindSafe};

use h3o::{geom, CellIndex, LatLng, Resolution};

// ===========================================================================
// ExH3oBuf: variable-length binary output ownership
// ===========================================================================

/// Heap-allocated byte buffer owned by Rust but exposed to C via raw
/// pointer + length. The caller MUST invoke `ex_h3o_buf_free` exactly
/// once on every non-null `data` pointer returned by an FFI function.
///
/// `#[repr(C)]` guarantees layout compatibility with the matching C
/// struct declared in `c_src/ex_h3o_nif.c`.
#[repr(C)]
pub struct ExH3oBuf {
    pub data: *mut u8,
    pub len: usize,
}

impl ExH3oBuf {
    /// Zero value representing "no buffer allocated".
    const EMPTY: Self = Self {
        data: std::ptr::null_mut(),
        len: 0,
    };
}

/// Transfers ownership of `bytes` into the `ExH3oBuf` out-param.
///
/// # Safety
///
/// `out` must be a valid, writable `*mut ExH3oBuf`. The caller takes
/// ownership of the underlying `Box<[u8]>` allocation and must release
/// it via `ex_h3o_buf_free`.
unsafe fn put_buf(out: *mut ExH3oBuf, bytes: Vec<u8>) {
    let boxed = bytes.into_boxed_slice();
    let len = boxed.len();
    // `Box::into_raw` on `Box<[u8]>` returns a fat pointer to a slice;
    // casting to `*mut u8` strips the length field to give us the raw
    // data pointer, which matches the data/len layout in `ExH3oBuf`.
    let data = Box::into_raw(boxed) as *mut u8;
    // SAFETY: caller contract requires `out` to be a valid, writable
    // `*mut ExH3oBuf`. The scalar field writes below do not run any
    // destructor (both fields are trivially copyable).
    unsafe {
        (*out).data = data;
        (*out).len = len;
    }
}

/// Frees a buffer previously transferred to C via an FFI function.
/// Idempotent + double-free safe: zeroes out the struct after dropping
/// so repeated calls are no-ops.
///
/// # Safety
///
/// `buf` must either be null or point to a valid `ExH3oBuf` previously
/// populated by an FFI function in this crate.
#[no_mangle]
pub unsafe extern "C" fn ex_h3o_buf_free(buf: *mut ExH3oBuf) {
    // `catch_unwind` is defensive: dropping a `Box<[u8]>` cannot panic
    // under the global allocator, but no panic is ever allowed to cross
    // an `extern "C"` boundary so we wrap anyway.
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if buf.is_null() {
            return;
        }
        // SAFETY: `buf` is non-null and the caller guarantees it points
        // at a valid `ExH3oBuf` produced by this crate. Reading the
        // two scalar fields cannot trigger any destructor.
        let (data, len) = unsafe { ((*buf).data, (*buf).len) };
        if data.is_null() {
            return;
        }
        // SAFETY: `data`/`len` were produced by `put_buf` via
        // `Box::into_raw` on a `Box<[u8]>`. Rebuilding the fat raw
        // pointer via `ptr::slice_from_raw_parts_mut` and feeding it
        // back to `Box::from_raw` drops the original allocation
        // exactly once. We deliberately do NOT build a `&mut [u8]`
        // first — that would briefly create a reference to memory
        // we're immediately taking ownership of.
        let fat = std::ptr::slice_from_raw_parts_mut(data, len);
        let _ = unsafe { Box::from_raw(fat) };
        // SAFETY: same validity as the read above; we zero out the
        // fields so a subsequent call on the same `ExH3oBuf` takes
        // the early-return null branch.
        unsafe {
            (*buf).data = std::ptr::null_mut();
            (*buf).len = 0;
        }
    }));
}

// ===========================================================================
// Shared helper
// ===========================================================================

/// Wraps a fallible closure in `catch_unwind` and maps the result to
/// the C-side status convention: `0` on `Some(())`, `1` on `None` or
/// panic. Used by every FFI function whose success is communicated via
/// an out-param rather than a return value.
fn try_call<F: FnOnce() -> Option<()>>(f: F) -> i32 {
    catch_unwind(AssertUnwindSafe(f))
        .ok()
        .flatten()
        .map(|()| 0)
        .unwrap_or(1)
}

// ===========================================================================
// Single-cell scalar operations
// ===========================================================================

/// Returns `true` if `cell` is a valid H3 index. Never errors (an
/// invalid input just returns `false`), so this uses a bare `bool`
/// return instead of the `i32`-status convention.
#[no_mangle]
pub extern "C" fn ex_h3o_is_valid(cell: u64) -> bool {
    catch_unwind(AssertUnwindSafe(|| CellIndex::try_from(cell).is_ok()))
        .unwrap_or(false)
}

/// Writes the resolution of `cell` into `*out`. Returns 0 on success,
/// 1 if `cell` is not a valid H3 index.
///
/// # Safety
///
/// `out` must be a valid, writable `*mut u8`.
#[no_mangle]
pub unsafe extern "C" fn ex_h3o_get_resolution(cell: u64, out: *mut u8) -> i32 {
    try_call(|| {
        let cell = CellIndex::try_from(cell).ok()?;
        // SAFETY: caller contract requires `out` to be valid and writable.
        unsafe { *out = u8::from(cell.resolution()) };
        Some(())
    })
}

/// Writes the base cell number (0..121) into `*out`.
///
/// # Safety
///
/// `out` must be a valid, writable `*mut u8`.
#[no_mangle]
pub unsafe extern "C" fn ex_h3o_get_base_cell(cell: u64, out: *mut u8) -> i32 {
    try_call(|| {
        let cell = CellIndex::try_from(cell).ok()?;
        // SAFETY: caller contract requires `out` to be valid and writable.
        unsafe { *out = u8::from(cell.base_cell()) };
        Some(())
    })
}

/// Writes `true` or `false` into `*out` depending on whether `cell` is
/// a pentagon.
///
/// # Safety
///
/// `out` must be a valid, writable `*mut bool`.
#[no_mangle]
pub unsafe extern "C" fn ex_h3o_is_pentagon(cell: u64, out: *mut bool) -> i32 {
    try_call(|| {
        let cell = CellIndex::try_from(cell).ok()?;
        // SAFETY: caller contract requires `out` to be valid and writable.
        unsafe { *out = cell.is_pentagon() };
        Some(())
    })
}

/// Writes whether `cell`'s resolution is a Class III grid.
///
/// # Safety
///
/// `out` must be a valid, writable `*mut bool`.
#[no_mangle]
pub unsafe extern "C" fn ex_h3o_is_class3(cell: u64, out: *mut bool) -> i32 {
    try_call(|| {
        let cell = CellIndex::try_from(cell).ok()?;
        // SAFETY: caller contract requires `out` to be valid and writable.
        unsafe { *out = cell.resolution().is_class3() };
        Some(())
    })
}

// ===========================================================================
// Hex string <-> cell conversion
// ===========================================================================

/// Parses a hex string (with or without `0x` prefix) into an H3 cell.
/// The input is an arbitrary byte slice; the C NIF passes the raw
/// bytes of an Elixir binary directly.
///
/// # Safety
///
/// `data` must be valid for reads of `len` bytes. `out` must be a
/// valid, writable `*mut u64`.
#[no_mangle]
pub unsafe extern "C" fn ex_h3o_from_string(
    data: *const u8,
    len: usize,
    out: *mut u64,
) -> i32 {
    try_call(|| {
        // SAFETY: caller guarantees `data` is valid for `len` bytes.
        let slice = unsafe { std::slice::from_raw_parts(data, len) };
        let s = std::str::from_utf8(slice).ok()?;
        let hex = s.trim_start_matches("0x");
        let value = u64::from_str_radix(hex, 16).ok()?;
        // Validate that the value is actually a well-formed H3 cell.
        CellIndex::try_from(value).ok()?;
        // SAFETY: caller contract requires `out` to be valid and writable.
        unsafe { *out = value };
        Some(())
    })
}

/// Formats a cell index as a lowercase hex string into `out_buf`.
///
/// H3 cell strings are at most 16 hex digits; the C caller should
/// supply a buffer of at least 17 bytes (including a byte of slack).
/// On success, `*out_len` holds the number of bytes written (no NUL
/// terminator is appended; the caller treats the buffer as a
/// length-prefixed byte slice).
///
/// # Safety
///
/// `out_buf` must be valid for `out_cap` writable bytes. `out_len`
/// must be a valid, writable `*mut usize`.
#[no_mangle]
pub unsafe extern "C" fn ex_h3o_to_string(
    cell: u64,
    out_buf: *mut u8,
    out_cap: usize,
    out_len: *mut usize,
) -> i32 {
    try_call(|| {
        let cell = CellIndex::try_from(cell).ok()?;
        let s = format!("{:x}", u64::from(cell));
        let bytes = s.as_bytes();
        if bytes.len() > out_cap {
            return None;
        }
        // SAFETY: caller guarantees `out_buf` is valid for at least
        // `out_cap` writable bytes and we just confirmed `bytes.len()
        // <= out_cap`. `out_len` is guaranteed valid and writable.
        unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), out_buf, bytes.len());
            *out_len = bytes.len();
        }
        Some(())
    })
}

// ===========================================================================
// Geo <-> cell conversion
// ===========================================================================

/// Converts a `(lat, lng)` coordinate to an H3 cell at the given
/// resolution. Rejects out-of-range or non-finite inputs explicitly.
///
/// # Safety
///
/// `out` must be a valid, writable `*mut u64`.
#[no_mangle]
pub unsafe extern "C" fn ex_h3o_from_geo(
    lat: f64,
    lng: f64,
    res: u8,
    out: *mut u64,
) -> i32 {
    try_call(|| {
        if !lat.is_finite()
            || !lng.is_finite()
            || !(-90.0..=90.0).contains(&lat)
            || !(-180.0..=180.0).contains(&lng)
        {
            return None;
        }
        let resolution = Resolution::try_from(res).ok()?;
        let ll = LatLng::new(lat, lng).ok()?;
        // SAFETY: caller contract requires `out` to be valid and writable.
        unsafe { *out = u64::from(ll.to_cell(resolution)) };
        Some(())
    })
}

/// Writes the centroid `(lat, lng)` of `cell` into two out-params.
///
/// # Safety
///
/// `out_lat` and `out_lng` must each be valid, writable `*mut f64`.
#[no_mangle]
pub unsafe extern "C" fn ex_h3o_to_geo(
    cell: u64,
    out_lat: *mut f64,
    out_lng: *mut f64,
) -> i32 {
    try_call(|| {
        let cell = CellIndex::try_from(cell).ok()?;
        let ll = LatLng::from(cell);
        // SAFETY: caller contract requires both out-params to be valid
        // and writable.
        unsafe {
            *out_lat = ll.lat();
            *out_lng = ll.lng();
        }
        Some(())
    })
}

/// Writes the boundary vertices of `cell` into an `ExH3oBuf`. Wire
/// format: packed `(f64 lat, f64 lng)` pairs in native-endian order,
/// 16 bytes per vertex. 5 or 6 vertices per cell depending on whether
/// it's a pentagon.
///
/// # Safety
///
/// `out` must be a valid, writable `*mut ExH3oBuf`.
#[no_mangle]
pub unsafe extern "C" fn ex_h3o_to_geo_boundary(cell: u64, out: *mut ExH3oBuf) -> i32 {
    try_call(|| {
        // SAFETY: caller contract requires `out` to be valid and writable.
        unsafe { *out = ExH3oBuf::EMPTY };
        let cell = CellIndex::try_from(cell).ok()?;
        let boundary = cell.boundary();
        let mut bytes: Vec<u8> = Vec::with_capacity(boundary.len() * 16);
        for ll in boundary.iter() {
            bytes.extend_from_slice(&ll.lat().to_ne_bytes());
            bytes.extend_from_slice(&ll.lng().to_ne_bytes());
        }
        // SAFETY: same `out` validity as the EMPTY write above.
        unsafe { put_buf(out, bytes) };
        Some(())
    })
}

// ===========================================================================
// Hierarchy
// ===========================================================================

/// Writes the parent of `cell` at the target resolution. Fails if
/// `res` is not a valid H3 resolution OR if `res` is finer than
/// `cell`'s own resolution (the parent doesn't exist).
///
/// # Safety
///
/// `out` must be a valid, writable `*mut u64`.
#[no_mangle]
pub unsafe extern "C" fn ex_h3o_parent(cell: u64, res: u8, out: *mut u64) -> i32 {
    try_call(|| {
        let cell = CellIndex::try_from(cell).ok()?;
        let resolution = Resolution::try_from(res).ok()?;
        let parent = cell.parent(resolution)?;
        // SAFETY: caller contract requires `out` to be valid and writable.
        unsafe { *out = u64::from(parent) };
        Some(())
    })
}

/// Writes the children of `cell` at the target resolution into an
/// `ExH3oBuf`. Wire format: packed `u64` cells in native-endian order.
///
/// # Safety
///
/// `out` must be a valid, writable `*mut ExH3oBuf`.
#[no_mangle]
pub unsafe extern "C" fn ex_h3o_children(cell: u64, res: u8, out: *mut ExH3oBuf) -> i32 {
    try_call(|| {
        // SAFETY: caller contract requires `out` to be valid and writable.
        unsafe { *out = ExH3oBuf::EMPTY };
        let cell = CellIndex::try_from(cell).ok()?;
        let resolution = Resolution::try_from(res).ok()?;
        // Children must be at a resolution finer than (or equal to)
        // the cell itself. Equal-resolution returns a 1-element list
        // containing the cell itself.
        if u8::from(resolution) < u8::from(cell.resolution()) {
            return None;
        }
        // Single-pass: iterate h3o's children() iterator directly into
        // the output byte buffer. `size_hint()` lets us pre-size the
        // Vec when h3o reports a known length, avoiding reallocation
        // in the loop.
        let iter = cell.children(resolution);
        let cap = iter.size_hint().1.unwrap_or(0).saturating_mul(8);
        let mut bytes = Vec::with_capacity(cap);
        for c in iter {
            bytes.extend_from_slice(&u64::from(c).to_ne_bytes());
        }
        // SAFETY: same `out` validity as the EMPTY write above.
        unsafe { put_buf(out, bytes) };
        Some(())
    })
}

// ===========================================================================
// Neighbors / edges / distance
// ===========================================================================

/// Writes whether `a` and `b` are adjacent cells into `*out`.
///
/// # Safety
///
/// `out` must be a valid, writable `*mut bool`.
#[no_mangle]
pub unsafe extern "C" fn ex_h3o_indices_are_neighbors(
    a: u64,
    b: u64,
    out: *mut bool,
) -> i32 {
    try_call(|| {
        let a = CellIndex::try_from(a).ok()?;
        let b = CellIndex::try_from(b).ok()?;
        let result = a.is_neighbor_with(b).ok()?;
        // SAFETY: caller contract requires `out` to be valid and writable.
        unsafe { *out = result };
        Some(())
    })
}

/// Writes the signed grid distance between `a` and `b` into `*out`.
///
/// # Safety
///
/// `out` must be a valid, writable `*mut i32`.
#[no_mangle]
pub unsafe extern "C" fn ex_h3o_grid_distance(a: u64, b: u64, out: *mut i32) -> i32 {
    try_call(|| {
        let a = CellIndex::try_from(a).ok()?;
        let b = CellIndex::try_from(b).ok()?;
        let dist = a.grid_distance(b).ok()?;
        // SAFETY: caller contract requires `out` to be valid and writable.
        unsafe { *out = dist };
        Some(())
    })
}

/// Writes the unidirectional edge from `origin` to `destination`
/// into `*out`.
///
/// # Safety
///
/// `out` must be a valid, writable `*mut u64`.
#[no_mangle]
pub unsafe extern "C" fn ex_h3o_get_unidirectional_edge(
    origin: u64,
    destination: u64,
    out: *mut u64,
) -> i32 {
    try_call(|| {
        let origin = CellIndex::try_from(origin).ok()?;
        let destination = CellIndex::try_from(destination).ok()?;
        let edge = origin.edge(destination)?;
        // SAFETY: caller contract requires `out` to be valid and writable.
        unsafe { *out = u64::from(edge) };
        Some(())
    })
}

// ===========================================================================
// Grid disk (k_ring) family
// ===========================================================================

/// Writes the k-ring around `cell` into an `ExH3oBuf`. Wire format:
/// packed `u64` cells in native-endian order.
///
/// # Safety
///
/// `out` must be a valid, writable `*mut ExH3oBuf`.
#[no_mangle]
pub unsafe extern "C" fn ex_h3o_k_ring(cell: u64, k: u32, out: *mut ExH3oBuf) -> i32 {
    try_call(|| {
        // SAFETY: caller contract requires `out` to be valid and writable.
        unsafe { *out = ExH3oBuf::EMPTY };
        let cell = CellIndex::try_from(cell).ok()?;
        // Pre-size the output buffer using the H3 max-k-ring formula
        // (3k² + 3k + 1 cells). Exact for the all-hexagon case, a
        // slight overestimate near pentagons. Avoids reallocation.
        let max_cells = (3 * k as usize * k as usize) + (3 * k as usize) + 1;
        let mut bytes = Vec::with_capacity(max_cells * 8);
        for c in cell.grid_disk::<Vec<_>>(k) {
            bytes.extend_from_slice(&u64::from(c).to_ne_bytes());
        }
        // SAFETY: same `out` validity as the EMPTY write above.
        unsafe { put_buf(out, bytes) };
        Some(())
    })
}

/// Writes the k-ring around `cell` with per-cell distances into an
/// `ExH3oBuf`. Wire format: packed `(u64 cell, u64 distance)` pairs
/// in native-endian order, 16 bytes per pair.
///
/// # Safety
///
/// `out` must be a valid, writable `*mut ExH3oBuf`.
#[no_mangle]
pub unsafe extern "C" fn ex_h3o_k_ring_distances(
    cell: u64,
    k: u32,
    out: *mut ExH3oBuf,
) -> i32 {
    try_call(|| {
        // SAFETY: caller contract requires `out` to be valid and writable.
        unsafe { *out = ExH3oBuf::EMPTY };
        let cell = CellIndex::try_from(cell).ok()?;
        let max_cells = (3 * k as usize * k as usize) + (3 * k as usize) + 1;
        let mut bytes = Vec::with_capacity(max_cells * 16);
        for (c, d) in cell.grid_disk_distances::<Vec<_>>(k) {
            bytes.extend_from_slice(&u64::from(c).to_ne_bytes());
            bytes.extend_from_slice(&u64::from(d).to_ne_bytes());
        }
        // SAFETY: same `out` validity as the EMPTY write above.
        unsafe { put_buf(out, bytes) };
        Some(())
    })
}

/// Writes the k-ring around `cell` directly into a caller-provided
/// `u64` buffer, returning the number of cells written via `*out_len`.
///
/// Unlike [`ex_h3o_k_ring`], this function does no heap allocation on
/// the Rust side of the FFI and imposes no [`ExH3oBuf`] ownership
/// contract on the caller. It exists so the C NIF can keep a stack
/// buffer for small-k calls and skip the `Box<[u8]>` / `ErlNifBinary`
/// roundtrip that dominates total cost when the output is only a few
/// cells. Above the C NIF's stack-buffer threshold, callers fall back
/// to the `ExH3oBuf` path.
///
/// Returns `0` on success, `1` on failure (invalid cell OR output
/// wouldn't fit in `out_cap` elements). `out_cap` is counted in `u64`
/// elements, not bytes; the caller should size the buffer to at least
/// `3k² + 3k + 1` elements to guarantee no truncation.
///
/// # Safety
///
/// `out_buf` must be valid for `out_cap * sizeof(u64)` writable bytes
/// and 8-byte aligned. `out_len` must be a valid, writable `*mut
/// usize`.
#[no_mangle]
pub unsafe extern "C" fn ex_h3o_k_ring_into(
    cell: u64,
    k: u32,
    out_buf: *mut u64,
    out_cap: usize,
    out_len: *mut usize,
) -> i32 {
    try_call(|| {
        let cell = CellIndex::try_from(cell).ok()?;

        // Happy path: `grid_disk_fast` returns an allocation-free
        // iterator backed by a const-initialized DiskDistancesUnsafe
        // state machine. On non-pentagon cells every item is Some
        // and we write straight into out_buf with zero heap traffic.
        let mut count: usize = 0;
        let mut pentagon_distortion = false;
        for maybe_c in cell.grid_disk_fast(k) {
            match maybe_c {
                Some(c) => {
                    if count >= out_cap {
                        return None;
                    }
                    // SAFETY: count < out_cap per the check above;
                    // caller contract guarantees out_buf is valid for
                    // out_cap u64 writes and is 8-byte aligned.
                    unsafe { *out_buf.add(count) = u64::from(c) };
                    count += 1;
                }
                None => {
                    // Pentagon distortion: rewind and retry with the
                    // always-correct (but allocating) safe iterator.
                    pentagon_distortion = true;
                    break;
                }
            }
        }

        if pentagon_distortion {
            // Rewind the write cursor and retry with the safe
            // iterator. Any Some(cell) values the fast path wrote
            // into out_buf[0..old_count] before hitting None are
            // discarded: resetting count to 0 causes the safe path
            // to overwrite them from index 0 onward, and the final
            // *out_len = count reflects ONLY the safe path's count.
            // If the safe path's count is smaller than old_count,
            // the stale fast-path values sitting past the new count
            // are invisible to the C NIF because it only reads
            // out_buf[0..*out_len] when building the BEAM list.
            //
            // Per h3o's own docs on grid_disk_fast: "the previously
            // returned cells should be treated as invalid and
            // discarded" when the iterator returns None. That's
            // exactly what we're doing.
            //
            // This works without cloning `cell` because CellIndex
            // derives Copy, so cell.grid_disk_fast(k) copied rather
            // than moved.
            count = 0;
            for c in cell.grid_disk_safe(k) {
                if count >= out_cap {
                    return None;
                }
                // SAFETY: same as the fast-path write above.
                unsafe { *out_buf.add(count) = u64::from(c) };
                count += 1;
            }
        }

        // SAFETY: caller contract requires out_len to be a valid,
        // writable *mut usize.
        unsafe { *out_len = count };
        Some(())
    })
}

/// Writes cell/distance pairs for the k-ring around `cell` directly
/// into a caller-provided `u64` buffer as interleaved `[cell,
/// distance, cell, distance, ...]`, returning the number of `u64`
/// *elements* written via `*out_len` (so the pair count is
/// `*out_len / 2`).
///
/// Companion to [`ex_h3o_k_ring_into`]; same motivation and same
/// tradeoffs. `out_cap` is in `u64` elements, not pairs, so the
/// caller should size it to at least `2 * (3k² + 3k + 1)`.
///
/// # Safety
///
/// Same as [`ex_h3o_k_ring_into`]: `out_buf` must be valid for
/// `out_cap * sizeof(u64)` writable bytes and 8-byte aligned;
/// `out_len` must be a valid, writable `*mut usize`.
#[no_mangle]
pub unsafe extern "C" fn ex_h3o_k_ring_distances_into(
    cell: u64,
    k: u32,
    out_buf: *mut u64,
    out_cap: usize,
    out_len: *mut usize,
) -> i32 {
    try_call(|| {
        let cell = CellIndex::try_from(cell).ok()?;

        // Happy path: grid_disk_distances_fast is the allocation-free
        // sibling of grid_disk_fast, yielding Option<(CellIndex, u32)>.
        let mut count: usize = 0;
        let mut pentagon_distortion = false;
        for maybe_pair in cell.grid_disk_distances_fast(k) {
            match maybe_pair {
                Some((c, d)) => {
                    if count + 2 > out_cap {
                        return None;
                    }
                    // SAFETY: count + 2 <= out_cap per the check above,
                    // and the caller guarantees out_buf is valid for
                    // out_cap u64 writes and is 8-byte aligned.
                    unsafe {
                        *out_buf.add(count) = u64::from(c);
                        *out_buf.add(count + 1) = u64::from(d);
                    }
                    count += 2;
                }
                None => {
                    pentagon_distortion = true;
                    break;
                }
            }
        }

        if pentagon_distortion {
            // Rewind. Same reasoning as `ex_h3o_k_ring_into` above:
            // previously-written fast-path values get overwritten
            // from index 0, and anything past the safe path's final
            // count is invisible to C because *out_len is the only
            // thing the C NIF reads. Relies on CellIndex: Copy so
            // that grid_disk_distances_fast(k) didn't move `cell`.
            count = 0;
            for (c, d) in cell.grid_disk_distances_safe(k) {
                if count + 2 > out_cap {
                    return None;
                }
                // SAFETY: same as the fast-path write above.
                unsafe {
                    *out_buf.add(count) = u64::from(c);
                    *out_buf.add(count + 1) = u64::from(d);
                }
                count += 2;
            }
        }

        // SAFETY: caller contract.
        unsafe { *out_len = count };
        Some(())
    })
}

// ===========================================================================
// Compact / uncompact
// ===========================================================================

/// Compacts a set of cells (provided as a packed `u64` binary from the
/// C NIF side) into its minimal representation.
///
/// # Safety
///
/// `cells_data` must be valid for reads of `cell_count` `u64` values
/// and 8-byte aligned (BEAM binaries satisfy this). `out` must be a
/// valid, writable `*mut ExH3oBuf`.
#[no_mangle]
pub unsafe extern "C" fn ex_h3o_compact(
    cells_data: *const u64,
    cell_count: usize,
    out: *mut ExH3oBuf,
) -> i32 {
    try_call(|| {
        // SAFETY: caller contract requires `out` to be valid and writable.
        unsafe { *out = ExH3oBuf::EMPTY };
        // SAFETY: caller contract guarantees `cells_data` is valid for
        // `cell_count` u64 reads and is 8-byte aligned.
        let raw = unsafe { std::slice::from_raw_parts(cells_data, cell_count) };
        // Validate-while-collecting via `collect::<Result<_, _>>()`: if
        // any cell fails `CellIndex::try_from`, the iterator
        // short-circuits and we never allocate the rest of the Vec.
        let mut cells: Vec<CellIndex> = raw
            .iter()
            .map(|&c| CellIndex::try_from(c))
            .collect::<Result<Vec<_>, _>>()
            .ok()?;
        CellIndex::compact(&mut cells).ok()?;
        let mut bytes = Vec::with_capacity(cells.len() * 8);
        for c in cells {
            bytes.extend_from_slice(&u64::from(c).to_ne_bytes());
        }
        // SAFETY: same `out` validity as the EMPTY write above.
        unsafe { put_buf(out, bytes) };
        Some(())
    })
}

/// Expands a compacted set back to the target resolution.
///
/// # Safety
///
/// Same contract as [`ex_h3o_compact`]: `cells_data` must be valid for
/// `cell_count` u64 reads and 8-byte aligned; `out` must be valid
/// and writable.
#[no_mangle]
pub unsafe extern "C" fn ex_h3o_uncompact(
    cells_data: *const u64,
    cell_count: usize,
    res: u8,
    out: *mut ExH3oBuf,
) -> i32 {
    try_call(|| {
        // SAFETY: caller contract requires `out` to be valid and writable.
        unsafe { *out = ExH3oBuf::EMPTY };
        let resolution = Resolution::try_from(res).ok()?;
        // SAFETY: caller contract guarantees `cells_data` is valid for
        // `cell_count` u64 reads and is 8-byte aligned.
        let raw = unsafe { std::slice::from_raw_parts(cells_data, cell_count) };
        // Validate-while-collecting with the resolution-bound check
        // folded in: each input cell must be (a) a valid `CellIndex`
        // and (b) coarser than or equal to the target resolution.
        // Either failure short-circuits the iterator.
        let cells: Vec<CellIndex> = raw
            .iter()
            .map(|&c| {
                let cell = CellIndex::try_from(c).ok()?;
                if u8::from(cell.resolution()) > res {
                    return None;
                }
                Some(cell)
            })
            .collect::<Option<Vec<_>>>()?;
        // `CellIndex::uncompact` returns an iterator we can chain
        // directly into the output byte buffer with no intermediate
        // `Vec<CellIndex>`.
        let iter = CellIndex::uncompact(cells, resolution);
        let cap = iter.size_hint().1.unwrap_or(0).saturating_mul(8);
        let mut bytes = Vec::with_capacity(cap);
        for c in iter {
            bytes.extend_from_slice(&u64::from(c).to_ne_bytes());
        }
        // SAFETY: same `out` validity as the EMPTY write above.
        unsafe { put_buf(out, bytes) };
        Some(())
    })
}

// ===========================================================================
// Polyfill
// ===========================================================================

/// Fills a polygon with H3 cells at the given resolution.
///
/// The polygon is passed as a packed `[lat0, lng0, lat1, lng1, ...]`
/// array of native-endian `f64` values. The Elixir wrapper builds
/// that binary before the dirty dispatch so this function walks raw
/// bytes, not BEAM terms.
///
/// # ⚠️ geo_types coordinate convention
///
/// `geo_types::Coord` uses `x = lng, y = lat`, the OPPOSITE of H3's
/// `(lat, lng)` tuple convention. The conversion below MUST write
/// `x: lng, y: lat` or the polygon will end up at a completely
/// different location on the globe. DO NOT "fix" this to look
/// consistent with the input order.
///
/// # Safety
///
/// `coords` must be valid for reads of `vertex_count * 2` `f64` values
/// and 8-byte aligned. `out` must be a valid, writable `*mut ExH3oBuf`.
#[no_mangle]
pub unsafe extern "C" fn ex_h3o_polyfill(
    coords: *const f64,
    vertex_count: usize,
    res: u8,
    out: *mut ExH3oBuf,
) -> i32 {
    try_call(|| {
        // SAFETY: caller contract requires `out` to be valid and writable.
        unsafe { *out = ExH3oBuf::EMPTY };
        if vertex_count < 3 {
            return None;
        }
        let resolution = Resolution::try_from(res).ok()?;
        // SAFETY: caller contract guarantees `coords` is valid for
        // `vertex_count * 2` f64 reads and is 8-byte aligned.
        let flat = unsafe { std::slice::from_raw_parts(coords, vertex_count * 2) };

        // geo_types uses x=lng, y=lat, OPPOSITE of our input convention.
        let geo_coords: Vec<geo_types::Coord<f64>> = flat
            .chunks_exact(2)
            .map(|pair| geo_types::coord! { x: pair[1], y: pair[0] })
            .collect();

        let line_string = geo_types::LineString::new(geo_coords);
        let polygon = geo_types::Polygon::new(line_string, vec![]);

        let mut tiler = geom::TilerBuilder::new(resolution)
            .containment_mode(geom::ContainmentMode::ContainsCentroid)
            .build();

        tiler.add(polygon).ok()?;
        let cells: Vec<CellIndex> = tiler.into_coverage().collect();

        let mut bytes = Vec::with_capacity(cells.len() * 8);
        for c in &cells {
            bytes.extend_from_slice(&u64::from(*c).to_ne_bytes());
        }
        // SAFETY: same `out` validity as the EMPTY write above.
        unsafe { put_buf(out, bytes) };
        Some(())
    })
}

// ===========================================================================
// Bench-only: null_nif, zero-work FFI baseline
// ===========================================================================

/// Does nothing. Used by the GC deep-dive benchmark to isolate the cost
/// of crossing the C NIF + Rust FFI boundary from the cost of the
/// underlying h3o algorithm. Always compiled in, zero runtime cost
/// unless called.
///
/// Two flavors of this symbol are exposed via the C NIF table:
/// `null_nif/0` runs on the normal scheduler (matches all the scalar
/// ops) and `null_nif_dirty/0` runs on the dirty CPU scheduler
/// (matches polyfill / compact / uncompact). They share this same
/// Rust function; only the C-side scheduler flag differs.
#[no_mangle]
pub extern "C" fn ex_h3o_null_nif() {
    // Intentionally empty. No `catch_unwind` needed — an empty body
    // cannot panic.
}

// ===========================================================================
// Test-only: dirty_sleep
// ===========================================================================

/// Sleeps for `ms` milliseconds. Used by the shutdown regression test
/// to verify that `ERL_NIF_OPT_DELAY_HALT` lets in-flight dirty NIFs
/// complete gracefully. Zero runtime cost unless called.
#[no_mangle]
pub extern "C" fn ex_h3o_dirty_sleep(ms: u64) {
    // `thread::sleep` cannot panic, but wrap in `catch_unwind` anyway
    // so every FFI entry point is uniformly panic-safe.
    let _ = catch_unwind(AssertUnwindSafe(|| {
        std::thread::sleep(std::time::Duration::from_millis(ms));
    }));
}
