//! The main window: onboarding gate, sidebar, content card and router, and `Session`, the plain
//! view model standing in for Swift's `AppServices` until capture and models exist.
use crate::core::Core;
use crate::insertion::{self, Delivery, Insertion, Phase, Quality, ReviewEntry};
use crate::pages::{Page, dictionary::DictionaryPage, history::HistoryPage, insights::InsightsPage, notetaker::NotetakerPage, onboarding::OnboardingPage, settings::SettingsPage};
use crate::pill::Pill;
use flow_platform::{Permission, PermissionState, SessionCommand};
use flow_ui::components::prototype_nav;
use flow_ui::prelude::*;
use flow_ui::tokens::{Palette, set_mode};
use std::time::Duration;

/// `DictationSession.State`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum DictState {
    Idle,
    Preparing,
    Connecting,
    Recording,
    Transcribing,
    Persisting,
    Rewriting,
    Inserting,
    Cancelling,
    Recovery,
    Failed,
}

/// What `DictationCoordinator` publishes to the shell.
#[derive(Clone)]
pub struct Dictation {
    pub state: DictState,
    pub busy: bool,
    pub status: String,
    pub unsaved: Option<String>,
    pub storage_blocked: bool,
    pub capacity_blocked: bool,
    pub cleanup_blocked: bool,
}

impl Default for Dictation {
    fn default() -> Self {
        Dictation {
            state: DictState::Idle,
            busy: false,
            status: "Install a verified speech model to begin.".into(),
            unsaved: None,
            storage_blocked: false,
            capacity_blocked: false,
            cleanup_blocked: false,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum MeetingState {
    Created,
    Preparing,
    Recording,
    Paused,
    Finalizing,
    Completed,
    Interrupted,
    Failed,
}

impl MeetingState {
    pub fn is_active(self) -> bool {
        matches!(self, Self::Created | Self::Preparing | Self::Recording | Self::Paused | Self::Finalizing)
    }
    pub fn badge_text(self) -> &'static str {
        match self {
            Self::Created => "Created",
            Self::Preparing => "Preparing",
            Self::Recording => "Recording",
            Self::Paused => "Paused",
            Self::Finalizing => "Finalizing",
            Self::Completed => "Completed",
            Self::Interrupted => "Interrupted",
            Self::Failed => "Failed",
        }
    }
}

#[derive(Clone)]
pub struct MeetingStatus {
    pub id: String,
    pub title: Option<String>,
    pub state: MeetingState,
    pub elapsed_ms: i64,
}

/// Swift's `AppServices.setupStatus` copy that only later features can trigger; the unavailable
/// views and the menu bar already display whichever is current.
pub const SETUP_STATUS_COPY: &[&str] = &[
    "The bundled AI helper could not restart. It will retry before the next request.",
    "Verified local model available.",
    "Import the pinned model before dictating.",
    "Whisper Turbo import failed. Install it in Settings to finalize meetings.",
    "Running the resource benchmark…",
    "Benchmark failed; see its result file.",
    "Benchmark complete.",
    "Running the remote dictation benchmark…",
    "Could not prepare speech model. ",
    "Preparing speech model…",
    "Speech model ready. Hold the shortcut to dictate.",
    "Local model files verified.",
    "Local model verification failed. Verify or reinstall the model in Settings.",
    "Whisper Turbo verified.",
    "Install Whisper Turbo in Settings to finalize meetings.",
    "Install or verify Whisper Turbo in Settings to finalize meetings.",
    "Whisper Turbo verified. Final meeting transcripts use it locally.",
    "Speaker labeling model verified.",
    "Speaker labeling model isn't installed.",
    "Term booster verified. Dictionary terms are checked against your speech.",
    "Shortcut updated.",
    "Shortcut disabled.",
    "The chosen speech model is missing; dictating with Parakeet v3.",
    "Dictation now uses Parakeet v3.",
    "Parakeet v3 downloaded and verified.",
    "Parakeet v3 download cancelled.",
    "Parakeet v3 download failed. Check the connection and available storage.",
    "Microphone allowed.",
    "Microphone permission is needed for dictation.",
    "Accessibility allowed. Insertion is available in supported fields.",
    "Enable LocalFlow in Accessibility settings. The app is shown in Finder if you need to add it.",
    "Meeting models did not finish downloading. Retry in Settings.",
    "Downloading model files…",
    "Importing model files…",
    "Model verified. Hold the shortcut for a short test.",
    "Provisioning unavailable: the pinned manifest is missing verified hashes.",
    "Model installation cancelled.",
    "Installation failed. Check the pinned files, connection and available storage.",
];

/// Sidebar rows above the spacer, then Settings under its divider.
const NAV: [(Page, &str, &str, &str); 5] = [
    (Page::Meetings, "Notetaker", "record.circle", "navigation.notetaker"),
    (Page::History, "Transcriptions", "mic", "navigation.transcriptions"),
    (Page::Insights, "Insights", "chart.bar", "navigation.insights"),
    (Page::Dictionary, "Dictionary", "text.book.closed", "navigation.dictionary"),
    (Page::Settings, "Settings", "gearshape", "navigation.settings"),
];

pub const SETUP_STARTING: &str = "Starting…";
pub const SETUP_FAILED: &str = "Setup could not finish. Check app storage and the model manifest.";

/// A native alert, as Swift's SwiftUI `.alert` and `NSAlert` are. Set while one is on screen.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Alert {
    DiscardUnsaved,
    QuitUnsaved,
    RecordingCantWait,
}

/// The state Swift keeps on `AppServices`, `MainWindowRouter` and the coordinators.
pub struct Session {
    /// Unfinished setup kept across a closed window, as Swift's coordinator is.
    pub parked_setup: Option<flow_core::onboarding::Setup>,
    pub selection: Page,
    /// Settings scrolls here once shown, then clears it. The settings page takes it.
    pub microphones_anchor: bool,
    /// Meeting (and tab) the Notetaker page should open next. The Notetaker page takes it.
    pub open_meeting: Option<(String, Option<&'static str>)>,
    pub window: Option<AnyWindowHandle>,
    pub window_focused: bool,
    pub setup_status: String,
    /// Stores exist. False before start and when the database can't open.
    pub stores_ready: bool,
    pub dictation: Option<Dictation>,
    pub meetings_available: bool,
    pub meeting: Option<MeetingStatus>,
    /// `MeetingCoordinator.canStart`: reconciliation complete, no active meeting, not busy.
    pub can_start_meeting: bool,
    pub installing: bool,
    pub model_command: bool,
    pub model_installed: bool,
    pub shortcut_available: bool,
    pub alert: Option<Alert>,
    pub quitting: bool,
    pub ready_to_terminate: bool,
    pub insertion: Insertion,
    pub pill: Pill,
    /// Bumped whenever saved dictations change; Insights watches it while selected.
    pub history_revision: u64,
}
impl Global for Session {}

impl Session {
    pub fn new(core: &Core) -> Session {
        let stores_ready = core.db.is_some();
        let mut s = Session {
            parked_setup: None,
            selection: landing_page(core),
            microphones_anchor: false,
            open_meeting: None,
            window: None,
            window_focused: false,
            setup_status: if stores_ready { SETUP_STARTING.into() } else { SETUP_FAILED.into() },
            stores_ready,
            dictation: stores_ready.then(Dictation::default),
            meetings_available: stores_ready,
            meeting: None,
            can_start_meeting: false,
            installing: false,
            model_command: false,
            model_installed: false,
            shortcut_available: false,
            alert: None,
            quitting: false,
            ready_to_terminate: false,
            insertion: Insertion::default(),
            pill: Pill::default(),
            history_revision: 0,
        };
        if let Some(scenario) = core.scenario.as_deref() {
            s.apply_scenario(scenario);
        }
        s
    }

    /// `LOCALFLOW_SCENARIO=shell.<state>` selects what fixture data can't reach.
    fn apply_scenario(&mut self, scenario: &str) {
        let meeting = |state, title: Option<&str>| Some(MeetingStatus { id: "scenario".into(), title: title.map(Into::into), state, elapsed_ms: 754_000 });
        let d = self.dictation.get_or_insert_with(Dictation::default);
        match scenario {
            "shell.starting" => {
                self.dictation = None;
                self.stores_ready = false;
                self.meetings_available = false;
            }
            "shell.storage-blocked" => {
                d.storage_blocked = true;
                d.status = "Storage is unavailable. Check free disk space and Retry storage.".into();
            }
            "shell.capacity-blocked" => {
                d.capacity_blocked = true;
                d.status = "History is full. Explicitly delete saved text before recording again.".into();
            }
            "shell.unsaved" => {
                d.unsaved = Some("Synthetic unsaved dictation text for the audit.".into());
                d.status = "Text could not be saved.".into();
            }
            "shell.unsaved-busy" => {
                d.unsaved = Some("Synthetic unsaved dictation text for the audit.".into());
                d.storage_blocked = true;
                d.busy = true;
            }
            "shell.failed" => d.state = DictState::Failed,
            "shell.review" => {
                d.busy = true;
                self.insertion.entry = Some(ReviewEntry { id: "scenario".into(), text: "Move the kickoff to Thursday and ask Northwind to send the updated floor plan before noon.".into(), quality: Quality::Complete, delivery: Delivery::None });
                self.insertion.phase = Phase::Reviewing;
            }
            "shell.discard-alert" => {
                d.unsaved = Some("Synthetic unsaved dictation text for the audit.".into());
                self.alert = Some(Alert::DiscardUnsaved);
            }
            "shell.quit-alert" => {
                d.unsaved = Some("Synthetic unsaved dictation text for the audit.".into());
                self.alert = Some(Alert::QuitUnsaved);
            }
            "shell.recording-cant-wait" => self.alert = Some(Alert::RecordingCantWait),
            "shell.note-recording" => self.meeting = meeting(MeetingState::Recording, Some("Weekly planning")),
            "shell.note-paused" => self.meeting = meeting(MeetingState::Paused, Some("Weekly planning")),
            "shell.note-preparing" => self.meeting = meeting(MeetingState::Preparing, Some("Weekly planning")),
            "shell.note-untitled" => self.meeting = meeting(MeetingState::Finalizing, None),
            _ => {}
        }
    }

