//! The composition root's shared state: data root, preferences, database and OS services.
use flow_core::{db::Db, paths::{InstanceLock, Paths}, prefs::Prefs};
use flow_platform::Services;
use flow_ui::gpui::Global;

pub struct Core {
    pub paths: Paths,
    /// Held for the app's lifetime. A failure leaves no stores, as Swift's launch catch does.
    pub instance_lock: Option<InstanceLock>,
    pub prefs: Prefs,
    /// None when the database couldn't open; `db_error` says why (Swift's `setupStatus`).
    pub db: Option<Db>,
    pub db_error: Option<String>,
    pub services: Box<dyn Services>,
    /// `LOCALFLOW_SCENARIO`, for the audit: pages use it to show states fixture data can't reach.
    pub scenario: Option<String>,
    /// `MeetingCoordinator.reconciliationComplete`. Start stays off until it is true.
    pub reconciled: bool,
    /// Launch recovery's notices, until the Notetaker page publishes them to the pill.
    pub meeting_notices: Vec<String>,
}
impl Global for Core {}

impl Core {
    pub fn load(services: Box<dyn Services>) -> Core {
        if let Some(f) = services.formats() {
            flow_core::history::set_region(flow_core::history::Region { date: f.date, number: f.number, first_weekday: f.first_weekday });
        }
        let paths = Paths::resolve(services.app_data_dir());
        let (instance_lock, stores) = match paths.prepare() {
            Ok(lock) => (Some(lock), Db::open_or_create(&paths.database()).map_err(|e| e.to_string())),
            Err(e) => (None, Err(e.to_string())),
        };
        let prefs = Prefs::open(paths.preferences());
        let (db, db_error) = match stores {
            Ok(db) => (Some(db), None),
            Err(e) => (None, Some(e)),
        };
        let scenario = std::env::var("LOCALFLOW_SCENARIO").ok();
        Core { paths, instance_lock, prefs, db, db_error, services, scenario, reconciled: false, meeting_notices: vec![] }
    }

    /// `turnOffRemoteDictation()`: enrollment `turnOff()` removes the four Keychain items and the
    /// remote settings, history stays, and a parked rewrite channel is closed. Failures are ignored
    /// as Swift's `try?` and detached task ignore them.
    pub fn turn_off_remote(&mut self) {
        for account in ["device-key", "server-key", "refresh-token", "access-token"] {
            let _ = self.services.remove_secret(&flow_core::settings::remote_keychain(account));
        }
        flow_core::settings::reset_remote(&mut self.prefs);
        let _ = self.services.close_parked_channels();
    }

    /// In-memory database with the seed, memory preferences and fake services.
    pub fn for_test() -> Core {
        let db = Db::memory();
        flow_core::seed::seed(&db);
        Core {
            paths: Paths::new(std::env::temp_dir().join("localflow-test")),
            instance_lock: None,
            prefs: Prefs::memory(),
            db: Some(db),
            db_error: None,
            services: Box::new(flow_platform::Fake::default()),
            scenario: None,
            reconciled: true,
            meeting_notices: vec![],
        }
    }

    /// Swift's launch reconciliation.
    // ponytail: runs on launch's thread, bounded to 100 rows per table; a task if it ever shows up in launch time.
    pub fn reconcile_meetings(&mut self) {
        let root = self.paths.root.join("Meetings");
        if let Some(Ok(recovery)) = self.db.as_ref().map(|db| flow_core::meetings::reconcile_launch(db, &root, flow_core::history::now_ms())) {
            self.meeting_notices = recovery.notices();
        }
        // Swift completes recovery even when a reconciler throws, so New note unlocks.
        self.reconciled = true;
    }
}
