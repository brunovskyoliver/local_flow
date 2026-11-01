//! `AppServices`' dictation wiring: one thread owns the coordinator and the speech lifecycle, as its
//! actors do in Swift; this side polls the shortcut and that thread's events on the UI thread.
use crate::core::Core;
use crate::pill;
use crate::shell::{self, DictState, Session, update_session};
use flow_core::db::Db;
use flow_core::dictation::lifecycle::{Launcher, Lifecycle};
use flow_core::dictation::learner::{self, Note, Observation};
use flow_core::dictation::remote::{NoServer, Served};
use flow_core::dictation::retrier::{self, Retrier};
use flow_core::dictation::rewrite::{self, Live, Plan};
use flow_core::dictation::session::{Control, Coordinator, DbHistory, Deps, Event, Inserter, Local, Mic, Recognizer, Rewriter, Rewritten, Snapshot, State};
use flow_core::remote::enrollment::Enrollment;
use flow_core::remote::pool::Pool;
use flow_core::settings::{self as server, InputEntry, Shortcut};
use flow_platform::{Credentials, SessionCommand, Unavailable};
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
    Begin { control: Arc<Control>, entries: Vec<InputEntry>, route: Route },
    RecognizeLocally(String, Sender<bool>),
    TestSpeech(Sender<bool>),
    Unload(Sender<bool>),
    RetrySave(Sender<bool>),
    RetryStorage(Sender<bool>),
    RecheckCapacity,
    ModelChanged,
    KeepLoaded(bool),
    Load(Sender<bool>),
    Shutdown(Sender<bool>),
}

/// Where one press goes; a settings change affects the next.
#[derive(Clone)]
struct Route {
    server: Option<(Arc<Enrollment>, Arc<Pool>, Duration)>,
    local_allowed: bool,
    rewrite: Plan,
}

/// A rewrite reads its key when it runs, on this thread, so the Keychain never delays the recording.
struct KeyedRewrite {
    live: Live,
    credentials: Arc<dyn Credentials>,
}

fn with_key(plan: &mut Plan, credentials: &dyn Credentials) {
    if plan.channel.is_none() {
        plan.secret = credentials.secret_data(&server::rewrite_keychain(&plan.settings.origin)).ok().flatten().and_then(|v| String::from_utf8(v).ok());
        plan.settings.credential_present = plan.secret.is_some();
    }
}

impl Rewriter for KeyedRewrite {
    fn rewrite(&mut self, id: &str, text: &str, started: &mut dyn FnMut(), cancel: &Arc<AtomicBool>) -> Rewritten {
        with_key(&mut self.live.plan, &*self.credentials);
        let plan = &self.live.plan;
        if plan.enabled && plan.channel.is_none() {
            flow_core::local_model::wait_until_ready(&plan.settings.origin, plan.secret.as_deref(), plan.timeout, cancel);
        }
        self.live.rewrite(id, text, started, cancel)
    }
}

pub struct Parts {
    pub mic: Arc<dyn Mic>,
    pub inserter: Arc<dyn Inserter>,
    pub launcher: Box<dyn Launcher>,
    pub db: Db,
    /// For connections of its own: the live rewrite, its retry and the retrier.
    pub database: PathBuf,
    pub credentials: Arc<dyn Credentials>,
    pub spool_root: PathBuf,
    pub pending_dir: PathBuf,
    pub free_bytes: Box<dyn Fn() -> Option<u64> + Send>,
    /// SET-243's full-hash check.
    pub verify_model: Box<dyn Fn() -> Result<(), String> + Send>,
}

pub struct Driver {
    commands: Sender<Command>,
    publish: Sender<Event>,
    events: Mutex<Receiver<Event>>,
    database: PathBuf,
    pending_dir: PathBuf,
    credentials: Arc<dyn Credentials>,
    inserter: Arc<dyn Inserter>,
    /// The running observation's cancel; the setting, read live by its thread.
    observing: Option<Arc<AtomicBool>>,
    learn_corrections: Arc<AtomicBool>,
    /// `routing.served(Dictation)` for the retrier's thread, which has no preferences.
    dictation_served: Arc<AtomicBool>,
    /// The bubble showing, and those waiting for it to end.
    note: Option<Note>,
    notes: std::collections::VecDeque<Note>,
    /// The dictation the last rewrite notice is about, for its Retry.
    action: Option<String>,
    retrier_started: bool,
    /// The recording the "can't wait" alert is about.
    offered: Option<PathBuf>,
    installing: bool,
    mic: Arc<dyn Mic>,
    running: Arc<AtomicBool>,
    control: Option<Arc<Control>>,
    model_installed: bool,
    keep_loaded: bool,
    local_model: flow_core::local_model::Residency,
}
impl Global for Driver {}