    /// `AppServices.needsAttention`.
    pub fn needs_attention(&self) -> bool {
        self.dictation.as_ref().is_some_and(|d| d.unsaved.is_some() || d.storage_blocked || d.capacity_blocked || d.state == DictState::Failed)
    }

    /// `AppServices.readinessStatus`.
    pub fn readiness(&self, mic: PermissionState, server_only: bool, meetings_purpose: bool) -> String {
        let Some(d) = &self.dictation else { return self.setup_status.clone() };
        if d.busy || self.needs_attention() {
            return d.status.clone();
        }
        if self.installing {
            return "Installing speech model…".into();
        }
        if self.model_command {
            return "Preparing speech model…".into();
        }
        if !self.model_installed && !server_only {
            return "Install the local speech model in Settings.".into();
        }
        if mic != PermissionState::Granted {
            return "Allow Microphone in Settings.".into();
        }
        if meetings_purpose {
            return "Ready · start a meeting in Notetaker".into();
        }
        if !self.shortcut_available {
            return "Enable the shortcut and Input Monitoring in Settings.".into();
        }
        "Ready · hold your shortcut to dictate".into()
    }

    /// `AppServices.updateBusy`, for the parts of the gate this client has.
    pub fn update_busy(&self) -> bool {
        self.quitting
            || self.installing
            || self.model_command
            || self.dictation.as_ref().is_some_and(|d| d.busy || d.unsaved.is_some())
            || self.meeting.as_ref().is_some_and(|m| m.state.is_active())
    }
}

/// Mutates `Session` and wakes every observer: windows, the tray and the pill.
pub fn update_session<R>(cx: &mut App, f: impl FnOnce(&mut Session) -> R) -> R {
    cx.update_global::<Session, R>(|s, _| f(s))
}

/// Run from `Shell::new` too, so a test can open a shell after a plain `boot`.
pub fn ensure_session(cx: &mut App) {
    if !cx.has_global::<Session>() {
        let s = Session::new(cx.global::<Core>());
        cx.set_global(s);
    }
}

pub fn readiness(cx: &App) -> String {
    let core = cx.global::<Core>();
    cx.global::<Session>().readiness(
        core.services.permission(Permission::Microphone),
        core.prefs.bool_or("server.only", false),
        core.prefs.string("setup.purpose").as_deref() == Some("meetings"),
    )
}

/// `preferences.landingPage`: Notetaker when `purpose == .meetings`, otherwise Transcriptions.
pub fn landing_page(core: &Core) -> Page {
    if let Some(p) = std::env::var("LOCALFLOW_PAGE").ok().as_deref().and_then(page_named) {
        return p;
    }
    match core.prefs.string("setup.purpose").as_deref() {
        Some("meetings") => Page::Meetings,
        _ => Page::History,
    }
}

fn page_named(n: &str) -> Option<Page> {
    Some(match n {
        "meetings" => Page::Meetings,
        "history" => Page::History,
        "insights" => Page::Insights,
        "dictionary" => Page::Dictionary,
        "settings" => Page::Settings,
        _ => return None,
    })
}

const DEFAULT_SIZE: Size<Pixels> = size(px(1100.), px(760.));
const MIN_SIZE: Size<Pixels> = size(px(720.), px(560.));

/// `AppServices.start()`, as far as this client has services: appearance, launch recovery of
/// meetings and the model check. Runs at launch only, so the tests' `boot` leaves it out.
pub fn start(cx: &mut App) {
    apply_appearance(cx);
    cx.global_mut::<Core>().reconcile_meetings();
    let verified = cx.global::<Core>().services.speech_model_verified();
    let (reconciled, stores) = (cx.global::<Core>().reconciled, cx.global::<Core>().db.is_some());
    update_session(cx, |s| {
        s.model_installed = verified;
        s.can_start_meeting = reconciled;
        if stores {
            s.setup_status = if verified { "Verified local model available." } else { "Import the pinned model before dictating." }.into();
        }
    });
}

/// `applyAppearance()`: the `appearance` preference over the system's, plus Increase Contrast.
/// The settings page calls this after writing the preference.
pub fn apply_appearance(cx: &mut App) {
    let preference = match cx.global::<Core>().prefs.string("appearance").as_deref() {
        Some("dark") => Some(true),
        Some("light") => Some(false),
        _ => None,
    };
    let _ = cx.global::<Core>().services.set_app_appearance(preference);
    let dark = match preference {
        Some(dark) => dark,
        None => matches!(cx.window_appearance(), WindowAppearance::Dark | WindowAppearance::VibrantDark),
    };
    let contrast = cx.global::<Core>().services.high_contrast();
    let mode = Mode::new(dark, contrast);
    if pal(cx).mode != mode {
        set_mode(mode, cx);
        cx.refresh_windows();
    }
}

/// Rereads display options, as Swift does on `accessibilityDisplayOptionsDidChangeNotification`.
// ponytail: read on app activation rather than from the notification; a change made while LocalFlow stays frontmost waits for the next activation.
fn refresh_display_options(cx: &mut App) {
    let reduce = cx.global::<Core>().services.reduce_motion();
    cx.global_mut::<Flow>().reduce_motion = reduce;
    cx.set_reduce_motion(reduce);
    apply_appearance(cx);
}

/// `observeSettingsWhileVisible`'s condition: an active window on Settings or unfinished setup.
fn polls(selection: Page, onboarded: bool, active: bool) -> bool {
    active && (selection == Page::Settings || !onboarded)
}

/// `MainWindowRouter.open`: select, become a regular app, open or restore the window, activate.
pub fn open(destination: Option<Page>, cx: &mut App) {
    if let Some(page) = destination {
        update_session(cx, |s| s.selection = page);
    }
    cx.set_activation_policy(ActivationPolicy::Regular);
    // `window_closed` clears this. `update_window` also fails while the window is mid-update, so its
    // result can't stand in for "closed": a menu press during a frame would open a second window.
    match cx.global::<Session>().window {
        Some(window) => cx.defer(move |cx| {
            let _ = cx.update_window(window.into(), |_, w, _| w.activate_window());
        }),
        None => open_main_window(cx),
    }
    cx.activate(true);
}

/// `MainWindowRouter.showSettings(at: .microphones)`.
pub fn show_microphones(cx: &mut App) {
    update_session(cx, |s| s.microphones_anchor = true);
    open(Some(Page::Settings), cx);
}

/// Title "LocalFlow", default 1100 x 760, minimum 720 x 560, hidden titlebar with the traffic lights kept.
fn main_window_options(cx: &App) -> WindowOptions {
    WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(Bounds::centered(None, DEFAULT_SIZE, cx))),
        titlebar: Some(TitlebarOptions { title: Some("LocalFlow".into()), appears_transparent: true, traffic_light_position: Some(point(px(9.), px(9.))) }),
        window_min_size: Some(MIN_SIZE),
        ..Default::default()
    }
}

pub fn open_main_window(cx: &mut App) {
    // The audit opens a window that takes no focus and stays out of the tiling layout.
    let audit = std::env::var_os("LOCALFLOW_AUDIT_WINDOW").is_some();
    let options = if audit {
        let length = |name, default| std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default);
        let bounds = Bounds { origin: point(px(30.), px(60.)), size: size(px(length("LOCALFLOW_AUDIT_WIDTH", 1180.)), px(length("LOCALFLOW_AUDIT_HEIGHT", 780.))) };
        WindowOptions { window_bounds: Some(WindowBounds::Windowed(bounds)), titlebar: None, focus: false, kind: WindowKind::PopUp, is_movable: false, ..Default::default() }
    } else {
        main_window_options(cx)
    };
    let (handle, _) = flow_ui::open_window(options, cx, |w, cx| cx.new(|cx| Shell::new(w, cx))).expect("main window opens");
    update_session(cx, |s| s.window = Some(handle));
    tag_main_window(handle, cx);
}

/// `attach(window)`: Swift's `localflow.main`, which the system reads as the AX identifier.
fn tag_main_window(handle: AnyWindowHandle, cx: &mut App) {
    let _ = handle.update(cx, |_, w, cx| cx.global::<Core>().services.set_window_identifier(w, "localflow.main"));
}

