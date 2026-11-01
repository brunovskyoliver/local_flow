//! `AppServices`' dictation wiring: one thread owns the coordinator and the speech lifecycle, as its
//! actors do in Swift; this side polls the shortcut and that thread's events on the UI thread.
use crate::core::Core;
use crate::pill;
use crate::shell::{self, DictState, Session, update_session};
use flow_core::db::Db;
use flow_core::dictation::lifecycle::{Launcher, Lifecycle};
use flow_core::dictation::session::{Control, Coordinator, DbHistory, Deps, Event, Inserter, Local, Mic, Snapshot, State};
use flow_core::settings::{self as server, InputEntry, Shortcut};
use flow_platform::{SessionCommand, Unavailable};
use flow_ui::prelude::*;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering::SeqCst};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const POLL: Duration = Duration::from_millis(40);
const TICK: Duration = Duration::from_secs(5);
/// Past this the thread is in a session, and the command's answer is that it can't run now.
const REPLY: Duration = Duration::from_secs(2);
const MODEL_LOAD: Duration = Duration::from_secs(30);

enum Command {
    Begin { control: Arc<Control>, entries: Vec<InputEntry> },
    RetrySave(Sender<bool>),
    RetryStorage(Sender<bool>),
    RecheckCapacity,
    ModelChanged,
    KeepLoaded(bool),
    Load(Sender<bool>),
    Shutdown(Sender<bool>),
}

pub struct Parts {
    pub mic: Arc<dyn Mic>,
    pub inserter: Arc<dyn Inserter>,
    pub launcher: Box<dyn Launcher>,
    pub db: Db,
    pub spool_root: PathBuf,
    pub pending_dir: PathBuf,
    pub free_bytes: Box<dyn Fn() -> Option<u64> + Send>,
}

pub struct Driver {
    commands: Sender<Command>,
    events: Mutex<Receiver<Event>>,
    mic: Arc<dyn Mic>,
    running: Arc<AtomicBool>,
    control: Option<Arc<Control>>,
    model_installed: bool,
    keep_loaded: bool,
}
impl Global for Driver {}

impl Driver {
    pub fn spawn(parts: Parts, keep_loaded: bool) -> Driver {
        let (commands, inbox) = channel();
        let (publish, events) = channel();
        let running = Arc::new(AtomicBool::new(false));
        let (mic, flag) = (parts.mic.clone(), running.clone());
        std::thread::Builder::new().name("dictation".into()).spawn(move || serve(parts, keep_loaded, inbox, publish, flag)).expect("the dictation thread starts");
        Driver { commands, events: Mutex::new(events), mic, running, control: None, model_installed: false, keep_loaded }
    }

    fn ask(&self, command: impl FnOnce(Sender<bool>) -> Command, limit: Duration) -> bool {
        let (reply, answer) = mpsc::channel();
        self.commands.send(command(reply)).is_ok() && answer.recv_timeout(limit).unwrap_or(false)
    }
}

