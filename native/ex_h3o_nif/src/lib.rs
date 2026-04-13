mod atoms;
mod types;

use h3o::{error::CompactionError, geom, CellIndex, LatLng, Resolution};
use rustler::sys::{enif_set_option, ErlNifOption};
use rustler::{Encoder, Env, NewBinary, Term};

#[rustler::nif]
fn is_valid(cell: u64) -> bool {
    CellIndex::try_from(cell).is_ok()
}

#[rustler::nif]
fn get_resolution(cell: u64) -> Result<u8, rustler::Atom> {
    let cell = CellIndex::try_from(cell).map_err(|_| atoms::invalid_index())?;
    Ok(u8::from(cell.resolution()))
}

#[rustler::nif]
fn get_base_cell(cell: u64) -> Result<u8, rustler::Atom> {
    let cell = CellIndex::try_from(cell).map_err(|_| atoms::invalid_index())?;
    Ok(u8::from(cell.base_cell()))
}

#[rustler::nif]
fn is_pentagon(cell: u64) -> Result<bool, rustler::Atom> {
    let cell = CellIndex::try_from(cell).map_err(|_| atoms::invalid_index())?;
    Ok(cell.is_pentagon())
}

#[rustler::nif]
fn is_class3(cell: u64) -> Result<bool, rustler::Atom> {
    let cell = CellIndex::try_from(cell).map_err(|_| atoms::invalid_index())?;
    Ok(cell.resolution().is_class3())
}

#[rustler::nif]
fn from_string(hex: &str) -> Result<u64, rustler::Atom> {
    let value = u64::from_str_radix(hex, 16).map_err(|_| atoms::invalid_string())?;
    let cell = CellIndex::try_from(value).map_err(|_| atoms::invalid_string())?;
    Ok(u64::from(cell))
}

#[rustler::nif]
fn to_string(cell: u64) -> Result<String, rustler::Atom> {
    let cell = CellIndex::try_from(cell).map_err(|_| atoms::invalid_index())?;
    Ok(format!("{:x}", u64::from(cell)))
}

#[rustler::nif]
fn parent(cell: u64, resolution: u8) -> Result<u64, rustler::Atom> {
    let cell_index = CellIndex::try_from(cell).map_err(|_| atoms::invalid_index())?;
    let res = Resolution::try_from(resolution).map_err(|_| atoms::invalid_resolution())?;
    cell_index
        .parent(res)
        .map(u64::from)
        .ok_or(atoms::invalid_resolution())
}

#[rustler::nif]
fn from_geo(lat: f64, lng: f64, resolution: u8) -> Result<u64, rustler::Atom> {
    if !lat.is_finite() || !lng.is_finite() || lat < -90.0 || lat > 90.0 || lng < -180.0 || lng > 180.0
    {
        return Err(atoms::invalid_coordinates());
    }
    let res = Resolution::try_from(resolution).map_err(|_| atoms::invalid_resolution())?;
    let ll = LatLng::new(lat, lng).map_err(|_| atoms::invalid_coordinates())?;
    Ok(u64::from(ll.to_cell(res)))
}

#[rustler::nif]
fn to_geo(cell: u64) -> Result<(f64, f64), rustler::Atom> {
    let cell_index = CellIndex::try_from(cell).map_err(|_| atoms::invalid_index())?;
    let ll = LatLng::from(cell_index);
    Ok((ll.lat(), ll.lng()))
}

#[rustler::nif]
fn to_geo_boundary<'a>(env: Env<'a>, cell: u64) -> Term<'a> {
    let cell_index = match CellIndex::try_from(cell) {
        Ok(c) => c,
        Err(_) => return (atoms::error(), atoms::invalid_index()).encode(env),
    };
    let boundary = cell_index.boundary();
    let len = boundary.len();
    let mut binary = NewBinary::new(env, len * 16);
    let buf = binary.as_mut_slice();
    for (i, ll) in boundary.iter().enumerate() {
        buf[i * 16..i * 16 + 8].copy_from_slice(&ll.lat().to_ne_bytes());
        buf[i * 16 + 8..(i + 1) * 16].copy_from_slice(&ll.lng().to_ne_bytes());
    }
    let binary: rustler::Binary = binary.into();
    (atoms::ok(), binary).encode(env)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn children<'a>(env: Env<'a>, cell: u64, resolution: u8) -> Term<'a> {
    let cell_index = match CellIndex::try_from(cell) {
        Ok(c) => c,
        Err(_) => return (atoms::error(), atoms::invalid_index()).encode(env),
    };
    let cell_res = u8::from(cell_index.resolution());
    let res = match Resolution::try_from(resolution) {
        Ok(r) => r,
        Err(_) => return (atoms::error(), atoms::invalid_resolution()).encode(env),
    };

    if resolution < cell_res {
        return (atoms::error(), atoms::invalid_resolution()).encode(env);
    }

    let cells: Vec<CellIndex> = cell_index.children(res).collect();
    let mut binary = NewBinary::new(env, cells.len() * 8);
    let buf = binary.as_mut_slice();
    for (i, c) in cells.iter().enumerate() {
        buf[i * 8..(i + 1) * 8].copy_from_slice(&u64::from(*c).to_ne_bytes());
    }
    let binary: rustler::Binary = binary.into();
    (atoms::ok(), binary).encode(env)
}

