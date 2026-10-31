//! Synthetic content in the real schema, for tests, the audit and the Swift reference app. None
//! of it comes from real recordings or dictations. Each store module owns its section.
use crate::db::Db;

pub fn seed(db: &Db) {
    crate::dictionary::seed(db);
    crate::history::seed(db);
    crate::insights::seed(db);
    crate::meetings::seed(db);
    crate::settings::seed(db);
    crate::onboarding::seed(db);
}