fn serve(parts: Parts, keep_loaded: bool, inbox: Receiver<Command>, publish: Sender<Event>, running: Arc<AtomicBool>) {
    let Parts { mic, inserter, launcher, db, spool_root, pending_dir, free_bytes } = parts;
    let mut lifecycle = Lifecycle::new(launcher, Box::new(Instant::now));
    lifecycle.set_keep_loaded(keep_loaded);
    let mut coordinator = Coordinator::new(spool_root, pending_dir.clone(), Box::new(move |event| drop(publish.send(event))));
    let mut history = DbHistory { db, pending_dir, free_bytes };
    coordinator.verify_admission(&mut history);
    loop {
        match inbox.recv_timeout(TICK) {
            Ok(Command::Begin { control, entries }) => {
                let mut recognizer = Local::new(&mut lifecycle);
                // seam (T017): the rewriter goes here. Without one a session saves and inserts the original.
                let mut deps = Deps { mic: mic.as_ref(), inputs: &entries, recognizer: &mut recognizer, rewriter: None, inserter: inserter.as_ref(), history: &mut history };
                coordinator.run(&mut deps, &control);
                running.store(false, SeqCst);
            }
            Ok(Command::RetrySave(reply)) => drop(reply.send(coordinator.retry_save(&mut history))),
            Ok(Command::RetryStorage(reply)) => drop(reply.send(coordinator.retry_storage(&mut history))),
            Ok(Command::RecheckCapacity) => coordinator.recheck_capacity(&mut history),
            Ok(Command::ModelChanged) => lifecycle.model_changed(),
            Ok(Command::KeepLoaded(keep)) => lifecycle.set_keep_loaded(keep),
            Ok(Command::Load(reply)) => drop(reply.send(lifecycle.ensure_started().is_ok())),
            Ok(Command::Shutdown(reply)) => drop(reply.send(lifecycle.shutdown_if_idle())),
            Err(RecvTimeoutError::Timeout) => lifecycle.tick(),
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }
}

/// SHELL-143.
pub fn may_begin(installing: bool, model_command: bool, model_installed: bool, server_only: bool, authorized: bool) -> bool {
    !installing && !model_command && (model_installed || server_only) && authorized
}

/// `keepsParakeetLoaded`: a server-served dictation never warms the local model.
fn keeps_loaded(cx: &App) -> bool {
    let prefs = &cx.global::<Core>().prefs;
    prefs.bool_or("keepModelReady", false) && !server::routing(prefs).served(server::Service::Dictation)
}

/// `AppServices.start`: composes the session where this platform has every part, and installs the
/// saved shortcut. A build without them keeps the unavailable answers of `Services`.
pub fn start(cx: &mut App) {
    install_saved_shortcut(cx);
    let core = cx.global::<Core>();
    let services = &core.services;
    let parts = (|| {
        Some(Parts {
            mic: services.microphone()?,
            inserter: services.inserter()?,
            launcher: services.speech_launcher(&core.paths.models())?,
            db: Db::open_or_create(&core.paths.database()).ok()?,
            spool_root: core.paths.temporary_audio(),
            pending_dir: core.paths.pending_audio(),
            free_bytes: services.free_bytes_probe(),
        })
    })();
    let Some(parts) = parts else { return };
    let driver = Driver::spawn(parts, keeps_loaded(cx));
    cx.set_global(driver);
    poll_forever(cx);
}

/// SHELL-114's start: a failure is the setup status, as `shortcut.install` failing is in Swift.
fn install_saved_shortcut(cx: &mut App) {
    let core = cx.global::<Core>();
    if core.prefs.string("setup.purpose").as_deref() == Some("meetings") {
        return;
    }
    let json = Shortcut::load(&core.prefs).for_platform(core.services.has_globe_key()).json();
    let installed = core.services.install_shortcut(&json);
    let available = core.services.shortcut_available();
    update_session(cx, |s| {
        s.shortcut_available = available;
        if installed.is_err() {
            s.setup_status = "The dictation shortcut could not be installed. Check Input Monitoring in Settings.".into();
        }
    });
}

/// SHELL-114: `configureShortcut` posted its result.
pub fn shortcut_configured(enabled: bool, cx: &mut App) {
    if cx.has_global::<Session>() {
        update_session(cx, |s| s.setup_status = if enabled { "Shortcut updated." } else { "Shortcut disabled." }.into());
    }
}

fn poll_forever(cx: &mut App) {
    cx.spawn(async move |cx| {
        loop {
            cx.background_executor().timer(POLL).await;
            cx.update(poll);
        }
    })
    .detach();
}

fn poll(cx: &mut App) {
    for event in cx.global::<Core>().services.take_shortcut_events() {
        shortcut(event, cx);
    }
    let events: Vec<Event> = cx.global::<Driver>().events.lock().unwrap().try_iter().collect();
    for event in events {
        apply(event, cx);
    }
    // SET and install paths change these without knowing about this thread.
    let (installed, keep) = (cx.global::<Session>().model_installed, keeps_loaded(cx));
    let available = cx.global::<Core>().services.shortcut_available();
    if cx.global::<Session>().shortcut_available != available {
        update_session(cx, |s| s.shortcut_available = available);
    }
    let driver = cx.global_mut::<Driver>();
    if installed && !driver.model_installed {
        let _ = driver.commands.send(Command::ModelChanged);
    }
    driver.model_installed = installed;
    if keep != driver.keep_loaded {
        driver.keep_loaded = keep;
        let _ = driver.commands.send(Command::KeepLoaded(keep));
    }
}

/// SHELL-143, SHELL-144.
fn shortcut(event: flow_core::dictation::hotkey::Event, cx: &mut App) {
    use flow_core::dictation::hotkey::Event::*;
    match event {
        Pressed => press(cx),
        Released { bypass_rewrite } => {
            if let Some(control) = &cx.global::<Driver>().control {
                control.release(bypass_rewrite);
            }
        }
        Cancelled => {
            if let Some(control) = &cx.global::<Driver>().control {
                control.cancel();
            }
        }
    }
}

fn press(cx: &mut App) {
    let (session, core, driver) = (cx.global::<Session>(), cx.global::<Core>(), cx.global::<Driver>());
    let server_only = server::routing(&core.prefs).served(server::Service::Dictation);
    if driver.running.load(SeqCst) || !may_begin(session.installing, session.model_command, session.model_installed, server_only, driver.mic.authorize()) {
        return;
    }
    let entries = server::load_inputs(&core.prefs);
    let control = Arc::new(Control::default());
    let driver = cx.global_mut::<Driver>();
    driver.running.store(true, SeqCst);
    driver.control = Some(control.clone());
    let _ = driver.commands.send(Command::Begin { control, entries });
    // Escape must work from the press, before the thread's first state arrives.
    cx.global::<Core>().services.set_shortcut_session_active(true);
}

fn state_of(state: State) -> DictState {
    match state {
        State::Idle => DictState::Idle,
        State::Preparing => DictState::Preparing,
        State::Connecting => DictState::Connecting,
        State::Recording => DictState::Recording,
        State::Transcribing => DictState::Transcribing,
        State::Persisting => DictState::Persisting,
        State::Rewriting => DictState::Rewriting,
        State::Inserting => DictState::Inserting,
        State::Cancelling => DictState::Cancelling,
        State::Recovery => DictState::Recovery,
        State::Failed => DictState::Failed,
    }
}

fn session_active(state: State) -> bool {
    !matches!(state, State::Idle | State::Recovery | State::Failed)
}

/// One event from the session thread into `Session`, the pill and the shortcut.
pub fn apply(event: Event, cx: &mut App) {
    match event {
        Event::Changed(snapshot) => changed(snapshot, cx),
        Event::Level(level) => {
            let state = cx.global::<Session>().dictation.as_ref().map_or(DictState::Idle, |d| d.state);
            pill::update_level(state, level, cx);
        }
        Event::Clipboard { uncertain } => pill::show_clipboard(uncertain, cx),
        Event::Action { message, can_retry } => pill::show_action(message, can_retry, cx),
        Event::Microphone(message) => pill::show_microphone(message, cx),
        Event::HistoryChanged => shell::history_changed(cx),
    }
}

fn changed(snapshot: Snapshot, cx: &mut App) {
    let state = state_of(snapshot.state);
    let active = session_active(snapshot.state);
    update_session(cx, |s| {
        let d = s.dictation.get_or_insert_with(Default::default);
        d.state = state;
        d.busy = snapshot.busy;
        d.status = snapshot.status;
        d.unsaved = snapshot.unsaved;
        d.storage_blocked = snapshot.storage_blocked;
        d.capacity_blocked = snapshot.capacity_blocked;
        d.cleanup_blocked = snapshot.cleanup_blocked;
    });
    let level = cx.global::<Session>().pill.level;
    pill::set_state(state, level, cx);
    cx.global::<Core>().services.set_shortcut_session_active(active);
}

/// `Services::session_command` with the running session in front of it.
pub fn session_command(command: SessionCommand, cx: &mut App) -> Result<(), Unavailable> {
    let refused = Err(Unavailable("dictation session"));
    let Some(driver) = cx.try_global::<Driver>() else {
        return cx.global::<Core>().services.session_command(command);
    };
    match command {
        SessionCommand::CancelDictation => {
            if let Some(control) = &driver.control {
                control.cancel();
            }
            Ok(())
        }
        SessionCommand::CancelRewrite => {
            if let Some(control) = &driver.control {
                control.cancel_rewrite();
            }
            Ok(())
        }
        SessionCommand::RetrySave => if driver.ask(Command::RetrySave, REPLY) { Ok(()) } else { refused },
        SessionCommand::RetryStorage => if driver.ask(Command::RetryStorage, REPLY) { Ok(()) } else { refused },
        // The rewrite retry and the correction learner's Undo and Restore have no owner here yet.
        other => cx.global::<Core>().services.session_command(other),
    }
}

/// Swift's `prepareModel` before the first test dictation.
// ponytail: blocks the caller up to 30 s as the page's arming step is synchronous; an async arming step would free the UI.
pub fn load_speech_model(cx: &App) -> Result<(), Unavailable> {
    let Some(driver) = cx.try_global::<Driver>() else {
        return cx.global::<Core>().services.load_speech_model();
    };
    if driver.ask(Command::Load, MODEL_LOAD) { Ok(()) } else { Err(Unavailable("speech model loading")) }
}

/// False while a session holds the worker, for quit.
pub fn shutdown_if_idle(cx: &App) -> bool {
    let Some(driver) = cx.try_global::<Driver>() else { return true };
    !driver.running.load(SeqCst) && driver.ask(Command::Shutdown, REPLY)
}

/// `recheckCapacity` after History frees rows.
pub fn recheck_capacity(cx: &App) {
    if let Some(driver) = cx.try_global::<Driver>() {
        let _ = driver.commands.send(Command::RecheckCapacity);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shell::ensure_session;
    use crate::testing::boot;
    use flow_core::dictation::lifecycle::Spawned;
    use flow_core::dictation::ring::Failure;
    use flow_core::dictation::session::{CapturedTarget, Candidate, InsertOutcome, Input};
    use flow_ui::test::TestAppContext;

    #[test]
    fn the_press_gate_needs_every_condition() {
        assert!(may_begin(false, false, true, false, true));
        assert!(may_begin(false, false, false, true, true), "a server-only setup needs no local model");
        assert!(!may_begin(true, false, true, false, true));
        assert!(!may_begin(false, true, true, false, true));
        assert!(!may_begin(false, false, false, false, true));
        assert!(!may_begin(false, false, true, false, false));
    }

    #[test]
    fn escape_is_live_from_preparing_to_cancelling() {
        let live = [State::Preparing, State::Connecting, State::Recording, State::Transcribing, State::Persisting, State::Rewriting, State::Inserting, State::Cancelling];
        assert!(live.into_iter().all(session_active));
        assert!([State::Idle, State::Recovery, State::Failed].into_iter().all(|s| !session_active(s)));
    }

    #[flow_ui::gpui::test]
    async fn events_reach_the_shell_and_the_pill(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        cx.update(|cx| {
            ensure_session(cx);
            let revision = cx.global::<Session>().history_revision;
            apply(Event::Changed(Snapshot { state: State::Recording, status: "Recording…".into(), busy: true, unsaved: Some("kept".into()), storage_blocked: true, capacity_blocked: false, cleanup_blocked: false, offers_microphones: false }), cx);
            apply(Event::Microphone("No microphone available".into()), cx);
            apply(Event::HistoryChanged, cx);
            let s = cx.global::<Session>();
            let d = s.dictation.as_ref().unwrap();
            assert_eq!((d.state, d.busy, d.status.as_str(), d.unsaved.as_deref(), d.storage_blocked), (DictState::Recording, true, "Recording…", Some("kept"), true));
            assert_eq!(s.pill.state, DictState::Recording);
            assert_eq!(s.pill.microphone.as_ref().unwrap().message, "No microphone available");
            assert_eq!(s.history_revision, revision + 1);
        });
    }

    #[flow_ui::gpui::test]
    async fn without_a_driver_commands_keep_the_services_answer(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        cx.update(|cx| {
            ensure_session(cx);
            start(cx);
            assert!(!cx.has_global::<Driver>(), "fake services have no microphone, so nothing runs");
            assert!(session_command(SessionCommand::RetrySave, cx).is_err());
            assert!(shutdown_if_idle(cx));
        });
    }

    fn doubles(root: &std::path::Path) -> Parts {
        std::fs::create_dir_all(root).unwrap();
        Parts { mic: Arc::new(NoMic(vec![])), inserter: Arc::new(NoField), launcher: Box::new(NoLauncher), db: Db::open_or_create(&root.join("t.sqlite")).unwrap(), spool_root: root.join("spool"), pending_dir: root.join("pending"), free_bytes: Box::new(|| Some(u64::MAX)) }
    }

    // parity: SHELL-143 SHELL-144
    #[flow_ui::gpui::test]
    async fn presses_are_gated_and_release_and_cancel_reach_the_session(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let root = std::env::temp_dir().join(format!("flow-driver-press-{}", std::process::id()));
        cx.update(|cx| {
            use flow_core::dictation::hotkey::Event::*;
            ensure_session(cx);
            cx.set_global(Driver::spawn(doubles(&root), false));
                update_session(cx, |s| s.model_installed = false);
            shortcut(Pressed, cx);
            assert!(cx.global::<Driver>().control.is_none(), "no model: the press does nothing");
            update_session(cx, |s| s.model_installed = true);
            shortcut(Pressed, cx);
            let control = cx.global::<Driver>().control.clone().expect("the press began a session");
            shortcut(Released { bypass_rewrite: true }, cx);
            assert!(control.released() && control.bypassed());
            shortcut(Cancelled, cx);
            assert!(control.cancelled());
        });
        let _ = std::fs::remove_dir_all(&root);
    }

    // parity: SHELL-114
    #[flow_ui::gpui::test]
    async fn configuring_the_shortcut_posts_the_setup_status(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        cx.update(|cx| {
            ensure_session(cx);
            shortcut_configured(true, cx);
            assert_eq!(cx.global::<Session>().setup_status, "Shortcut updated.");
            shortcut_configured(false, cx);
            assert_eq!(cx.global::<Session>().setup_status, "Shortcut disabled.");
        });
    }

    struct NoLauncher;
    impl Launcher for NoLauncher {
        fn launch(&mut self) -> std::io::Result<Spawned> {
            Err(std::io::Error::other("no worker in a test"))
        }
    }
    struct NoMic(Vec<Candidate>);
    impl Mic for NoMic {
        fn authorize(&self) -> bool {
            true
        }
        fn candidates(&self, _: &[InputEntry]) -> Vec<Candidate> {
            self.0.clone()
        }
        fn start(&self, _: &Candidate) -> Result<Box<dyn Input>, Failure> {
            Err(Failure::DeviceLost)
        }
    }
    struct NoField;
    impl Inserter for NoField {
        fn capture_target(&self) -> Option<CapturedTarget> {
            None
        }
        fn insert_once(&self, _: &CapturedTarget, _: &str) -> InsertOutcome {
            InsertOutcome::NotInserted
        }
        fn copy(&self, _: &str) {}
    }

    /// The whole thread with doubles: a press with no microphone, its events, and the commands.
    #[test]
    fn the_thread_runs_a_session_and_answers_commands() {
        let root = std::env::temp_dir().join(format!("flow-driver-{}", std::process::id()));
        let driver = Driver::spawn(doubles(&root), false);
        driver.running.store(true, SeqCst);
        driver.commands.send(Command::Begin { control: Arc::new(Control::default()), entries: vec![] }).unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while driver.running.load(SeqCst) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(!driver.running.load(SeqCst));
        let events: Vec<Event> = driver.events.lock().unwrap().try_iter().collect();
        assert!(events.contains(&Event::Microphone("No microphone available".into())), "{events:?}");
        assert!(driver.ask(Command::Shutdown, REPLY));
        assert!(!driver.ask(Command::Load, REPLY), "the launcher refuses");
        drop(driver);
        let _ = std::fs::remove_dir_all(&root);
    }
}