#[rustler::nif]
fn indices_are_neighbors(a: u64, b: u64) -> Result<bool, rustler::Atom> {
    let a = CellIndex::try_from(a).map_err(|_| atoms::invalid_index())?;
    let b = CellIndex::try_from(b).map_err(|_| atoms::invalid_index())?;
    a.is_neighbor_with(b)
        .map_err(|_| atoms::resolution_mismatch())
}

#[rustler::nif]
fn grid_distance(a: u64, b: u64) -> Result<i32, rustler::Atom> {
    let a = CellIndex::try_from(a).map_err(|_| atoms::invalid_index())?;
    let b = CellIndex::try_from(b).map_err(|_| atoms::invalid_index())?;
    a.grid_distance(b).map_err(|_| atoms::local_ij_error())
}

#[rustler::nif]
fn get_unidirectional_edge(origin: u64, destination: u64) -> Result<u64, rustler::Atom> {
    let origin = CellIndex::try_from(origin).map_err(|_| atoms::invalid_index())?;
    let destination = CellIndex::try_from(destination).map_err(|_| atoms::invalid_index())?;
    origin
        .edge(destination)
        .map(u64::from)
        .ok_or(atoms::not_neighbors())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn k_ring<'a>(env: Env<'a>, cell: u64, k: u32) -> Term<'a> {
    let cell_index = match CellIndex::try_from(cell) {
        Ok(c) => c,
        Err(_) => return (atoms::error(), atoms::invalid_index()).encode(env),
    };

    let cells: Vec<CellIndex> = cell_index.grid_disk::<Vec<_>>(k);
    let mut binary = NewBinary::new(env, cells.len() * 8);
    let buf = binary.as_mut_slice();
    for (i, c) in cells.iter().enumerate() {
        buf[i * 8..(i + 1) * 8].copy_from_slice(&u64::from(*c).to_ne_bytes());
    }
    let binary: rustler::Binary = binary.into();
    (atoms::ok(), binary).encode(env)
}

/// Dirty CPU NIF that sleeps for `ms` milliseconds and returns `:ok`.
/// Used to verify that `ERL_NIF_OPT_DELAY_HALT` allows in-flight dirty
/// NIFs to complete before the VM halts. Only compiled with the
/// `test_utils` feature flag.
#[cfg(feature = "test_utils")]
#[rustler::nif(schedule = "DirtyCpu")]
fn dirty_sleep(ms: u64) -> rustler::Atom {
    std::thread::sleep(std::time::Duration::from_millis(ms));
    rustler::types::atom::ok()
}

fn load(env: rustler::Env, _info: rustler::Term) -> bool {
    // SAFETY: called during NIF load with a valid env pointer.
    // enif_set_option returns 0 on success.
    let rc = unsafe {
        enif_set_option(
            env.as_c_arg(),
            ErlNifOption::ERL_NIF_OPT_DELAY_HALT,
        )
    };

    if rc != 0 {
        eprintln!(
            "ex_h3o: failed to set ERL_NIF_OPT_DELAY_HALT (rc={}). \
             Dirty NIFs may not complete gracefully during VM shutdown. \
             Requires OTP 26.0+.",
            rc
        );
    }

    // DELAY_HALT is best-effort — the NIF is still usable without it.
    true
}


