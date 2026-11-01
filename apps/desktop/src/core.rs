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
        let (db, db_error) = match stores {
            Ok(db) => (Some(db), None),
            Err(e) => (None, Some(e)),
        };
        let scenario = std::env::var("LOCALFLOW_SCENARIO").ok();
        Core { paths, instance_lock, prefs, db, db_error, services, scenario, reconciled: false, meeting_notices: vec![], recorder: None, remote: None, swift_import }
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
