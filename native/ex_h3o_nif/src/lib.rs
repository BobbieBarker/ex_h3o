mod atoms;
mod types;

use h3o::{CellIndex, LatLng, Resolution};
use rustler::sys::{enif_set_option, ErlNifOption};
use rustler::{Encoder, OwnedBinary, Term};

#[rustler::nif]
fn is_valid(cell: u64) -> bool {
    CellIndex::try_from(cell).is_ok()
}

#[rustler::nif]
fn from_geo<'a>(env: rustler::Env<'a>, lat: Term<'a>, lng: Term<'a>, resolution: u8) -> Term<'a> {
    let lat: f64 = match lat.decode() {
        Ok(v) => v,
        Err(_) => return (atoms::error(), atoms::invalid_coordinates()).encode(env),
    };
    let lng: f64 = match lng.decode() {
        Ok(v) => v,
        Err(_) => return (atoms::error(), atoms::invalid_coordinates()).encode(env),
    };

    let res = match Resolution::try_from(resolution) {
        Ok(r) => r,
        Err(_) => return (atoms::error(), atoms::invalid_resolution()).encode(env),
    };

    if !(-90.0..=90.0).contains(&lat) || !(-180.0..=180.0).contains(&lng) {
        return (atoms::error(), atoms::invalid_coordinates()).encode(env);
    }

    let latlng = match LatLng::new(lat, lng) {
        Ok(ll) => ll,
        Err(_) => return (atoms::error(), atoms::invalid_coordinates()).encode(env),
    };

    let cell: u64 = latlng.to_cell(res).into();
    (atoms::ok(), cell).encode(env)
}

#[rustler::nif]
fn to_geo<'a>(env: rustler::Env<'a>, cell: u64) -> Term<'a> {
    let cell = match CellIndex::try_from(cell) {
        Ok(c) => c,
        Err(_) => return (atoms::error(), atoms::invalid_index()).encode(env),
    };

    let latlng = LatLng::from(cell);
    let lat = f64::from(latlng.lat());
    let lng = f64::from(latlng.lng());
    (atoms::ok(), (lat, lng)).encode(env)
}

#[rustler::nif]
fn to_geo_boundary<'a>(env: rustler::Env<'a>, cell: u64) -> Term<'a> {
    let cell = match CellIndex::try_from(cell) {
        Ok(c) => c,
        Err(_) => return (atoms::error(), atoms::invalid_index()).encode(env),
    };

    let boundary = cell.boundary();
    let vertices: Vec<_> = boundary.iter().collect();
    let num_vertices = vertices.len();

    let mut binary = OwnedBinary::new(num_vertices * 16).unwrap();
    let buf = binary.as_mut_slice();
    for (i, vertex) in vertices.iter().enumerate() {
        let lat = f64::from(vertex.lat());
        let lng = f64::from(vertex.lng());
        buf[i * 16..i * 16 + 8].copy_from_slice(&lat.to_ne_bytes());
        buf[i * 16 + 8..i * 16 + 16].copy_from_slice(&lng.to_ne_bytes());
    }

    (atoms::ok(), rustler::Binary::from_owned(binary, env)).encode(env)
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

rustler::init!("Elixir.ExH3o.Native", load = load);
