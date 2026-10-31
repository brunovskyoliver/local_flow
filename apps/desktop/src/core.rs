//! The composition root's shared state: data root, preferences, database and OS services.
use flow_core::{db::Db, paths::Paths, prefs::Prefs};
use flow_platform::Services;
use flow_ui::gpui::Global;

pub struct Core {
    pub paths: Paths,
    pub prefs: Prefs,
    /// None when the database couldn't open; `db_error` says why (Swift's `setupStatus`).
    pub db: Option<Db>,
    pub db_error: Option<String>,
    pub services: Box<dyn Services>,
    /// `LOCALFLOW_SCENARIO`, for the audit: pages use it to show states fixture data can't reach.
    pub scenario: Option<String>,
}
impl Global for Core {}

impl Core {
    pub fn load(services: Box<dyn Services>) -> Core {
        let paths = Paths::resolve(services.app_data_dir());
        let prefs = Prefs::open(paths.preferences());
        let (db, db_error) = match Db::open_or_create(&paths.database()) {
            Ok(db) => (Some(db), None),
            Err(e) => (None, Some(e.to_string())),
        };
        let scenario = std::env::var("LOCALFLOW_SCENARIO").ok();
        Core { paths, prefs, db, db_error, services, scenario }
    }

    /// In-memory database with the seed, memory preferences and fake services.
    pub fn for_test() -> Core {
        let db = Db::memory();
        flow_core::seed::seed(&db);
        Core {
            paths: Paths::new(std::env::temp_dir().join("localflow-test")),
            prefs: Prefs::memory(),
            db: Some(db),
            db_error: None,
            services: Box::new(flow_platform::Fake::default()),
            scenario: None,
        }
    }
}