#[rustler::nif(schedule = "DirtyCpu")]
fn k_ring_distances<'a>(env: Env<'a>, cell: u64, k: u32) -> Term<'a> {
    let cell_index = match CellIndex::try_from(cell) {
        Ok(c) => c,
        Err(_) => return (atoms::error(), atoms::invalid_index()).encode(env),
    };

    let pairs: Vec<(CellIndex, u32)> = cell_index.grid_disk_distances::<Vec<_>>(k);
    let mut binary = NewBinary::new(env, pairs.len() * 16);
    let buf = binary.as_mut_slice();
    for (i, (c, d)) in pairs.iter().enumerate() {
        let offset = i * 16;
        buf[offset..offset + 8].copy_from_slice(&u64::from(*c).to_ne_bytes());
        buf[offset + 8..offset + 16].copy_from_slice(&(u64::from(*d)).to_ne_bytes());
    }
    let binary: rustler::Binary = binary.into();
    (atoms::ok(), binary).encode(env)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn compact<'a>(env: Env<'a>, packed: rustler::Binary) -> Term<'a> {
    let bytes = packed.as_slice();
    if bytes.len() % 8 != 0 {
        return (atoms::error(), atoms::invalid_index()).encode(env);
    }

    let mut cells: Vec<CellIndex> = Vec::with_capacity(bytes.len() / 8);
    for chunk in bytes.chunks_exact(8) {
        let raw = u64::from_ne_bytes(chunk.try_into().unwrap());
        match CellIndex::try_from(raw) {
            Ok(cell) => cells.push(cell),
            Err(_) => return (atoms::error(), atoms::invalid_index()).encode(env),
        }
    }

    match CellIndex::compact(&mut cells) {
        Ok(()) => {
            let mut binary = NewBinary::new(env, cells.len() * 8);
            let buf = binary.as_mut_slice();
            for (i, c) in cells.iter().enumerate() {
                buf[i * 8..(i + 1) * 8].copy_from_slice(&u64::from(*c).to_ne_bytes());
            }
            let binary: rustler::Binary = binary.into();
            (atoms::ok(), binary).encode(env)
        }
        Err(CompactionError::HeterogeneousResolution) => {
            (atoms::error(), atoms::heterogeneous_resolution()).encode(env)
        }
        Err(CompactionError::DuplicateInput) => {
            (atoms::error(), atoms::duplicate_input()).encode(env)
        }
        Err(_) => (atoms::error(), atoms::compaction_failed()).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn uncompact<'a>(env: Env<'a>, packed: rustler::Binary, resolution: u8) -> Term<'a> {
    let res = match Resolution::try_from(resolution) {
        Ok(r) => r,
        Err(_) => return (atoms::error(), atoms::invalid_resolution()).encode(env),
    };

    let bytes = packed.as_slice();
    if bytes.len() % 8 != 0 {
        return (atoms::error(), atoms::invalid_index()).encode(env);
    }

    let mut cells: Vec<CellIndex> = Vec::with_capacity(bytes.len() / 8);
    for chunk in bytes.chunks_exact(8) {
        let raw = u64::from_ne_bytes(chunk.try_into().unwrap());
        match CellIndex::try_from(raw) {
            Ok(cell) => {
                if u8::from(cell.resolution()) > resolution {
                    return (atoms::error(), atoms::invalid_resolution()).encode(env);
                }
                cells.push(cell);
            }
            Err(_) => return (atoms::error(), atoms::invalid_index()).encode(env),
        }
    }

    let result: Vec<CellIndex> = CellIndex::uncompact(cells, res).collect();
    let mut binary = NewBinary::new(env, result.len() * 8);
    let buf = binary.as_mut_slice();
    for (i, c) in result.iter().enumerate() {
        buf[i * 8..(i + 1) * 8].copy_from_slice(&u64::from(*c).to_ne_bytes());
    }
    let binary: rustler::Binary = binary.into();
    (atoms::ok(), binary).encode(env)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn polyfill<'a>(env: Env<'a>, vertices: Vec<(f64, f64)>, resolution: u8) -> Term<'a> {
    let res = match Resolution::try_from(resolution) {
        Ok(r) => r,
        Err(_) => return (atoms::error(), atoms::invalid_resolution()).encode(env),
    };

    if vertices.len() < 3 {
        return (atoms::error(), atoms::invalid_geometry()).encode(env);
    }

    // Convert (lat, lng) tuples to geo_types::Coord (x=lng, y=lat)
    let coords: Vec<geo_types::Coord<f64>> = vertices
        .iter()
        .map(|(lat, lng)| geo_types::coord! { x: *lng, y: *lat })
        .collect();

    let line_string = geo_types::LineString::new(coords);
    let polygon = geo_types::Polygon::new(line_string, vec![]);

    let mut tiler = geom::TilerBuilder::new(res)
        .containment_mode(geom::ContainmentMode::ContainsCentroid)
        .build();

    match tiler.add(polygon) {
        Ok(()) => {}
        Err(_) => return (atoms::error(), atoms::invalid_geometry()).encode(env),
    }

    let cells: Vec<CellIndex> = tiler.into_coverage().collect();
    let mut binary = NewBinary::new(env, cells.len() * 8);
    let buf = binary.as_mut_slice();
    for (i, c) in cells.iter().enumerate() {
        buf[i * 8..(i + 1) * 8].copy_from_slice(&u64::from(*c).to_ne_bytes());
    }
    let binary: rustler::Binary = binary.into();
    (atoms::ok(), binary).encode(env)
}

rustler::init!("Elixir.ExH3o.Native", load = load);