/// `flushMeetingNotes`, from quit. A closing window flushes through `Shell`'s release.
pub fn flush_notes(cx: &mut App) {
    let shell = cx.global::<Session>().window.and_then(|w| w.downcast::<Shell>());
    if let Some(shell) = shell {
        let _ = shell.update(cx, |shell, _, cx| shell.meetings.update(cx, |page, cx| page.flush_notes(cx)));
    }
}

/// `AppServices`' history observer: the selected Insights page re-reads when dictations change.
pub fn history_changed(cx: &mut App) {
    update_session(cx, |s| s.history_revision += 1);
}

/// Closing keeps the app in the menu bar; the policy drops back so the Dock icon goes.
pub fn window_closed(id: WindowId, cx: &mut App) {
    if cx.global::<Session>().window.map(|w| w.window_id()) != Some(id) {
        return;
    }
    // The sheet went with its window: `closeInsertionReview`.
    if cx.global::<Session>().insertion.is_reviewing() {
        insertion::cancel(cx);
    }
    update_session(cx, |s| {
        s.window = None;
        s.window_focused = false;
    });
    cx.set_activation_policy(ActivationPolicy::Accessory);
}

/// The Notetaker page takes `open_meeting` when it next renders.
fn open_note(id: String, cx: &mut App) {
    update_session(cx, |s| {
        s.selection = Page::Meetings;
        s.open_meeting = Some((id, None));
    });
}

/// `coordinator.cancel(source:)`: insertion first, a rewrite only, else the session when busy.
pub fn cancel_dictation(cx: &mut App) {
    if cx.global::<Session>().insertion.is_active() {
        insertion::cancel(cx);
        return;
    }
    let Some(d) = cx.global::<Session>().dictation.clone() else { return };
    let command = match (d.state, d.busy) {
        (DictState::Rewriting, _) => SessionCommand::CancelRewrite,
        (_, true) => SessionCommand::CancelDictation,
        _ => return,
    };
    if cx.global::<Core>().services.session_command(command).is_err() {
        update_session(cx, |s| s.dictation.as_mut().unwrap().status = "Could not cancel: dictation isn't available in this build.".into());
    }
}

fn retry_storage(cx: &mut App) {
    let ok = cx.global::<Core>().services.session_command(SessionCommand::RetryStorage).is_ok();
    update_session(cx, |s| {
        let d = s.dictation.as_mut().unwrap();
        if ok {
            d.storage_blocked = false;
            d.status = "Storage available. Saved text remains in history.".into();
        } else {
            d.status = "Storage is unavailable. Check free disk space and Retry storage.".into();
        }
    });
}

fn retry_save(cx: &mut App) {
    let ok = cx.global::<Core>().services.session_command(SessionCommand::RetrySave).is_ok();
    update_session(cx, |s| {
        let d = s.dictation.as_mut().unwrap();
        if ok {
            d.unsaved = None;
            d.state = DictState::Recovery;
            d.status = "Text saved for review.".into();
        } else {
            d.status = "Still unsaved. Check available disk space or Copy the text.".into();
        }
    });
    if ok {
        history_changed(cx);
    }
}

pub struct Shell {
    pub(crate) meetings: Entity<NotetakerPage>,
    history: Entity<HistoryPage>,
    insights: Entity<InsightsPage>,
    dictionary: Entity<DictionaryPage>,
    settings: Entity<SettingsPage>,
    onboarding: Entity<OnboardingPage>,
    focus: FocusHandle,
    _subs: Vec<Subscription>,
    _polling: Task<()>,
}

impl Shell {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        ensure_session(cx);
        if let Some(alert) = cx.global::<Session>().alert {
            cx.defer_in(window, move |_, w, cx| present_alert(alert, w, cx));
        }
        let subs = vec![
            cx.observe_global::<Session>(|_, cx| cx.notify()),
            cx.observe_window_appearance(window, |_, _, cx| apply_appearance(cx)),
            cx.observe_window_activation(window, |_, w, cx| {
                let focused = w.is_window_active();
                update_session(cx, |s| s.window_focused = focused);
                crate::pill::focus_changed(cx);
                if focused {
                    refresh_display_options(cx);
                }
            }),
            // `onDisappear`: notes are saved before the editor goes away; capture is untouched.
            cx.on_release(|shell: &mut Shell, cx| shell.meetings.update(cx, |page, cx| page.flush_notes(cx))),
        ];
        // `observeSettingsWhileVisible`: only Settings and onboarding poll, every 500 ms.
        let polling = cx.spawn_in(window, async move |_, cx| {
            loop {
                cx.background_executor().timer(Duration::from_millis(500)).await;
                let alive = cx.update(|w, cx| {
                    if polls(cx.global::<Session>().selection, Self::onboarded(cx), w.is_window_active()) {
                        w.refresh();
                    }
                });
                if alive.is_err() {
                    break;
                }
            }
        });
        Shell {
            meetings: cx.new(|cx| NotetakerPage::new(window, cx)),
            history: cx.new(|cx| HistoryPage::new(window, cx)),
            insights: cx.new(|cx| InsightsPage::new(window, cx)),
            dictionary: cx.new(|cx| DictionaryPage::new(window, cx)),
            settings: cx.new(|cx| SettingsPage::new(window, cx)),
            onboarding: cx.new(|cx| OnboardingPage::new(window, cx)),
            focus: cx.focus_handle(),
            _subs: subs,
            _polling: polling,
        }
    }
    pub fn onboarded(cx: &App) -> bool {
        cx.global::<Core>().prefs.int_or("setupVersion", 0) >= 1
    }

    fn nav_item(&self, (page, title, symbol, id): (Page, &'static str, &'static str, &'static str), cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let selected = cx.global::<Session>().selection == page;
        prototype_nav(id, title, symbol, selected, p.tint, p.ink).on_click(cx.listener(move |_, _, _, cx| update_session(cx, |s| s.selection = page)))
    }

    fn active_note(&self, cx: &mut Context<Self>) -> Option<impl IntoElement> {
        let p = pal(cx);
        let status = cx.global::<Session>().meeting.clone().filter(|m| m.state.is_active())?;
        let title = status.title.clone().unwrap_or_else(|| "Untitled note".into());
        let id = status.id.clone();
        Some(div().pb(px(12.)).child(
            plain_button("navigation.activeNote", title.clone())
                .full_width()
                .content(
                    v_flex()
                        .w_full()
                        .gap(px(8.))
                        .p(px(14.))
                        .bg(p.surface)
                        .border_1()
                        .border_color(p.line)
                        .rounded(px(12.))
                        .child(t(title).font(13., 500.).lines(1).a11y_hidden())
                        .child(live_badge(status.state, status.elapsed_ms, 12., &p, cx.global::<Flow>().reduce_motion)),
                )
                .on_click(cx.listener(move |_, _, _, cx| open_note(id.clone(), cx))),
        ))
    }

    fn sidebar(&self, cx: &mut Context<Self>) -> AnyElement {
        let p = pal(cx);
        let attention = cx.global::<Session>().needs_attention();
        v_flex()
            .h_full()
            .px(px(12.))
            .child(
                h_flex()
                    .gap(px(6.2))
                    .px(px(8.))
                    .pt(px(70.))
                    .pb(px(36.))
                    .items_center()
                    .child(icon("chart.bar.xaxis", 27., p.ink))
                    .child(t("LocalFlow").size(22.).bold().tracking(-0.6)),
            )
            .child(
                v_flex()
                    .gap(px(5.))
                    .children(NAV[..4].iter().map(|row| self.nav_item(*row, cx).into_any_element()).collect::<Vec<_>>()),
            )
            .child(div().flex_1())
            .children(self.active_note(cx))
            .when(attention, |d| d.child(div().px(px(10.)).pb(px(8.)).child(sf_label("exclamationmark.circle", "Review needed", 13., p.warning))))
            .child(hairline(cx).mb(px(8.)))
            .child(div().pb(px(12.)).child(self.nav_item(NAV[4], cx)))
            .into_any_element()
    }

    /// `RecoveryNotice`: no space at all unless one of its three states applies.
    fn recovery_notice(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let p = pal(cx);
        let d = cx.global::<Session>().dictation.clone()?;
        if d.unsaved.is_none() && !d.storage_blocked && !d.capacity_blocked {
            return None;
        }
        let symbol = "externaldrive.badge.exclamationmark";
        Some(
            v_flex()
                .w_full()
                .flex_none()
                .gap(px(10.))
                .p(px(20.))
                .bg(p.surface)
                .text_size(px(14.))
                .when(d.storage_blocked, |v| {
                    v.child(
                        h_flex()
                            .justify_between()
                            .child(sf_label(symbol, "Storage needs attention. Your saved text is retained.", 14., p.ink))
                            .child(prototype_button("recovery.retryStorage", "Retry storage").disabled(d.busy).on_click(|_, _, cx| retry_storage(cx))),
                    )
                })
                .when(d.capacity_blocked, |v| v.child(sf_label(symbol, "History is full. Open Transcriptions and delete saved text before recording again.", 14., p.ink)))
                .when_some(d.unsaved.clone(), |v, text| {
                    let copied = text.clone();
                    v.child(h_flex().gap(px(6.)).child(icon("exclamationmark.triangle", 14., p.ink)).child(t("Unsaved text").font(14., 600.)))
                        .child(t("This text will be lost if you quit. Copy does not save it."))
                        .child(div().id("recovery.unsaved").max_h(px(150.)).overflow_y_scroll().child(t(text)))
                        .child(
                            h_flex()
                                .gap(px(8.))
                                .child(prototype_button("recovery.retrySave", "Retry save").disabled(d.busy).on_click(|_, _, cx| retry_save(cx)))
                                .child(prototype_button("recovery.copy", "Copy").disabled(d.busy).on_click(move |_, _, cx| cx.write_to_clipboard(ClipboardItem::new_string(copied.clone()))))
                                .child(
                                    prototype_button("recovery.discard", "Discard…")
                                        .disabled(d.busy)
                                        .text_color(p.warning)
                                        .on_click(|_, w, cx| present_alert(Alert::DiscardUnsaved, w, cx)),
                                ),
                        )
                })
                .into_any_element(),
        )
    }

    /// `ContentUnavailableView`, shown for a data page until its store exists.
    fn unavailable(&self, title: &'static str, cx: &mut Context<Self>) -> AnyElement {
        let p = pal(cx);
        let status = cx.global::<Session>().setup_status.clone();
        v_flex()
            .id(title)
            .size_full()
            .items_center()
            .justify_center()
            .gap(px(4.))
            .child(div().mb(px(20.)).child(icon("externaldrive.badge.exclamationmark", 44., p.muted.opacity(0.55))))
            .child(t(title).font(16., 700.).center())
            .child(div().max_w(px(350.)).child(t(status).size(15.).line_spacing(1.).center()))
            .into_any_element()
    }

    fn destination(&self, cx: &mut Context<Self>) -> AnyElement {
        let session = cx.global::<Session>();
        let (selection, stores, meetings) = (session.selection, session.stores_ready, session.meetings_available);
        match selection {
            Page::Meetings if meetings => self.meetings.clone().into_any_element(),
            Page::Meetings => self.unavailable("Meetings unavailable", cx),
            Page::History if stores => self.history.clone().into_any_element(),
            Page::History => self.unavailable("Transcriptions unavailable", cx),
            Page::Insights if stores => self.insights.clone().into_any_element(),
            Page::Insights => self.unavailable("Insights unavailable", cx),
            Page::Dictionary if stores => self.dictionary.clone().into_any_element(),
            Page::Dictionary => self.unavailable("Dictionary unavailable", cx),
            Page::Settings => self.settings.clone().into_any_element(),
        }
    }
}