impl Driver {
    pub fn spawn(parts: Parts, keep_loaded: bool) -> Driver {
        let (commands, inbox) = channel();
        let (publish, events) = channel();
        let running = Arc::new(AtomicBool::new(false));
        let (mic, flag, sender) = (parts.mic.clone(), running.clone(), publish.clone());
        let (database, pending_dir, credentials, inserter) = (parts.database.clone(), parts.pending_dir.clone(), parts.credentials.clone(), parts.inserter.clone());
        std::thread::Builder::new().name("dictation".into()).spawn(move || serve(parts, keep_loaded, inbox, publish, flag)).expect("the dictation thread starts");
        Driver { commands, publish: sender, events: Mutex::new(events), database, pending_dir, credentials, inserter, observing: None, learn_corrections: Arc::default(), dictation_served: Arc::default(), note: None, notes: Default::default(), action: None, retrier_started: false, offered: None, installing: false, mic, running, control: None, model_installed: false, keep_loaded, local_model: Default::default() }
    }

    fn ask(&self, command: impl FnOnce(Sender<bool>) -> Command, limit: Duration) -> bool {
        let (reply, answer) = mpsc::channel();
        self.commands.send(command(reply)).is_ok() && answer.recv_timeout(limit).unwrap_or(false)
    }
}

