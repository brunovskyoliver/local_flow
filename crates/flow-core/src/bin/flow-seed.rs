//! `flow-seed <history.sqlite>`: creates a fixture database with synthetic content.
fn main() {
    let path = std::env::args().nth(1).expect("usage: flow-seed <history.sqlite>");
    let db = flow_core::db::Db::open_or_create(std::path::Path::new(&path)).expect("open database");
    flow_core::seed::seed(&db);
    println!("seeded {path}");
}