fn badge_style(state: MeetingState, p: &Palette) -> (&'static str, Hsla) {
    if state == MeetingState::Paused { ("pause.fill", p.muted) } else { ("waveform", p.success) }
}

/// `LiveRecordingBadge`: waveform or pause symbol and a tabular timer.
pub fn live_badge(state: MeetingState, elapsed_ms: i64, size: f32, p: &Palette, reduce_motion: bool) -> impl IntoElement {
    let (symbol, color) = badge_style(state, p);
    let duration = duration_text(elapsed_ms);
    let glyph = div().child(icon(symbol, size - 1., color));
    let animated = state == MeetingState::Recording && !reduce_motion;
    h_flex()
        .id("meeting.elapsed")
        .test_support()
        .gap(px(8.))
        .role(accesskit::Role::Label)
        .aria_label(state.badge_text())
        .aria_value(duration.clone())
        // The iterative variable-color effect, approximated as a pulse: Lucide glyphs have no layers.
        .child(if animated {
            glyph.with_animation("meeting.elapsed.pulse", Animation::new(Duration::from_millis(1200)).repeat(), |d, f| d.opacity(0.45 + 0.55 * (1. - (2. * f - 1.).abs()))).into_any_element()
        } else {
            glyph.into_any_element()
        })
        .child(t(duration).size(size).color(color).mono_digits().a11y_hidden())
}

/// `meetingDurationText`.
pub fn duration_text(ms: i64) -> String {
    let seconds = ms.max(0) / 1000;
    let (h, m, s) = (seconds / 3600, (seconds % 3600) / 60, seconds % 60);
    if h > 0 { format!("{h}:{m:02}:{s:02}") } else { format!("{m}:{s:02}") }
}

/// A centered modal over a scrim, in the window's own accessibility tree.
pub fn modal(id: &'static str, width: f32, padding: f32, cx: &App, content: impl IntoElement) -> Stateful<Div> {
    let p = pal(cx);
    div()
        .id(id)
        .absolute()
        .top_0()
        .left_0()
        .size_full()
        .flex()
        .items_center()
        .justify_center()
        .bg(sheet_scrim(cx))
        .occlude()
        .child(v_flex().w(px(width)).p(px(padding)).bg(sheet_fill(cx)).rounded(px(14.)).shadow_lg().text_color(p.ink).text_size(px(14.)).child(content))
}

/// Title, message and buttons, in the order Swift adds them.
fn alert_content(alert: Alert) -> (PromptLevel, &'static str, &'static str, Vec<PromptButton>) {
    let (cancel, other) = (|l: &'static str| PromptButton::Cancel(l.into()), |l: &'static str| PromptButton::Other(l.into()));
    match alert {
        Alert::DiscardUnsaved => (PromptLevel::Warning, "Discard unsaved text?", "This text has not been saved. Discarding it cannot be undone.", vec![cancel("Keep text"), other("Discard")]),
        Alert::QuitUnsaved => (PromptLevel::Warning, "Quit with unsaved text?", "This text will be lost. Copy it or retry saving before quitting.", vec![PromptButton::Ok("Keep Open".into()), other("Quit and Lose Text")]),
        Alert::RecordingCantWait => (PromptLevel::Warning, "This recording can't wait for your server", "Twenty dictations are already waiting, or the recording could not be stored. Save its audio to keep it, or discard it.", vec![PromptButton::Ok("Save Audio…".into()), other("Discard")]),
    }
}

fn alert_answered(alert: Alert, answer: usize, cx: &mut App) {
    update_session(cx, |s| s.alert = None);
    match (alert, answer) {
        (Alert::DiscardUnsaved, 1) => update_session(cx, |s| {
            let d = s.dictation.as_mut().unwrap();
            d.unsaved = None;
            d.status = "Unsaved text discarded.".into();
        }),
        (Alert::QuitUnsaved, 1) => crate::menu::finish_quit(cx),
        // Read and write errors are silent in Swift too (SHELL-248).
        (Alert::RecordingCantWait, 0) => drop(cx.global::<Core>().services.choose_save_path("LocalFlow dictation.wav")),
        _ => {}
    }
}

/// Presents `alert` natively on `window`; the answer applies when the user picks a button.
pub fn present_alert(alert: Alert, window: &mut Window, cx: &mut App) {
    update_session(cx, |s| s.alert = Some(alert));
    let (level, title, message, buttons) = alert_content(alert);
    let answer = window.prompt(level, title, Some(message), &buttons, cx);
    cx.spawn(async move |cx| {
        if let Ok(i) = answer.await {
            let _ = cx.update(|cx| alert_answered(alert, i, cx));
        }
    })
    .detach();
}

/// The same from code with no window at hand, on the main window.
pub fn show_alert(alert: Alert, cx: &mut App) {
    if let Some(w) = cx.global::<Session>().window {
        let _ = w.update(cx, |_, w, cx| present_alert(alert, w, cx));
    }
}

impl Render for Shell {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let reviewing = cx.global::<Session>().insertion.is_reviewing();
        if !Self::onboarded(cx) {
            return div().size_full().bg(p.canvas).text_color(p.ink).child(self.onboarding.clone()).into_any_element();
        }
        // Keys reach "Shell" bindings only through a focused node: Escape needs one with nothing else focused.
        if window.focused(cx).is_none() || (reviewing && !self.focus.contains_focused(window, cx)) {
            self.focus.focus(window, cx);
        }
        let compact = window.viewport_size().width <= px(800.);
        cx.global_mut::<Flow>().compact = compact;
        let page = self.destination(cx);
        let notice = self.recovery_notice(cx);
        let sidebar = self.sidebar(cx);
        let review_el = reviewing.then(|| insertion::review_sheet(cx).into_any_element());
        h_flex()
            .id("shell.library")
            .key_context("Shell")
            .track_focus(&self.focus)
            .relative()
            .size_full()
            .bg(p.canvas)
            .text_color(p.ink)
            .text_size(px(14.))
            .font_family(FIGTREE)
            .on_action(|_: &crate::menu::CancelSession, _, cx| cancel_dictation(cx))
            .child(div().w(px(if compact { 180. } else { 216. })).h_full().flex_none().child(sidebar))
            .child(
                div().flex_1().min_w_0().h_full().pt(px(44.)).pr(px(8.)).pb(px(8.)).child(
                    v_flex()
                        .size_full()
                        .bg(p.surface)
                        .border_1()
                        .border_color(p.line)
                        .rounded(px(16.))
                        .overflow_hidden()
                        .children(notice)
                        .child(div().flex_1().min_h_0().child(page)),
                ),
            )
            .children(review_el)
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::{assert_saw, boot};
    use flow_platform::Fake;
    use flow_ui::test::{TestAppContext, TestWindowExt};