fn serve(parts: Parts, keep_loaded: bool, inbox: Receiver<Command>, publish: Sender<Event>, running: Arc<AtomicBool>) {
    let Parts { mic, inserter, launcher, db, database, credentials, spool_root, pending_dir, free_bytes, verify_model } = parts;
    let history_changed = publish.clone();
    let mut lifecycle = Lifecycle::new(launcher, Box::new(Instant::now));
    lifecycle.set_keep_loaded(keep_loaded);
    let mut coordinator = Coordinator::new(spool_root, pending_dir.clone(), Box::new(move |event| drop(publish.send(event))));
    let mut history = DbHistory { db, pending_dir, free_bytes };
    coordinator.verify_admission(&mut history);
    loop {
        match inbox.recv_timeout(TICK) {
            Ok(Command::Begin { control, entries, route }) => {
                let mut local = Local::new(&mut lifecycle);
                let mut no_server = NoServer;
                let mut served;
                let recognizer: &mut dyn Recognizer = match route.server {
                    Some((enrollment, pool, threshold)) => {
                        served = Served::new(enrollment, pool, threshold, &mut local, route.local_allowed);
                        &mut served
                    }
                    None if route.local_allowed => &mut local,
                    None => &mut no_server,
                };
                let mut rewriter = Db::open_or_create(&database).ok().map(|db| KeyedRewrite { live: Live { db, plan: route.rewrite }, credentials: credentials.clone() });
                let mut deps = Deps { mic: mic.as_ref(), inputs: &entries, recognizer, rewriter: rewriter.as_mut().map(|r| r as &mut dyn Rewriter), inserter: inserter.as_ref(), history: &mut history };
                coordinator.run(&mut deps, &control);
                running.store(false, SeqCst);
            }
            Ok(Command::RecognizeLocally(id, reply)) => {
                let done = retrier::recognize_locally(&history.db, &history.pending_dir, &id, &mut Local::new(&mut lifecycle));
                let _ = history_changed.send(Event::HistoryChanged);
                let _ = reply.send(done.is_ok());
            }
            Ok(Command::TestSpeech(reply)) => {
                let works = verify_model().is_ok() && {
                    let mut local = Local::new(&mut lifecycle);
                    let works = local.prepare(&Default::default()).is_ok() && local.recognize(&[0.; 4_800]).is_ok();
                    local.finish();
                    works
                };
                lifecycle.shutdown_if_idle();
                let _ = reply.send(works);
            }
            Ok(Command::Unload(reply)) => drop(reply.send(lifecycle.shutdown_if_idle())),
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

/// What a Mac build runs on with no `flowd-speech` next to it, as the Rust app is until its bundle
/// carries one (Feature 028). Installs say so, a local press fails with the unavailable model's
/// words, and a device served by its server still dictates.
struct NoWorker;
impl Launcher for NoWorker {
    fn launch(&mut self) -> std::io::Result<flow_core::dictation::lifecycle::Spawned> {
        Err(std::io::ErrorKind::NotFound.into())
    }
}

/// `AppServices.start`: composes the session where this platform has a microphone and a field to
/// type in, and installs the saved shortcut. A build without them keeps `Services`' answers.
pub fn start(cx: &mut App) {
    install_saved_shortcut(cx);
    let core = cx.global::<Core>();
    let services = &core.services;
    let parts = (|| {
        Some(Parts {
            mic: services.microphone()?,
            inserter: services.inserter()?,
            launcher: services.speech_launcher(&core.paths.models()).unwrap_or_else(|| Box::new(NoWorker)),
            db: Db::open_or_create(&core.paths.database()).ok()?,
            database: core.paths.database(),
            credentials: services.credentials(),
            spool_root: core.paths.temporary_audio(),
            pending_dir: core.paths.pending_audio(),
            free_bytes: services.free_bytes_probe(),
            verify_model: Box::new(flow_platform::speech::verify_speech_model),
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

/// The local rewrite model, beside the Swift app only: its service and files live there.
fn follow_local_model(cx: &mut App) {
    use flow_core::local_model::{take_wake, wanted, Signals};
    let core = cx.global::<Core>();
    let idle = match server::local_model_idle_unload(&core.prefs) {
        0 => None,
        seconds => Some(Duration::from_secs(seconds as u64)),
    };
    let signals = Signals {
        wanted: core.paths.live && wanted(&core.prefs),
        idle,
        game: core.services.frontmost_game().filter(|_| server::bool_pref(&core.prefs, "unloadLocalModelDuringGames")),
        pressure: core.services.take_memory_pressure(),
        busy: cx.global::<Driver>().running.load(SeqCst) || core.analysis.as_ref().is_some_and(|a| a.busy()),
    };
    let now = std::time::Instant::now();
    let woken = take_wake();
    let game_alive = cx.global::<Driver>().local_model.unloaded_game().is_some_and(|pid| cx.global::<Core>().services.process_running(pid));
    let residency = &mut cx.global_mut::<Driver>().local_model;
    let change = if woken { residency.wake(signals.wanted, now) } else { residency.tick(signals, |_| game_alive, now) };
    if let Some(running) = change {
        cx.global::<Core>().services.set_local_model_running(running);
    }
}

/// `applicationWillTerminate`: the model runs only while the app does.
pub fn stop_local_model(cx: &mut App) {
    if cx.has_global::<Driver>() && cx.global_mut::<Driver>().local_model.stop() {
        cx.global::<Core>().services.set_local_model_running(false);
    }
}

fn poll(cx: &mut App) {
    follow_local_model(cx);
    for event in cx.global::<Core>().services.take_shortcut_events() {
        shortcut(event, cx);
    }
    let events: Vec<Event> = cx.global::<Driver>().events.lock().unwrap().try_iter().collect();
    for event in events {
        apply(event, cx);
    }
    if !cx.global::<Session>().model_installed && cx.global::<Core>().services.install_state(flow_platform::ModelPack::Speech) == flow_platform::InstallState::Verified {
        update_session(cx, |s| {
            s.model_installed = true;
            s.setup_status = "Verified local model available.".into();
        });
    }
    pill::follow_screens(cx);
    release_for_install(cx);
    // SET and install paths change these without knowing about this thread.
    let (installed, keep) = (cx.global::<Session>().model_installed, keeps_loaded(cx));
    let available = cx.global::<Core>().services.shortcut_available();
    if cx.global::<Session>().shortcut_available != available {
        update_session(cx, |s| s.shortcut_available = available);
    }
    publish_routing(cx);
    start_retrier(cx);
    let learn = cx.global::<Core>().prefs.bool_or("learnCorrections", false);
    cx.global::<Driver>().learn_corrections.store(learn, SeqCst);
    next_note(cx);
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

/// Installs replace what the worker has loaded, and SHELL-143's gate refuses a press during one.
fn release_for_install(cx: &mut App) {
    use flow_platform::{InstallState::Running, ModelPack::*};
    let services = &cx.global::<Core>().services;
    let speech = matches!(services.install_state(Speech), Running(..));
    let any = speech || matches!(services.install_state(Meeting), Running(..)) || matches!(services.install_state(Booster), Running(..));
    if cx.global::<Session>().installing != speech {
        update_session(cx, |s| s.installing = speech);
    }
    let driver = cx.global_mut::<Driver>();
    if any && !driver.installing {
        let _ = driver.commands.send(Command::Unload(mpsc::channel().0));
    }
    driver.installing = any;
}

fn publish_routing(cx: &App) {
    let served = server::routing(&cx.global::<Core>().prefs).served(server::Service::Dictation);
    cx.global::<Driver>().dictation_served.store(served, SeqCst);
}

/// `PendingRemoteRetrier`, from the first time this device is approved. A live dictation goes first.
fn start_retrier(cx: &mut App) {
    if cx.global::<Driver>().retrier_started || server::remote_state(&cx.global::<Core>().prefs) != "approved" {
        return;
    }
    let enrollment = cx.global_mut::<Core>().remote().enrollment.clone();
    let driver = cx.global_mut::<Driver>();
    driver.retrier_started = true;
    let Ok(db) = Db::open_or_create(&driver.database) else { return };
    let mut retrier = Retrier::new(db, driver.pending_dir.clone(), enrollment.clone(), driver.running.clone(), driver.dictation_served.clone());
    let (recovered, needed) = (driver.publish.clone(), driver.publish.clone());
    retrier.recovered = Box::new(move |_| drop(recovered.send(Event::HistoryChanged)));
    retrier.decision_needed = Box::new(move |_| drop(needed.send(Event::HistoryChanged)));
    let _ = std::thread::Builder::new().name("pending-retrier".into()).spawn(move || {
        loop {
            if enrollment.settings().state == "approved" {
                retrier.run_due();
            }
            std::thread::sleep(retrier.wait());
        }
    });
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
    // `dictationAdmissionReason`. The finalizing half has no case here: Rust runs no local finalization.
    if cx.global::<Session>().meeting.as_ref().is_some_and(|m| m.state.is_active()) {
        pill::show_action("Meeting in progress", false, cx);
        return;
    }
    let (session, core, driver) = (cx.global::<Session>(), cx.global::<Core>(), cx.global::<Driver>());
    let server_only = server::routing(&core.prefs).served(server::Service::Dictation);
    if driver.running.load(SeqCst) || !may_begin(session.installing, session.model_command, session.model_installed, server_only, driver.mic.authorize()) {
        return;
    }
    // Recording never waits for it; the rewrite after it does.
    flow_core::local_model::wake();
    let entries = server::load_inputs(&core.prefs);
    crate::remote::refresh_if_pending(cx);
    let route = route(cx);
    let control = Arc::new(Control::default());
    // `learner.cancel`: a new dictation ends the observation and hides the bubble.
    update_session(cx, |s| s.pill.learned = None);
    let driver = cx.global_mut::<Driver>();
    if let Some(cancel) = driver.observing.take() {
        cancel.store(true, SeqCst);
    }
    driver.running.store(true, SeqCst);
    driver.control = Some(control.clone());
    let _ = driver.commands.send(Command::Begin { control, entries, route });
    // Escape must work from the press, before the thread's first state arrives.
    cx.global::<Core>().services.set_shortcut_session_active(true);
}

/// `learner.observe` after a confirmed insertion, on its own thread and connection.
fn observe_insertion(inserted: flow_core::dictation::session::Inserted, cx: &mut App) {
    let driver = cx.global_mut::<Driver>();
    let cancelled = Arc::new(AtomicBool::new(false));
    if let Some(previous) = driver.observing.replace(cancelled.clone()) {
        previous.store(true, SeqCst);
    }
    let (database, reader, publish, setting) = (driver.database.clone(), driver.inserter.clone(), driver.publish.clone(), driver.learn_corrections.clone());
    if !setting.load(SeqCst) {
        return;
    }
    let _ = std::thread::Builder::new().name("correction-learner".into()).spawn(move || {
        let Ok(db) = Db::open_or_create(&database) else { return };
        let mut sink = |note| drop(publish.send(Event::Note(note)));
        learner::observe(&mut Observation {
            dictation: &inserted.dictation,
            inserted: &inserted.text,
            target: &inserted.target,
            changes: &inserted.changes,
            reader: reader.as_ref(),
            db: &db,
            enabled: &|| setting.load(SeqCst),
            cancelled: &cancelled,
            poll: learner::POLL_INTERVAL,
            window: learner::OBSERVATION_WINDOW,
            sink: &mut sink,
        });
    });
}

/// `showRetired`: one bubble at a time, the next when it ends.
fn next_note(cx: &mut App) {
    if cx.global::<Session>().pill.learned.is_some() {
        return;
    }
    let driver = cx.global_mut::<Driver>();
    driver.note = driver.notes.pop_front();
    match driver.note.clone() {
        Some(Note::Learned { canonical, .. }) => pill::show_learned(canonical, pill::LearnedKind::Added, cx),
        Some(Note::Retired { alias, .. }) => pill::show_learned(alias.clone(), pill::LearnedKind::Retired { alias }, cx),
        _ => {}
    }
}

/// PILL-072 and PILL-073, against the app's own connection.
fn learned_action(command: SessionCommand, cx: &mut App) -> Result<(), Unavailable> {
    let note = cx.global_mut::<Driver>().note.take();
    let core = cx.global::<Core>();
    let db = core.db.as_ref().ok_or(Unavailable("the dictionary"))?;
    let done = match (command, note) {
        (SessionCommand::UndoLearned, Some(Note::Learned { entry, .. })) => flow_core::dictionary::delete(db, &entry, None).is_ok(),
        (SessionCommand::RestoreLearned, Some(Note::Retired { entry, key, .. })) => flow_core::dictionary::restore_key(db, &entry, &key).is_ok(),
        _ => false,
    };
    shell::history_changed(cx);
    if done { Ok(()) } else { Err(Unavailable("the dictionary")) }
}

/// `RemoteDictationRouter` and `RewriteCoordinator.routed`, at the press.
fn route(cx: &mut App) -> Route {
    let installed = cx.global::<Session>().model_installed;
    let core = cx.global_mut::<Core>();
    let routing = server::routing(&core.prefs);
    let settings = flow_core::remote::enrollment::RemoteSettings::from_prefs(&core.prefs);
    let dictation = routing.served(server::Service::Dictation);
    let rewrite_routed = routing.path(server::Service::Rewrite) == server::Path::Server;
    let remote = (dictation || rewrite_routed).then(|| {
        let remote = core.remote();
        remote.enrollment.load(settings.clone());
        remote
    });
    let prefs = &core.prefs;
    let threshold = Duration::from_millis(server::fallback_threshold(prefs).max(0) as u64);
    let channel = remote.as_ref().filter(|_| rewrite_routed).map(|r| r.pool.clone());
    let rewrite = Plan {
        enabled: prefs.bool_or("rewriteEnabled", false),
        mode: server::rewrite_mode(prefs),
        settings: if channel.is_some() { server::RewriteSettings::routed_to_remote(settings.origin.unwrap_or_default()) } else { server::RewriteSettings::capture(prefs, |_| false) },
        timeout: Duration::from_secs(server::rewrite_timeout(prefs) as u64),
        channel,
        secret: None,
    };
    Route { server: remote.filter(|_| dictation).map(|r| (r.enrollment.clone(), r.pool.clone(), threshold)), local_allowed: installed && !routing.server_only, rewrite }
}

/// The save panel for a kept recording, GPUI's native one. `Ok(None)` when the user cancels.
pub fn save_panel(cx: &App) -> impl Future<Output = Result<Option<PathBuf>, ()>> + use<> {
    let home = std::env::home_dir().unwrap_or_default();
    let answer = cx.prompt_for_new_path(&home, Some("LocalFlow dictation.wav"));
    async move { answer.await.map_err(drop).and_then(|r| r.map_err(drop)) }
}

/// `askAboutUnkeptAudio`: nothing goes without asking.
// ponytail: a second offer while the alert is up replaces the first, whose file goes at the next launch; a queue if that's ever seen.
fn offer_audio(audio: PathBuf, cx: &mut App) {
    if let Some(driver) = cx.try_global::<Driver>().is_some().then(|| cx.global_mut::<Driver>()) {
        driver.offered = Some(audio);
    }
    cx.activate(true);
    if cx.global::<Session>().window.is_none() {
        shell::open_main_window(cx);
    }
    shell::show_alert(shell::Alert::RecordingCantWait, cx);
}

/// SHELL-132, SHELL-133. A cancelled panel or a failed write keeps the file until the next launch,
/// and read and write errors are silent, as in Swift.
pub fn offered_answered(save: bool, cx: &mut App) {
    let audio = cx.try_global::<Driver>().is_some().then(|| cx.global_mut::<Driver>().offered.take()).flatten();
    let Some(audio) = audio else { return };
    if !save {
        let _ = std::fs::remove_file(audio);
        return;
    }
    let panel = save_panel(cx);
    cx.spawn(async move |_| {
        if let Ok(Some(path)) = panel.await
            && flow_core::history::write_wav(&audio, &path).is_ok()
        {
            let _ = std::fs::remove_file(audio);
        }
    })
    .detach();
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
        Event::Action { message, can_retry, dictation } => {
            if let Some(driver) = cx.try_global::<Driver>().is_some().then(|| cx.global_mut::<Driver>()) {
                driver.action = Some(dictation);
            }
            pill::show_action(message, can_retry, cx);
        }
        Event::AudioOffered { audio } => offer_audio(audio, cx),
        Event::Inserted(inserted) => {
            if cx.has_global::<Driver>() {
                observe_insertion(inserted, cx);
            }
        }
        Event::Note(Note::DictionaryChanged) => shell::history_changed(cx),
        Event::Note(note) => {
            if cx.has_global::<Driver>() {
                cx.global_mut::<Driver>().notes.push_back(note);
                next_note(cx);
            }
            shell::history_changed(cx);
        }
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
    let level = cx.global::<Session>().pill.level.get();
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
        SessionCommand::RetryRewrite => {
            let Some(dictation) = driver.action.clone() else { return refused };
            let (database, credentials, publish) = (driver.database.clone(), driver.credentials.clone(), driver.publish.clone());
            let mut plan = route(cx).rewrite;
            // `retry` stores the result and inserts nothing; a failure comes back as a new notice.
            std::thread::spawn(move || {
                let Ok(db) = Db::open_or_create(&database) else { return };
                with_key(&mut plan, &*credentials);
                if let Some((message, can_retry)) = rewrite::retry(&db, &plan, &dictation) {
                    let _ = publish.send(Event::Action { message, can_retry, dictation });
                }
                let _ = publish.send(Event::HistoryChanged);
            });
            Ok(())
        }
        command @ (SessionCommand::UndoLearned | SessionCommand::RestoreLearned) => learned_action(command, cx),
        other => cx.global::<Core>().services.session_command(other),
    }
}

/// HIST-077: on the thread that owns the speech lifecycle, after any running session. `None` without one.
pub fn recognize_locally(id: String, cx: &App) -> Option<Receiver<bool>> {
    let driver = cx.try_global::<Driver>()?;
    let (reply, answer) = mpsc::channel();
    driver.commands.send(Command::RecognizeLocally(id, reply)).ok()?;
    Some(answer)
}

/// Settings › Models: what needs the session thread goes there; the rest is the platform's.
pub fn model_action(action: &str, cx: &App) -> Result<(), Unavailable> {
    let services = &cx.global::<Core>().services;
    match (action, cx.try_global::<Driver>()) {
        ("load", Some(_)) => load_speech_model(cx),
        ("unload", Some(driver)) => if !driver.running.load(SeqCst) && driver.ask(Command::Unload, REPLY) { Ok(()) } else { Err(Unavailable("speech model unloading")) },
        _ => services.settings_action(action),
    }
}

/// SET-243: verify, load, one silent window, release. The answer comes when it's done.
pub fn test_model(name: &str, cx: &App) -> Receiver<bool> {
    let (reply, answer) = mpsc::channel();
    let services = &cx.global::<Core>().services;
    match cx.try_global::<Driver>().filter(|d| name == "speech" && !d.running.load(SeqCst)) {
        Some(driver) => drop(driver.commands.send(Command::TestSpeech(reply))),
        None => drop(reply.send(services.settings_action(&format!("test.{name}")).is_ok())),
    }
    answer
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
pub(crate) mod tests {
    use super::*;
    use crate::shell::ensure_session;
    use crate::testing::boot;
    use flow_core::dictation::lifecycle::Spawned;
    use flow_core::dictation::ring::Failure;
    use flow_core::remote::scripted::Reply;
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
        Parts { mic: Arc::new(NoMic(vec![])), inserter: Arc::new(NoField), launcher: Box::new(NoLauncher), db: Db::open_or_create(&root.join("t.sqlite")).unwrap(), database: root.join("t.sqlite"), credentials: Arc::new(flow_platform::NoCredentials), spool_root: root.join("spool"), pending_dir: root.join("pending"), free_bytes: Box::new(|| Some(u64::MAX)), verify_model: Box::new(|| Ok(())) }
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

    /// A session on the worker's thread, for quit.
    pub(crate) fn hold_the_worker(cx: &mut App) {
        let root = std::env::temp_dir().join(format!("flow-driver-hold-{}", std::process::id()));
        let driver = Driver::spawn(doubles(&root), false);
        driver.running.store(true, SeqCst);
        cx.set_global(driver);
    }

    pub(crate) fn offer(audio: PathBuf, cx: &mut App) {
        let root = audio.parent().unwrap().join("driver");
        cx.set_global(Driver::spawn(doubles(&root), false));
        apply(Event::AudioOffered { audio }, cx);
    }

    // parity: SHELL-143
    #[flow_ui::gpui::test]
    async fn an_install_refuses_a_press_until_it_ends(cx: &mut TestAppContext) {
        use flow_platform::{InstallState, ModelPack};
        boot(cx, Mode::Light);
        let root = std::env::temp_dir().join(format!("flow-driver-installing-{}", std::process::id()));
        cx.update(|cx| {
            ensure_session(cx);
            cx.set_global(Driver::spawn(doubles(&root), false));
            update_session(cx, |s| s.model_installed = true);
            let fake = flow_platform::Fake::default();
            fake.install_states.borrow_mut().insert(ModelPack::Speech, InstallState::Running(1, 2, false));
            cx.global_mut::<Core>().services = Box::new(fake);
            poll(cx);
            assert!(cx.global::<Session>().installing && cx.global::<Driver>().installing);
            shortcut(flow_core::dictation::hotkey::Event::Pressed, cx);
            assert!(cx.global::<Driver>().control.is_none(), "refused during the install");
            cx.global_mut::<Core>().services = Box::new(flow_platform::Fake::default());
            poll(cx);
            assert!(!cx.global::<Session>().installing);
            shortcut(flow_core::dictation::hotkey::Event::Pressed, cx);
            assert!(cx.global::<Driver>().control.is_some(), "allowed again");
        });
        let _ = std::fs::remove_dir_all(&root);
    }

    // parity: PILL-106
    #[flow_ui::gpui::test]
    async fn an_active_meeting_refuses_a_press_with_its_notice(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let root = std::env::temp_dir().join(format!("flow-driver-meeting-{}", std::process::id()));
        cx.update(|cx| {
            use crate::shell::MeetingStatus;
            use flow_core::dictation::hotkey::Event::Pressed;
            ensure_session(cx);
            cx.set_global(Driver::spawn(doubles(&root), false));
            update_session(cx, |s| {
                s.model_installed = true;
                s.meeting = Some(MeetingStatus { id: "m".into(), title: None, state: crate::shell::MeetingState::Recording, elapsed_ms: 0 });
            });
            shortcut(Pressed, cx);
            assert!(cx.global::<Driver>().control.is_none(), "the meeting keeps the microphone");
            assert_eq!(cx.global::<Session>().pill.action.as_ref().map(|a| a.message.as_str()), Some("Meeting in progress"));
        });
        let _ = std::fs::remove_dir_all(&root);
    }

    // parity: PILL-086
    #[flow_ui::gpui::test]
    async fn a_notice_arms_retry(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let root = std::env::temp_dir().join(format!("flow-driver-notice-{}", std::process::id()));
        cx.update(|cx| {
            ensure_session(cx);
            cx.set_global(Driver::spawn(doubles(&root), false));
            assert!(session_command(SessionCommand::RetryRewrite, cx).is_err(), "no notice to retry");
            apply(Event::Action { message: "Rewrite took too long. Original text inserted.".into(), can_retry: true, dictation: "d1".into() }, cx);
            assert_eq!(cx.global::<Driver>().action.as_deref(), Some("d1"));
            assert!(cx.global::<Session>().pill.action.is_some());
            assert!(session_command(SessionCommand::RetryRewrite, cx).is_ok());
        });
        let _ = std::fs::remove_dir_all(&root);
    }

    #[flow_ui::gpui::test]
    async fn the_retriers_gate_follows_routing(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let root = std::env::temp_dir().join(format!("flow-driver-served-{}", std::process::id()));
        cx.update(|cx| {
            ensure_session(cx);
            cx.set_global(Driver::spawn(doubles(&root), false));
            let core = cx.global_mut::<Core>();
            core.prefs.set("remote.enabled", true);
            core.prefs.set("remote.consentVersion", 99_i64);
            core.prefs.set("remote.serverURL", "https://flow.example.com");
            core.prefs.set("remote.state", "approved");
            publish_routing(cx);
            assert!(cx.global::<Driver>().dictation_served.load(SeqCst));
            cx.global_mut::<Core>().prefs.set("server.override.dictation", "thisMac");
            publish_routing(cx);
            assert!(!cx.global::<Driver>().dictation_served.load(SeqCst), "this Mac: nothing retries on the server");
        });
        let _ = std::fs::remove_dir_all(&root);
    }

    // parity: SET-048
    #[flow_ui::gpui::test]
    async fn a_press_refreshes_a_pending_device_and_routes_by_the_settings_at_that_moment(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let root = std::env::temp_dir().join(format!("flow-driver-route-{}", std::process::id()));
        cx.update(|cx| {
            ensure_session(cx);
            update_session(cx, |s| s.model_installed = true);
            cx.set_global(Driver::spawn(doubles(&root), false));
            let plain = route(cx);
            assert!(plain.server.is_none() && plain.local_allowed && !plain.rewrite.enabled, "off: this Mac");
            let installed = crate::remote::testing::install(cx, vec![Reply::ready(), Reply::tokens("a", "r")], true);
            use flow_core::remote::{DeviceKeys, Secrets};
            let (handle, _) = installed.keys.create().unwrap();
            installed.secrets.write("device-key", &handle).unwrap();
            installed.secrets.write("refresh-token", b"lfr_1").unwrap();
            let core = cx.global_mut::<Core>();
            core.prefs.set("remote.enabled", true);
            core.prefs.set("remote.consentVersion", 99_i64);
            core.prefs.set("remote.serverURL", "https://flow.example.com");
            core.prefs.set("server.only", true);
            core.prefs.set("remote.state", "pending");
            assert!(route(cx).server.is_none(), "pending doesn't stream yet");
            assert!(!route(cx).local_allowed, "server only");
            shortcut(flow_core::dictation::hotkey::Event::Pressed, cx);
            assert_eq!(installed.counters.opened(), 0, "the press doesn't wait for the refresh");
        });
        cx.run_until_parked();
        cx.update(|cx| {
            assert_eq!(flow_core::settings::remote_state(&cx.global::<Core>().prefs), "approved");
            let served = route(cx);
            assert!(served.server.is_some() && served.rewrite.channel.is_some(), "approved now: dictation and rewrite both go to the server");
            assert!(served.rewrite.settings.via_channel);
        });
        let _ = std::fs::remove_dir_all(&root);
    }

    // parity: PILL-074
    #[flow_ui::gpui::test]
    async fn notes_queue_one_bubble_and_undo_and_restore_change_the_dictionary(cx: &mut TestAppContext) {
        use flow_core::dictionary::{self, Entry};
        boot(cx, Mode::Light);
        let root = std::env::temp_dir().join(format!("flow-driver-notes-{}", std::process::id()));
        cx.update(|cx| {
            ensure_session(cx);
            cx.set_global(Driver::spawn(doubles(&root), false));
            let db = cx.global::<Core>().db.as_ref().unwrap();
            let entry = |id: &str, word: &str| Entry { id: id.into(), canonical: word.into(), aliases: vec![], enabled: true, learned_at: Some(1) };
            dictionary::save(db, &entry("a", "Alpha"), None, "provisional").unwrap();
            dictionary::save(db, &entry("b", "Beta"), None, "provisional").unwrap();
            let key = "boost".to_string();
            db.conn.execute("UPDATE dictionary_key_usage SET state='retired', retired_at=1, retired_from='provisional', reverted=1 WHERE entry_id='b'", []).unwrap();

            apply(Event::Note(Note::Learned { entry: "a".into(), canonical: "Alpha".into() }), cx);
            apply(Event::Note(Note::Retired { entry: "b".into(), key: key.clone(), alias: "Beta".into() }), cx);
            assert_eq!(cx.global::<Session>().pill.learned.as_ref().unwrap().word, "Alpha", "the second waits");
            assert_eq!(cx.global::<Driver>().notes.len(), 1);

            session_command(SessionCommand::UndoLearned, cx).unwrap();
            let entries = dictionary::load(cx.global::<Core>().db.as_ref().unwrap()).unwrap().entries;
            assert!(!entries.iter().any(|e| e.id == "a") && entries.iter().any(|e| e.id == "b"), "Undo removes only the learned entry");
            update_session(cx, |s| s.pill.learned = None);
            next_note(cx);
            assert_eq!(cx.global::<Session>().pill.learned.as_ref().unwrap().word, "Beta");
            assert!(session_command(SessionCommand::UndoLearned, cx).is_err(), "a retired bubble has no Undo");

            apply(Event::Note(Note::Retired { entry: "b".into(), key: key.clone(), alias: "Beta".into() }), cx);
            update_session(cx, |s| s.pill.learned = None);
            next_note(cx);
            session_command(SessionCommand::RestoreLearned, cx).unwrap();
            let usage = dictionary::usage(cx.global::<Core>().db.as_ref().unwrap()).unwrap();
            assert_eq!(usage["b"].iter().find(|u| u.key_id == key).unwrap().state, "established");
        });
        let _ = std::fs::remove_dir_all(&root);
    }

    // parity: SET-250 SET-251
    #[flow_ui::gpui::test]
    async fn load_and_unload_go_to_the_session_thread_and_a_failed_test_says_so(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let root = std::env::temp_dir().join(format!("flow-driver-models-{}", std::process::id()));
        cx.update(|cx| {
            ensure_session(cx);
            cx.set_global(Driver::spawn(doubles(&root), false));
            assert!(model_action("load", cx).is_err(), "no worker to load");
            assert!(model_action("unload", cx).is_ok());
            assert!(!test_model("speech", cx).recv_timeout(REPLY).unwrap(), "verified, but nothing can run it");
        });
        let _ = std::fs::remove_dir_all(&root);
    }

        #[flow_ui::gpui::test]
    async fn an_install_that_verifies_turns_dictation_on_and_tells_the_session_thread(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let root = std::env::temp_dir().join(format!("flow-driver-install-{}", std::process::id()));
        cx.update(|cx| {
            ensure_session(cx);
            cx.set_global(Driver::spawn(doubles(&root), false));
            update_session(cx, |s| s.model_installed = false);
            poll(cx);
            assert!(!cx.global::<Session>().model_installed);
            let fake = flow_platform::Fake::default();
            fake.install_states.borrow_mut().insert(flow_platform::ModelPack::Speech, flow_platform::InstallState::Verified);
            cx.global_mut::<Core>().services = Box::new(fake);
            poll(cx);
            assert!(cx.global::<Session>().model_installed);
            assert_eq!(cx.global::<Session>().setup_status, "Verified local model available.");
            assert!(cx.global::<Driver>().model_installed, "ModelChanged went to the lifecycle");
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
    // parity: SET-243
    fn the_thread_runs_a_session_and_answers_commands() {
        let root = std::env::temp_dir().join(format!("flow-driver-{}", std::process::id()));
        let driver = Driver::spawn(doubles(&root), false);
        driver.running.store(true, SeqCst);
        let rewrite = Plan { enabled: false, mode: "clean", settings: Default::default(), timeout: REPLY, channel: None, secret: None };
        driver.commands.send(Command::Begin { control: Arc::new(Control::default()), entries: vec![], route: Route { server: None, local_allowed: true, rewrite } }).unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while driver.running.load(SeqCst) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(!driver.running.load(SeqCst));
        let events: Vec<Event> = driver.events.lock().unwrap().try_iter().collect();
        assert!(events.contains(&Event::Microphone("No microphone available".into())), "{events:?}");
        assert!(driver.ask(Command::Shutdown, REPLY));
        assert!(!driver.ask(Command::Load, REPLY), "the launcher refuses");
        assert!(!driver.ask(Command::TestSpeech, REPLY), "no worker: the test reports it");
        assert!(driver.ask(Command::Unload, REPLY));
        drop(driver);
        let _ = std::fs::remove_dir_all(&root);
    }
}
