use h3o::CellIndex;

#[rustler::nif]
fn is_valid(cell: u64) -> bool {
    CellIndex::try_from(cell).is_ok()
}

rustler::init!("Elixir.ExH3o.Native");