    fn open_shell(cx: &mut TestAppContext) -> WindowHandle<Shell> {
        cx.update(|cx| {
            crate::menu::init(cx);
            cx.global_mut::<Core>().prefs.set("setupVersion", 1);
        });
        let window = cx.add_window(|w, cx| Shell::new(w, cx));
        cx.run_until_parked();
        cx.update(|cx| update_session(cx, |s| s.window = Some(window.into())));
        window
    }

    #[track_caller]
    fn assert_drew(symbol: &str) {
        let drawn = flow_ui::probe::symbols();
        assert!(drawn.iter().any(|s| s == symbol), "{symbol} not drawn; drew {drawn:?}");
    }

    fn frame(cx: &mut TestAppContext, window: WindowHandle<Shell>) {
        flow_ui::probe::clear();
        cx.run_until_parked();
        cx.update_window(window.into(), |_, w, cx| w.render_frame(cx)).unwrap();
    }

    fn set(cx: &mut TestAppContext, f: impl FnOnce(&mut Session)) {
        cx.update(|cx| update_session(cx, f));
    }

    fn get<R>(cx: &mut TestAppContext, f: impl FnOnce(&Session) -> R) -> R {
        cx.update(|cx| f(cx.global::<Session>()))
    }

    // parity: SHELL-026 SHELL-027 SHELL-025
    #[flow_ui::gpui::test]
    async fn window_options_and_identifier_match_swift(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let identifiers = std::rc::Rc::default();
        cx.update(|cx| cx.global_mut::<Core>().services = Box::new(Fake { identifiers: std::rc::Rc::clone(&identifiers), ..Default::default() }));
        let options = cx.update(|cx| main_window_options(cx));
        let Some(WindowBounds::Windowed(bounds)) = options.window_bounds else { panic!("windowed") };
        assert_eq!(bounds.size, size(px(1100.), px(760.)));
        assert_eq!(options.window_min_size, Some(size(px(720.), px(560.))));
        assert_eq!(options.titlebar.and_then(|t| t.title).as_deref(), Some("LocalFlow"));
        let window = open_shell(cx);
        cx.update(|cx| tag_main_window(window.into(), cx));
        assert_eq!(*identifiers.borrow(), vec!["localflow.main".to_string()]);
    }

