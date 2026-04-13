mod atoms;
mod types;

use h3o::CellIndex;
use rustler::sys::{enif_set_option, ErlNifOption};

#[rustler::nif]
fn is_valid(cell: u64) -> bool {
    CellIndex::try_from(cell).is_ok()
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
