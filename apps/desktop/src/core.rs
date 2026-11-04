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
    /// What the last copy from the Swift app did.
    pub swift_import: Option<Result<String, String>>,
    /// The Rust recorder's current or last meeting, on platforms with `Services::meeting_audio`.
    pub recorder: Option<flow_core::capture::Handle>,
    /// Enrollment and channels, built on first use.
    pub remote: Option<std::sync::Arc<crate::remote::Remote>>,
    pub analysis: Option<std::sync::Arc<flow_core::analysis::queue::Coordinator>>,
    /// Meetings the launch reconciler picked; `start_analysis` queues them.
    pub analysis_restarts: Vec<String>,
    /// Server mode, where this Mac can host one and the data folder is the real one (Feature 028).
    pub server: Option<std::sync::Arc<dyn flow_platform::ServerHost>>,
}
impl Global for Core {}

impl Core {
    pub fn load(services: Box<dyn Services>) -> Core {
        if let Some(f) = services.formats() {
            flow_core::history::set_region(flow_core::history::Region { date: f.date, number: f.number, first_weekday: f.first_weekday });
        }
        let mut paths = Paths::resolve(services.app_data_dir(), services.data_folder());
        let redirected = std::env::var_os("LOCALFLOW_DATA_ROOT").is_some_and(|r| !r.is_empty());
        paths.adopt_swift(&services.app_data_dir(), services.swift_data_folder(), redirected);
        let (instance_lock, stores) = match paths.prepare() {
            Ok(lock) => (Some(lock), Db::open_or_create(&paths.database()).map_err(|e| e.to_string())),
            Err(e) => (None, Err(e.to_string())),
        };
        let mut prefs = Prefs::open(paths.preferences());
        let swift_import = match (&stores, &paths.swift_root) {
            (Ok(db), Some(swift)) => flow_core::migration::first_launch(db, &mut prefs, swift, &paths.root, services.swift_prefs()).map(|r| r.map(|i| i.summary())),
            _ => None,
        };
        if let (Some(_), Some(swift)) = (&instance_lock, &paths.swift_root) {
            // On failure the model reads as not installed and the app offers its download.
            let _ = flow_core::migration::clone_models(&swift.join("Models"), &paths.models());
        }
        let (db, db_error) = match stores {
            Ok(db) => (Some(db), None),
            Err(e) => (None, Some(e)),
        };
        let scenario = std::env::var("LOCALFLOW_SCENARIO").ok();
        let server = services.server_host(&paths.root, paths.live);
        if let Some(host) = server.clone() {
            // An open cut short by a quit is undone, and an update's helpers reach a managed server.
            std::thread::spawn(move || host.launch());
        }
        Core { paths, instance_lock, prefs, db, db_error, services, scenario, reconciled: false, meeting_notices: vec![], recorder: None, remote: None, swift_import, analysis: None, analysis_restarts: vec![], server }
    }

    /// The summary queue, made on first use: its paths and channel come from here.
    pub fn analysis(&mut self) -> std::sync::Arc<flow_core::analysis::queue::Coordinator> {
        if let Some(analysis) = &self.analysis {
            return analysis.clone();
        }
        let credentials = self.services.credentials();
        let deps = flow_core::analysis::run::Deps {
            database: self.paths.database(),
            secret: std::sync::Arc::new(move |origin| credentials.secret_data(&flow_core::settings::rewrite_keychain(origin)).ok().flatten().and_then(|v| String::from_utf8(v).ok())),
            pool: Some(self.remote().pool.clone()),
            wait_unit: std::time::Duration::from_secs(1),
            deadline_unit: std::time::Duration::from_secs(1),
            partials: Default::default(),
        };
        self.analysis.insert(flow_core::analysis::queue::Coordinator::new(deps)).clone()
    }

    /// Where a summary goes right now. Reads the Keychain, so it's built only when something is due.
    pub fn analysis_route(&self) -> flow_core::analysis::run::Route {
        let credentials = self.services.credentials();
        let credential = |origin: &str| credentials.secret_data(&flow_core::settings::rewrite_keychain(origin)).ok().flatten().is_some();
        let key = credentials.secret_data(&flow_core::settings::rewrite_keychain(flow_core::settings::SUMMARY_ACCOUNT)).ok().flatten().and_then(|v| String::from_utf8(v).ok());
        flow_core::analysis::run::route(&self.prefs, credential, key.as_deref())
    }

    pub fn remote(&mut self) -> std::sync::Arc<crate::remote::Remote> {
        let services = &self.services;
        self.remote.get_or_insert_with(|| crate::remote::Remote::native(services.credentials())).clone()
    }

    /// `turnOffRemoteDictation()`: enrollment `turnOff()` removes the device key, the four Keychain
    /// items and the remote settings, history stays, parked channels close and whatever is running
    /// stores nothing, and staged handoff bundles go, recordings stay. Failures are ignored as Swift's `try?` and detached task ignore them.
    pub fn turn_off_remote(&mut self) {
        if let Some(remote) = &self.remote {
            remote.enrollment.cancel();
            remote.pool.close_parked();
            remote.enrollment.turn_off();
        }
        if let Ok(Some(handle)) = self.services.secret_data(&flow_core::settings::remote_keychain("device-key")) {
            let _ = self.services.device_key_delete(&handle);
        }
        for account in ["device-key", "server-key", "refresh-token", "access-token"] {
            let _ = self.services.remove_secret(&flow_core::settings::remote_keychain(account));
        }
        flow_core::settings::reset_remote(&mut self.prefs);
        flow_core::remote::handoff::forget_staged(&self.paths.root.join("Meetings"));
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
            swift_import: None,
            recorder: None,
            remote: None,
            analysis: None,
            analysis_restarts: vec![],
            server: None,
        }
    }

    /// Swift's launch reconciliation.
    // ponytail: runs on launch's thread, bounded to 100 rows per table; a task if it ever shows up in launch time.
    pub fn reconcile_meetings(&mut self) {
        let root = self.paths.root.join("Meetings");
        if let Some(Ok(recovery)) = self.db.as_ref().map(|db| flow_core::meetings::reconcile_launch(db, &root, flow_core::history::now_ms())) {
            self.meeting_notices = recovery.notices();
            self.analysis_restarts = recovery.analysis_restarts;
        }
        // Swift completes recovery even when a reconciler throws, so New note unlocks.
        self.reconciled = true;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn turning_off_removes_staged_bundles_and_keeps_recordings() {
        let id = "6f3a1c52-8d47-4e19-9b21-0c7e5a2d4f10";
        let root = std::env::temp_dir().join(format!("flow-turn-off-{}", std::process::id()));
        let (bundle, recording) = (root.join("Handoff").join(id).join("bundle.sqlite"), root.join("Meetings").join(id).join("mic-0001.aac"));
        std::fs::create_dir_all(bundle.parent().unwrap()).unwrap();
        std::fs::create_dir_all(recording.parent().unwrap()).unwrap();
        std::fs::write(&bundle, b"x").unwrap();
        std::fs::write(&recording, b"x").unwrap();
        let mut core = Core::for_test();
        core.paths = Paths::new(root.clone());
        core.turn_off_remote();
        let (gone, kept) = (!bundle.parent().unwrap().exists(), recording.exists());
        let _ = std::fs::remove_dir_all(&root);
        assert!(gone && kept);
    }
}