    // parity: SHELL-007 SHELL-106
    /// A second launch on the same data root: no lock, no stores, Swift's launch failure.
    #[flow_ui::gpui::test]
    async fn a_second_instance_lands_in_the_launch_failure(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let dir = std::env::temp_dir().join(format!("lf-second-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let load = || Core::load(Box::new(Fake { dir: dir.clone(), ..Default::default() }));
        let first = load();
        assert!(first.instance_lock.is_some() && first.db.is_some());
        let second = load();
        assert!(second.instance_lock.is_none() && second.db.is_none());
        let session = Session::new(&second);
        assert_eq!(session.setup_status, SETUP_FAILED);
        drop((first, second));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    // parity: SHELL-004 SHELL-105
    #[flow_ui::gpui::test]
    async fn start_recovers_meetings_and_checks_the_model(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        cx.update(|cx| {
            ensure_session(cx);
            cx.global_mut::<Core>().reconciled = false;
            assert!(!cx.global::<Session>().can_start_meeting);
            start(cx);
            assert!(cx.global::<Core>().reconciled);
            assert!(cx.global::<Session>().can_start_meeting);
            assert_eq!(cx.global::<Session>().setup_status, "Import the pinned model before dictating.");
            let fake = Fake::default();
            fake.model_verified.set(true);
            cx.global_mut::<Core>().services = Box::new(fake);
            start(cx);
            assert_eq!(cx.global::<Session>().setup_status, "Verified local model available.");
        });
    }

    // parity: SHELL-003 SHELL-061 SHELL-034
    #[flow_ui::gpui::test]
    async fn landing_page_follows_purpose(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        cx.update(|cx| {
            assert_eq!(landing_page(cx.global::<Core>()), Page::History);
            cx.global_mut::<Core>().prefs.set("setup.purpose", "meetings");
            assert_eq!(landing_page(cx.global::<Core>()), Page::Meetings);
            assert!(!Shell::onboarded(cx));
        });
    }

    fn bounds_of(cx: &mut TestAppContext, window: WindowHandle<Shell>, id: &'static str) -> Bounds<Pixels> {
        cx.update_window(window.into(), |_, w, _| w.find(id).bounds()).unwrap()
    }

    // parity: SHELL-051 SHELL-060 SHELL-068 SHELL-070 SHELL-072 SHELL-075 SHELL-077
    #[flow_ui::gpui::test]
    async fn sidebar_rows_open_their_pages(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let window = open_shell(cx);
        frame(cx, window);
        let click = |cx: &mut TestAppContext, id: &'static str| {
            cx.update_window(window.into(), |_, w, cx| w.click(id, cx)).unwrap();
            frame(cx, window);
            get(cx, |s| s.selection)
        };
        assert_eq!(click(cx, "navigation.notetaker"), Page::Meetings);
        assert_saw(&["Past notes"]);
        assert_eq!(click(cx, "navigation.insights"), Page::Insights);
        assert_saw(&["Desktop usage"]);
        assert_eq!(click(cx, "navigation.dictionary"), Page::Dictionary);
        assert_saw(&["Add new word"]);
        assert_eq!(click(cx, "navigation.settings"), Page::Settings);
        assert_saw(&["Remote dictation"]);
        assert_eq!(click(cx, "navigation.transcriptions"), Page::History);
        assert!(!crate::testing::saw("Remote dictation"));
        // Clicking persists nothing: the landing page stays derived from the purpose.
        cx.update(|cx| assert!(!cx.global::<Core>().prefs.contains("selection")));
    }

    // parity: SHELL-070
    /// The Transcriptions destination carries Swift's wiring: copy, insert into review, delete through
    /// the store (`delete_asks_then_removes_the_row`), and `globalBusy` from the dictation session.
    #[flow_ui::gpui::test]
    async fn transcriptions_destination_wires_copy_insert_and_busy(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let window = open_shell(cx);
        set(cx, |s| s.selection = Page::History);
        frame(cx, window);
        let (id, text) = cx.update(|cx| {
            let page = flow_core::history::page(cx.global::<Core>().db.as_ref().unwrap(), "", None, flow_core::history::Direction::Older, None).unwrap();
            let e = page.entries.into_iter().find(|e| !e.is_attempting()).unwrap();
            (e.id, e.text)
        });
        let (copy, insert) = (SharedString::from(format!("history.copy.{id}")), SharedString::from(format!("history.insert.{id}")));
        cx.update_window(window.into(), |_, w, cx| w.click(copy.clone(), cx)).unwrap();
        assert_eq!(cx.read_from_clipboard().and_then(|c| c.text()), Some(text.clone()));
        frame(cx, window);
        let off = |cx: &mut TestAppContext| cx.update_window(window.into(), |_, w, _| w.find(insert.clone()).disabled()).unwrap();
        assert_ne!(off(cx), Some(true));
        set(cx, |s| s.dictation = Some(Dictation { busy: true, ..Default::default() }));
        frame(cx, window);
        assert_eq!(off(cx), Some(true), "globalBusy disables Insert");
        set(cx, |s| s.dictation = Some(Dictation::default()));
        frame(cx, window);
        cx.update_window(window.into(), |_, w, cx| w.click(insert.clone(), cx)).unwrap();
        cx.update(|cx| assert_eq!(cx.global::<Session>().insertion.entry.as_ref().map(|e| e.text.clone()), Some(text)));
    }

    // parity: SHELL-043 SHELL-044 SHELL-045 SHELL-046 SHELL-047
    #[flow_ui::gpui::test]
    async fn sidebar_rows_carry_swifts_labels_symbols_and_ids(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let window = open_shell(cx);
        frame(cx, window);
        let label = |cx: &mut TestAppContext, id: &'static str| cx.update_window(window.into(), |_, w, _| w.find(id).label().map(str::to_string)).unwrap();
        assert_eq!((label(cx, "navigation.notetaker").as_deref(), NAV[0].2), (Some("Notetaker"), "record.circle"));
        assert_eq!((label(cx, "navigation.transcriptions").as_deref(), NAV[1].2), (Some("Transcriptions"), "mic"));
        assert_eq!((label(cx, "navigation.insights").as_deref(), NAV[2].2), (Some("Insights"), "chart.bar"));
        assert_eq!((label(cx, "navigation.dictionary").as_deref(), NAV[3].2), (Some("Dictionary"), "text.book.closed"));
        assert_eq!((label(cx, "navigation.settings").as_deref(), NAV[4].2), (Some("Settings"), "gearshape"));
        for symbol in ["record.circle", "mic", "chart.bar", "text.book.closed", "gearshape"] {
            assert_drew(symbol);
        }
    }

    // parity: SHELL-029 SHELL-030 SHELL-040 SHELL-042 SHELL-048 SHELL-224
    /// Row bounds: 216 wide less 12 either side, 35 tall, 5 apart; 180 wide at the 800 breakpoint.
    #[flow_ui::gpui::test]
    async fn sidebar_geometry_follows_the_breakpoint(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        assert!(!cx.update(|cx| cx.global::<Flow>().compact), "prototypeCompact defaults to false");
        let window = open_shell(cx);
        cx.simulate_window_resize(window.into(), size(px(801.), px(700.)));
        frame(cx, window);
        let first = bounds_of(cx, window, "navigation.notetaker");
        let second = bounds_of(cx, window, "navigation.transcriptions");
        assert_eq!((first.origin.x, first.size.width), (px(12.), px(192.)));
        assert_eq!(first.size.height, px(35.));
        assert_eq!(second.origin.y - first.origin.y, px(40.));
        cx.update(|cx| assert!(!cx.global::<Flow>().compact));
        cx.simulate_window_resize(window.into(), size(px(800.), px(700.)));
        frame(cx, window);
        cx.update(|cx| assert!(cx.global::<Flow>().compact));
        assert_eq!(bounds_of(cx, window, "navigation.notetaker").size.width, px(156.));
    }

    // parity: SHELL-049 SHELL-050
    #[flow_ui::gpui::test]
    async fn only_the_selected_row_is_marked(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let window = open_shell(cx);
        set(cx, |s| s.selection = Page::Insights);
        frame(cx, window);
        let selected = |cx: &mut TestAppContext, id: &'static str| cx.update_window(window.into(), |_, w, _| w.find(id).checked().or(w.find(id).selected())).unwrap();
        assert_eq!(selected(cx, "navigation.insights"), Some(true));
        assert_eq!(selected(cx, "navigation.dictionary"), Some(false));
    }

    // parity: SHELL-069 SHELL-071 SHELL-073 SHELL-076 SHELL-078 SHELL-080 SHELL-103 SHELL-095
    #[flow_ui::gpui::test]
    async fn pages_show_unavailable_until_stores_exist(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let window = open_shell(cx);
        set(cx, |s| {
            s.stores_ready = false;
            s.meetings_available = false;
            s.dictation = None;
        });
        let shows = |cx: &mut TestAppContext, page: Page, title: &str| {
            set(cx, |s| s.selection = page);
            frame(cx, window);
            crate::testing::saw(title) && crate::testing::saw("Starting…") && flow_ui::probe::symbols().iter().any(|s| s == "externaldrive.badge.exclamationmark")
        };
        assert!(shows(cx, Page::Meetings, "Meetings unavailable"));
        assert!(shows(cx, Page::History, "Transcriptions unavailable"));
        assert!(shows(cx, Page::Insights, "Insights unavailable"));
        assert!(shows(cx, Page::Dictionary, "Dictionary unavailable"));
        // Settings is always available, and no coordinator means no recovery notice.
        assert!(!shows(cx, Page::Settings, "unavailable"));
        cx.update_window(window.into(), |_, w, _| assert!(w.try_find("recovery.retryStorage").is_none())).unwrap();
        assert_eq!(SETUP_STARTING, "Starting…");
        // The menu's readiness line shows the setup status while nothing else exists.
        set(cx, |s| s.setup_status = SETUP_FAILED.into());
        cx.update(|cx| assert_eq!(readiness(cx), "Setup could not finish. Check app storage and the model manifest."));
    }

    // parity: SHELL-109 SHELL-110 SHELL-111 SHELL-112 SHELL-113 SHELL-115 SHELL-116 SHELL-119 SHELL-120
    /// The copy each later service will post. Nothing posts it yet (plan: no model code in 024), so this
    /// holds the literal text and shows that the view renders whatever is current.
    #[flow_ui::gpui::test]
    async fn setup_status_copy_matches_swift_and_renders(cx: &mut TestAppContext) {
        let has = |text: &str| SETUP_STATUS_COPY.contains(&text);
        assert!(has("Could not prepare speech model. ") && has("Preparing speech model…") && has("Speech model ready. Hold the shortcut to dictate."));
        assert!(has("Local model files verified.") && has("Local model verification failed. Verify or reinstall the model in Settings."));
        assert!(has("Whisper Turbo verified.") && has("Install Whisper Turbo in Settings to finalize meetings.") && has("Install or verify Whisper Turbo in Settings to finalize meetings.") && has("Whisper Turbo verified. Final meeting transcripts use it locally."));
        assert!(has("Speaker labeling model verified.") && has("Speaker labeling model isn't installed."));
        assert!(has("Term booster verified. Dictionary terms are checked against your speech."));
        assert!(has("The chosen speech model is missing; dictating with Parakeet v3.") && has("Dictation now uses Parakeet v3."));
        assert!(has("Parakeet v3 downloaded and verified.") && has("Parakeet v3 download cancelled.") && has("Parakeet v3 download failed. Check the connection and available storage."));
        assert!(has("Meeting models did not finish downloading. Retry in Settings."));
        assert!(has("Downloading model files…") && has("Importing model files…") && has("Model verified. Hold the shortcut for a short test.") && has("Provisioning unavailable: the pinned manifest is missing verified hashes.") && has("Model installation cancelled.") && has("Installation failed. Check the pinned files, connection and available storage."));
        boot(cx, Mode::Light);
        let window = open_shell(cx);
        set(cx, |s| s.stores_ready = false);
        set(cx, |s| s.setup_status = "Local model files verified.".into());
        frame(cx, window);
        assert_saw(&["Local model files verified."]);
    }

    // parity: SHELL-053 SHELL-054 SHELL-058
    #[flow_ui::gpui::test]
    async fn active_note_card_opens_its_meeting(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let window = open_shell(cx);
        frame(cx, window);
        cx.update_window(window.into(), |_, w, _| assert!(w.try_find("navigation.activeNote").is_none())).unwrap();
        set(cx, |s| s.meeting = Some(MeetingStatus { id: flow_core::meetings::SEED_FULL.into(), title: None, state: MeetingState::Recording, elapsed_ms: 754_000 }));
        frame(cx, window);
        assert_saw(&["Untitled note"]);
        // Sits in the sidebar's 192 column; 14 padding around a line of 13 and a 12 badge, spaced 8.
        let card = bounds_of(cx, window, "navigation.activeNote");
        assert_eq!((card.origin.x, card.size.width), (px(12.), px(192.)));
        assert!(card.size.height >= px(28. + 8. + 13. + 12.) && card.size.height < px(28. + 8. + 45.), "{card:?}");
        cx.update_window(window.into(), |_, w, cx| w.click("navigation.activeNote", cx)).unwrap();
        frame(cx, window);
        assert_eq!(get(cx, |s| (s.selection, s.open_meeting.is_none())), (Page::Meetings, true));
        let opened = window.update(cx, |shell, _, cx| shell.meetings.read(cx).editor.as_ref().map(|e| e.meeting_id.clone())).unwrap();
        assert_eq!(opened.as_deref(), Some(flow_core::meetings::SEED_FULL));
        // A finished meeting has no card.
        set(cx, |s| s.meeting = Some(MeetingStatus { id: "m1".into(), title: None, state: MeetingState::Completed, elapsed_ms: 0 }));
        frame(cx, window);
        cx.update_window(window.into(), |_, w, _| assert!(w.try_find("navigation.activeNote").is_none())).unwrap();
    }

    // parity: SHELL-055 SHELL-056 SHELL-057
    #[flow_ui::gpui::test]
    async fn live_badge_reads_each_meeting_state(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let window = open_shell(cx);
        let p = cx.update(|cx| pal(cx));
        let label = |cx: &mut TestAppContext, state| {
            set(cx, |s| s.meeting = Some(MeetingStatus { id: "m1".into(), title: Some("Planning".into()), state, elapsed_ms: 754_000 }));
            frame(cx, window);
            cx.update_window(window.into(), |_, w, _| {
                let badge = w.find("meeting.elapsed");
                (badge.label().map(str::to_string), badge.value().map(str::to_string))
            })
            .unwrap()
        };
        assert_eq!(label(cx, MeetingState::Recording), (Some("Recording".to_string()), Some("12:34".to_string())));
        assert_eq!(badge_style(MeetingState::Recording, &p), ("waveform", p.success));
        assert_drew("waveform");
        assert_eq!(label(cx, MeetingState::Paused).0.as_deref(), Some("Paused"));
        assert_eq!(badge_style(MeetingState::Paused, &p), ("pause.fill", p.muted));
        assert_drew("pause.fill");
        assert_eq!(label(cx, MeetingState::Preparing).0.as_deref(), Some("Preparing"));
        assert_eq!(label(cx, MeetingState::Created).0.as_deref(), Some("Created"));
        assert_eq!(label(cx, MeetingState::Finalizing).0.as_deref(), Some("Finalizing"));
        assert_eq!(badge_style(MeetingState::Finalizing, &p), ("waveform", p.success));
    }

    // parity: PILL-110
    /// The published meeting notices reach the pill through the Notetaker page, as launch recovery posts them.
    #[flow_ui::gpui::test]
    async fn launch_recovery_notices_reach_the_pill(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        cx.update(|cx| cx.global_mut::<Core>().meeting_notices = vec!["1 transcript was interrupted".into()]);
        let window = open_shell(cx);
        set(cx, |s| s.selection = Page::Meetings);
        frame(cx, window);
        assert_eq!(get(cx, |s| s.pill.action.as_ref().map(|a| (a.message.clone(), a.can_retry))), Some(("1 transcript was interrupted".to_string(), false)));
    }

    // parity: SHELL-059 SHELL-079 SHELL-081 SHELL-083 SHELL-084 SHELL-085 SHELL-089 MENU-007
    #[flow_ui::gpui::test]
    async fn recovery_states_render_and_disable_while_busy(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let window = open_shell(cx);
        frame(cx, window);
        assert!(!crate::testing::saw("Review needed"));
        set(cx, |s| s.dictation.as_mut().unwrap().storage_blocked = true);
        frame(cx, window);
        assert_saw(&["Review needed", "Storage needs attention. Your saved text is retained.", "Retry storage"]);
        assert_drew("exclamationmark.circle");
        assert_drew("externaldrive.badge.exclamationmark");
        set(cx, |s| {
            let d = s.dictation.as_mut().unwrap();
            d.storage_blocked = false;
            d.capacity_blocked = true;
        });
        frame(cx, window);
        assert_saw(&["Review needed", "History is full. Open Transcriptions and delete saved text before recording again."]);
        assert_drew("externaldrive.badge.exclamationmark");
        cx.update_window(window.into(), |_, w, _| assert!(w.try_find("recovery.retryStorage").is_none())).unwrap();
        set(cx, |s| {
            let d = s.dictation.as_mut().unwrap();
            d.capacity_blocked = false;
            d.unsaved = Some("Keep this".into());
        });
        frame(cx, window);
        assert_saw(&["Unsaved text", "This text will be lost if you quit. Copy does not save it.", "Keep this", "Retry save", "Copy", "Discard…"]);
        assert_drew("exclamationmark.triangle");
        set(cx, |s| {
            let d = s.dictation.as_mut().unwrap();
            d.unsaved = None;
            d.state = DictState::Failed;
        });
        frame(cx, window);
        assert_saw(&["Review needed"]);
        // Failed alone flags attention but the notice takes no space.
        cx.update_window(window.into(), |_, w, _| assert!(w.try_find("recovery.retrySave").is_none())).unwrap();
        // Busy disables every recovery button: clicks do nothing.
        set(cx, |s| {
            let d = s.dictation.as_mut().unwrap();
            d.state = DictState::Idle;
            d.busy = true;
            d.unsaved = Some("Keep this".into());
            d.storage_blocked = true;
            d.status = "Busy".into();
        });
        frame(cx, window);
        for id in ["recovery.retryStorage", "recovery.retrySave", "recovery.discard"] {
            cx.update_window(window.into(), |_, w, cx| w.click(id, cx)).unwrap();
        }
        assert_eq!(get(cx, |s| s.dictation.as_ref().unwrap().status.clone()), "Busy");
        assert_eq!(get(cx, |s| s.alert), None);
    }

    // parity: SHELL-082 SHELL-086 SHELL-087 SHELL-088 SHELL-090 SHELL-091 SHELL-092
    #[flow_ui::gpui::test]
    async fn recovery_actions_retry_copy_and_discard(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let window = open_shell(cx);
        set(cx, |s| {
            let d = s.dictation.as_mut().unwrap();
            d.unsaved = Some("Keep this".into());
            d.storage_blocked = true;
        });
        frame(cx, window);
        // No session in this build: the failure copy Swift shows, and the text stays.
        cx.update_window(window.into(), |_, w, cx| w.click("recovery.retrySave", cx)).unwrap();
        assert_eq!(get(cx, |s| s.dictation.as_ref().unwrap().status.clone()), "Still unsaved. Check available disk space or Copy the text.");
        assert!(get(cx, |s| s.dictation.as_ref().unwrap().unsaved.is_some()));
        cx.update_window(window.into(), |_, w, cx| w.click("recovery.retryStorage", cx)).unwrap();
        assert!(get(cx, |s| s.dictation.as_ref().unwrap().storage_blocked));
        frame(cx, window);
        cx.update_window(window.into(), |_, w, cx| w.click("recovery.copy", cx)).unwrap();
        assert_eq!(cx.read_from_clipboard().and_then(|c| c.text()).as_deref(), Some("Keep this"));
        assert!(get(cx, |s| s.dictation.as_ref().unwrap().unsaved.is_some()));
        // With a session the retries succeed.
        cx.update(|cx| {
            let fake = Fake::default();
            fake.session_ok.set(true);
            cx.global_mut::<Core>().services = Box::new(fake);
        });
        cx.update_window(window.into(), |_, w, cx| w.click("recovery.retryStorage", cx)).unwrap();
        assert!(!get(cx, |s| s.dictation.as_ref().unwrap().storage_blocked));
        frame(cx, window);
        cx.update_window(window.into(), |_, w, cx| w.click("recovery.discard", cx)).unwrap();
        cx.run_until_parked();
        assert_eq!(cx.pending_prompt(), Some(("Discard unsaved text?".to_string(), "This text has not been saved. Discarding it cannot be undone.".to_string())));
        cx.simulate_prompt_answer("Keep text");
        cx.run_until_parked();
        assert!(get(cx, |s| s.alert.is_none() && s.dictation.as_ref().unwrap().unsaved.is_some()));
        frame(cx, window);
        cx.update_window(window.into(), |_, w, cx| w.click("recovery.discard", cx)).unwrap();
        cx.run_until_parked();
        cx.simulate_prompt_answer("Discard");
        cx.run_until_parked();
        assert!(get(cx, |s| s.alert.is_none() && s.dictation.as_ref().unwrap().unsaved.is_none()));
        frame(cx, window);
        assert!(!crate::testing::saw("Unsaved text"));
        // Retry save, on a fresh buffer.
        set(cx, |s| s.dictation.as_mut().unwrap().unsaved = Some("Again".into()));
        frame(cx, window);
        cx.update_window(window.into(), |_, w, cx| w.click("recovery.retrySave", cx)).unwrap();
        assert_eq!(get(cx, |s| s.dictation.as_ref().unwrap().status.clone()), "Text saved for review.");
    }

    // parity: SHELL-093 SHELL-094 SHELL-096..SHELL-102 MENU-006 ONB-020
    // The readiness text the menu's first line shows, from every branch of `AppServices.readinessStatus`.
    #[flow_ui::gpui::test]
    async fn readiness_follows_swift_order(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        cx.update(|cx| {
            let mut s = Session::new(cx.global::<Core>());
            let granted = PermissionState::Granted;
            let read = |s: &Session| s.readiness(granted, false, false);
            assert_eq!(read(&s), "Install the local speech model in Settings.");
            assert_eq!(s.readiness(PermissionState::Denied, true, false), "Allow Microphone in Settings.");
            s.model_installed = true;
            assert_eq!(read(&s), "Enable the shortcut and Input Monitoring in Settings.");
            assert_eq!(s.readiness(granted, false, true), "Ready · start a meeting in Notetaker");
            s.shortcut_available = true;
            assert_eq!(read(&s), "Ready · hold your shortcut to dictate");
            s.model_command = true;
            assert_eq!(read(&s), "Preparing speech model…");
            s.installing = true;
            assert_eq!(read(&s), "Installing speech model…");
            let d = s.dictation.as_mut().unwrap();
            d.status = "Saved".into();
            d.storage_blocked = true;
            assert_eq!(read(&s), "Saved");
            let d = s.dictation.as_mut().unwrap();
            d.storage_blocked = false;
            d.busy = true;
            d.status = "Recording".into();
            assert_eq!(read(&s), "Recording");
            let d = s.dictation.as_mut().unwrap();
            d.busy = false;
            d.state = DictState::Failed;
            d.status = "Failed".into();
            assert_eq!(read(&s), "Failed");
            s.dictation = None;
            s.setup_status = "Set up".into();
            assert_eq!(read(&s), "Set up");
        });
    }

    // parity: SHELL-039
    #[flow_ui::gpui::test]
    async fn appearance_preference_switches_palette_and_app(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let appearances = std::rc::Rc::default();
        cx.update(|cx| {
            cx.global_mut::<Core>().services = Box::new(Fake { appearances: std::rc::Rc::clone(&appearances), ..Default::default() });
            cx.global_mut::<Core>().prefs.set("appearance", "dark");
            apply_appearance(cx);
            assert_eq!(pal(cx).mode, Mode::Dark);
            cx.global_mut::<Core>().prefs.set("appearance", "light");
            apply_appearance(cx);
            assert_eq!(pal(cx).mode, Mode::Light);
            cx.global_mut::<Core>().prefs.set("appearance", "system");
            apply_appearance(cx);
        });
        assert_eq!(*appearances.borrow(), vec![Some(true), Some(false), None]);
    }

    // parity: SHELL-015
    #[flow_ui::gpui::test]
    async fn activation_rereads_reduce_motion(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        cx.update(|cx| {
            cx.global_mut::<Flow>().reduce_motion = true;
            refresh_display_options(cx);
            assert!(!cx.global::<Flow>().reduce_motion, "the Fake's system value wins");
        });
    }

    // parity: SHELL-023
    #[flow_ui::gpui::test]
    async fn escape_cancels_only_while_busy(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let commands = std::rc::Rc::default();
        cx.update(|cx| {
            let fake = Fake { commands: std::rc::Rc::clone(&commands), ..Default::default() };
            fake.session_ok.set(true);
            cx.global_mut::<Core>().services = Box::new(fake);
        });
        let window = open_shell(cx);
        frame(cx, window);
        cx.update_window(window.into(), |_, w, cx| {
            w.dispatch_action(Box::new(crate::menu::CancelSession), cx);
        }).unwrap();
        assert!(commands.borrow().is_empty());
        set(cx, |s| s.dictation.as_mut().unwrap().busy = true);
        cx.update(cancel_dictation);
        assert_eq!(*commands.borrow(), vec![SessionCommand::CancelDictation]);
        set(cx, |s| s.dictation.as_mut().unwrap().state = DictState::Rewriting);
        cx.update(cancel_dictation);
        assert_eq!(commands.borrow().last(), Some(&SessionCommand::CancelRewrite));
    }

    // parity: SHELL-062 SHELL-065
    #[flow_ui::gpui::test]
    async fn show_microphones_opens_settings_at_the_anchor_once(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let window = open_shell(cx);
        cx.update(|cx| show_microphones(cx));
        assert_eq!(get(cx, |s| (s.selection, s.microphones_anchor)), (Page::Settings, true));
        frame(cx, window);
        cx.executor().advance_clock(Duration::from_secs(1));
        cx.run_until_parked();
        assert!(!get(cx, |s| s.microphones_anchor), "Settings takes the anchor while shown");
    }

    // parity: SHELL-064 SHELL-066 SHELL-037
    #[flow_ui::gpui::test]
    async fn open_selects_keeps_one_window_and_close_keeps_the_selection(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let window = open_shell(cx);
        cx.update(|cx| open(Some(Page::Dictionary), cx));
        cx.run_until_parked();
        assert_eq!(get(cx, |s| s.selection), Page::Dictionary);
        assert_eq!(get(cx, |s| s.window.map(|w| w.window_id())), Some(window.window_id()), "no second window");
        cx.update(|cx| window_closed(window.window_id(), cx));
        assert_eq!(get(cx, |s| (s.selection, s.window.is_none(), s.window_focused)), (Page::Dictionary, true, false));
    }

    // parity: SHELL-063
    #[flow_ui::gpui::test]
    async fn window_focus_follows_activation(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let window = open_shell(cx);
        window.update(cx, |_, w, _| w.activate_window()).unwrap();
        cx.run_until_parked();
        assert!(get(cx, |s| s.window_focused));
        flow_ui::gpui::VisualTestContext::from_window(window.into(), cx).deactivate_window();
        cx.run_until_parked();
        assert!(!get(cx, |s| s.window_focused));
    }

    // parity: SHELL-074
    #[flow_ui::gpui::test]
    async fn a_save_marks_history_changed(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let window = open_shell(cx);
        set(cx, |s| s.dictation.as_mut().unwrap().unsaved = Some("Keep".into()));
        frame(cx, window);
        let before = get(cx, |s| s.history_revision);
        cx.update(|cx| {
            let fake = Fake::default();
            fake.session_ok.set(true);
            cx.global_mut::<Core>().services = Box::new(fake);
        });
        cx.update_window(window.into(), |_, w, cx| w.click("recovery.retrySave", cx)).unwrap();
        assert_eq!(get(cx, |s| s.history_revision), before + 1);
    }

    // parity: SHELL-133
    #[flow_ui::gpui::test]
    async fn recording_alert_discard_writes_nothing(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let saves = std::rc::Rc::default();
        cx.update(|cx| cx.global_mut::<Core>().services = Box::new(Fake { save_prompts: std::rc::Rc::clone(&saves), ..Default::default() }));
        let window = open_shell(cx);
        cx.update(|cx| show_alert(Alert::RecordingCantWait, cx));
        cx.run_until_parked();
        cx.simulate_prompt_answer("Discard");
        cx.run_until_parked();
        assert!(saves.borrow().is_empty());
        assert_eq!(get(cx, |s| s.alert), None);
        cx.update(|cx| show_alert(Alert::RecordingCantWait, cx));
        cx.run_until_parked();
        cx.simulate_prompt_answer("Save Audio…");
        cx.run_until_parked();
        assert_eq!(*saves.borrow(), vec!["LocalFlow dictation.wav".to_string()]);
        let _ = window;
    }

    // parity: SHELL-038
    #[test]
    fn only_an_active_settings_or_setup_window_polls() {
        assert!(polls(Page::Settings, true, true));
        assert!(polls(Page::History, false, true));
        assert!(!polls(Page::History, true, true));
        assert!(!polls(Page::Settings, true, false));
        assert!(!polls(Page::History, false, false));
    }

    struct Frame;
    impl Render for Frame {
        fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
            prototype_page("frame", 800., cx, div().id("frame.child").w_full().h(px(10.)).test_support())
        }
    }

    // parity: SHELL-226
    #[flow_ui::gpui::test]
    async fn compact_page_padding_is_24_and_32(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let w = cx.add_window(|_, _| Frame);
        let origin = |cx: &mut TestAppContext| {
            cx.update_window(w.into(), |_, w, cx| {
                w.render_frame(cx);
                let b = w.find("frame.child").bounds();
                (f32::from(b.origin.y), f32::from(w.viewport_size().width.min(px(800.))) , f32::from(b.size.width))
            })
            .unwrap()
        };
        let (top, column, width) = origin(cx);
        assert_eq!((top, column - width), (48., 96.));
        cx.update(|cx| cx.global_mut::<Flow>().compact = true);
        let (top, column, width) = origin(cx);
        assert_eq!((top, column - width), (32., 48.));
    }

    struct Buttons(bool);
    impl Render for Buttons {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            v_flex().items_start().child(prototype_button("b.proto", "Label")).child(primary_button("b.primary", "Label").disabled(self.0))
        }
    }

    // parity: SHELL-227 SHELL-228 SHELL-230 SHELL-231 SHELL-232 SHELL-222
    /// Padding shows in the bounds; the state colours come from the style table.
    #[flow_ui::gpui::test]
    async fn button_styles_match_swift(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let w = cx.add_window(|_, _| Buttons(false));
        let (proto, primary) = cx
            .update_window(w.into(), |_, w, cx| {
                w.render_frame(cx);
                (w.find("b.proto").bounds().size.height, w.find("b.primary").bounds().size.height)
            })
            .unwrap();
        // Vertical padding 7 and 9 around one line of 13 and 14 pt Figtree.
        assert!(f32::from(proto) > 14. + 13. && f32::from(proto) < 14. + 20., "{proto:?}");
        assert!(f32::from(primary) > 18. + 14. && f32::from(primary) < 18. + 22., "{primary:?}");
        cx.update(|cx| {
            let p = pal(cx);
            let (bg, active, fg, size, weight, x, y) = ButtonKind::Prototype.style(&p);
            assert_eq!((bg, active, fg, size, weight, x, y), (p.tint, p.button, p.ink, 13., 500., 12., 7.));
            let (bg, active, fg, size, weight, x, y) = ButtonKind::Primary.style(&p);
            assert_eq!((bg, active, fg, size, weight, x, y), (p.primary, p.primary.opacity(0.8), p.on_primary, 14., 500., 16., 9.));
            assert_eq!(primary_button("x", "y").disabled_level(), 0.45);
            // Swift's serif family name; `fonts.rs` embeds both faces at compile time.
            assert_eq!(GARAMOND, "EB Garamond");
        });
    }

    // parity: SHELL-011 ONB-017 ONB-018
    /// A closed window goes to the menu bar; reopening shows the same in-memory step.
    #[flow_ui::gpui::test]
    async fn reopening_keeps_the_setup_step(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let window = open_shell(cx);
        cx.update(|cx| cx.global_mut::<Core>().prefs.set("setupVersion", 0));
        let step = flow_core::onboarding::Step::Purpose;
        window.update(cx, |shell, _, cx| shell.onboarding.update(cx, |p, _| p.setup.step = step)).unwrap();
        cx.update(|cx| window_closed(window.window_id(), cx));
        window.update(cx, |_, w, _| w.remove_window()).unwrap();
        cx.run_until_parked();
        assert!(get(cx, |s| s.window.is_none() && s.parked_setup.is_some()));
        // `on_reopen` calls `open`; the test platform opens the window it would.
        let again = cx.add_window(|w, cx| Shell::new(w, cx));
        cx.run_until_parked();
        assert_eq!(again.update(cx, |shell, _, cx| shell.onboarding.read(cx).setup.step).unwrap(), step);
        assert!(get(cx, |s| s.parked_setup.is_none()));
    }
}
