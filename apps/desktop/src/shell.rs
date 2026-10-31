//! The main window: onboarding gate, sidebar, content card and router, and `Session`, the plain
//! view model standing in for Swift's `AppServices` until capture and models exist.
use crate::core::Core;
use crate::insertion::{self, Insertion};
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

pub const SETUP_STARTING: &str = "Starting…";
pub const SETUP_FAILED: &str = "Setup could not finish. Check app storage and the model manifest.";

/// A modal on top of the window. Swift uses SwiftUI's `.alert` and `NSAlert`; an in-window panel
/// keeps the text exposed to accessibility on both platforms.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Alert {
    DiscardUnsaved,
    QuitUnsaved,
    RecordingCantWait,
}

/// The state Swift keeps on `AppServices`, `MainWindowRouter` and the coordinators.
pub struct Session {
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
}
impl Global for Session {}

impl Session {
    pub fn new(core: &Core) -> Session {
        let stores_ready = core.db.is_some();
        let mut s = Session {
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

/// `applyAppearance()`: the `appearance` preference over the system's, plus Increase Contrast.
const DEFAULT_SIZE: Size<Pixels> = size(px(1100.), px(760.));
const MIN_SIZE: Size<Pixels> = size(px(720.), px(560.));

/// The settings page calls this after writing the preference.
pub fn apply_appearance(cx: &mut App) {
    let dark = match cx.global::<Core>().prefs.string("appearance").as_deref() {
        Some("dark") => true,
        Some("light") => false,
        _ => matches!(cx.window_appearance(), WindowAppearance::Dark | WindowAppearance::VibrantDark),
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
    apply_appearance(cx);
}

/// `MainWindowRouter.open`: select, become a regular app, open or restore the window, activate.
pub fn open(destination: Option<Page>, cx: &mut App) {
    if let Some(page) = destination {
        update_session(cx, |s| s.selection = page);
    }
    cx.set_activation_policy(ActivationPolicy::Regular);
    let window = cx.global::<Session>().window;
    let alive = window.is_some_and(|w| cx.update_window(w.into(), |_, w, _| w.activate_window()).is_ok());
    if !alive {
        open_main_window(cx);
    }
    cx.activate(true);
}

/// `MainWindowRouter.showSettings(at: .microphones)`.
pub fn show_microphones(cx: &mut App) {
    update_session(cx, |s| s.microphones_anchor = true);
    open(Some(Page::Settings), cx);
}

pub fn open_main_window(cx: &mut App) {
    // The audit opens a window that takes no focus and stays out of the tiling layout.
    let audit = std::env::var_os("LOCALFLOW_AUDIT_WINDOW").is_some();
    let options = if audit {
        let bounds = Bounds { origin: point(px(30.), px(60.)), size: size(px(1180.), px(780.)) };
        WindowOptions { window_bounds: Some(WindowBounds::Windowed(bounds)), titlebar: None, focus: false, kind: WindowKind::PopUp, is_movable: false, ..Default::default() }
    } else {
        let bounds = Bounds::centered(None, DEFAULT_SIZE, cx);
        WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(bounds)),
            titlebar: Some(TitlebarOptions { title: Some("LocalFlow".into()), appears_transparent: true, traffic_light_position: Some(point(px(9.), px(9.))) }),
            window_min_size: Some(MIN_SIZE),
            ..Default::default()
        }
    };
    let (handle, _) = flow_ui::open_window(options, cx, |w, cx| cx.new(|cx| Shell::new(w, cx))).expect("main window opens");
    update_session(cx, |s| s.window = Some(handle));
}

/// Closing keeps the app in the menu bar; the policy drops back so the Dock icon goes.
pub fn window_closed(id: WindowId, cx: &mut App) {
    if cx.global::<Session>().window.map(|w| w.window_id()) != Some(id) {
        return;
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
}

pub struct Shell {
    meetings: Entity<NotetakerPage>,
    history: Entity<HistoryPage>,
    insights: Entity<InsightsPage>,
    dictionary: Entity<DictionaryPage>,
    settings: Entity<SettingsPage>,
    onboarding: Entity<OnboardingPage>,
    _subs: Vec<Subscription>,
    _polling: Task<()>,
}

impl Shell {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        ensure_session(cx);
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
        ];
        // `observeSettingsWhileVisible`: only Settings and onboarding poll, every 500 ms.
        let polling = cx.spawn_in(window, async move |_, cx| {
            loop {
                cx.background_executor().timer(Duration::from_millis(500)).await;
                let alive = cx.update(|w, cx| {
                    let on_settings = cx.global::<Session>().selection == Page::Settings || !Self::onboarded(cx);
                    if on_settings && w.is_window_active() {
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
            _subs: subs,
            _polling: polling,
        }
    }
    pub fn onboarded(cx: &App) -> bool {
        cx.global::<Core>().prefs.int_or("setupVersion", 0) >= 1
    }

    fn nav_item(&self, page: Page, title: &'static str, symbol: &'static str, id: &'static str, cx: &mut Context<Self>) -> impl IntoElement {
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
                    .child(self.nav_item(Page::Meetings, "Notetaker", "record.circle", "navigation.notetaker", cx))
                    .child(self.nav_item(Page::History, "Transcriptions", "mic", "navigation.transcriptions", cx))
                    .child(self.nav_item(Page::Insights, "Insights", "chart.bar", "navigation.insights", cx))
                    .child(self.nav_item(Page::Dictionary, "Dictionary", "text.book.closed", "navigation.dictionary", cx)),
            )
            .child(div().flex_1())
            .children(self.active_note(cx))
            .when(attention, |d| d.child(div().px(px(10.)).pb(px(8.)).child(sf_label("exclamationmark.circle", "Review needed", 13., p.warning))))
            .child(hairline(cx).mb(px(8.)))
            .child(div().pb(px(12.)).child(self.nav_item(Page::Settings, "Settings", "gearshape", "navigation.settings", cx)))
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
                                        .on_click(|_, _, cx| update_session(cx, |s| s.alert = Some(Alert::DiscardUnsaved))),
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

/// `LiveRecordingBadge`: waveform or pause symbol and a tabular timer.
pub fn live_badge(state: MeetingState, elapsed_ms: i64, size: f32, p: &Palette, reduce_motion: bool) -> impl IntoElement {
    let color = if state == MeetingState::Paused { p.muted } else { p.success };
    let symbol = if state == MeetingState::Paused { "pause.fill" } else { "waveform" };
    let duration = duration_text(elapsed_ms);
    let glyph = div().child(icon(symbol, size - 1., color));
    let animated = state == MeetingState::Recording && !reduce_motion;
    h_flex()
        .id("meeting.elapsed")
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
        .bg(black().opacity(0.2))
        .occlude()
        .child(v_flex().w(px(width)).p(px(padding)).bg(p.surface).border_1().border_color(p.line).rounded(px(14.)).shadow_lg().text_color(p.ink).text_size(px(14.)).child(content))
}

fn alert_view(alert: Alert, cx: &mut App) -> impl IntoElement {
    let p = pal(cx);
    let (id, title, message) = match alert {
        Alert::DiscardUnsaved => ("alert.discard", "Discard unsaved text?", "This text has not been saved. Discarding it cannot be undone."),
        Alert::QuitUnsaved => ("alert.quit", "Quit with unsaved text?", "This text will be lost. Copy it or retry saving before quitting."),
        Alert::RecordingCantWait => ("alert.recording", "This recording can't wait for your server", "Twenty dictations are already waiting, or the recording could not be stored. Save its audio to keep it, or discard it."),
    };
    let close = |_: &ClickEvent, _: &mut Window, cx: &mut App| update_session(cx, |s| s.alert = None);
    let row = h_flex().gap(px(8.)).justify_end();
    let buttons = match alert {
        Alert::DiscardUnsaved => row.child(prototype_button("alert.keep", "Keep text").on_click(close)).child(prototype_button("alert.confirmDiscard", "Discard").text_color(p.warning).on_click(|_, _, cx| {
            update_session(cx, |s| {
                let d = s.dictation.as_mut().unwrap();
                d.unsaved = None;
                d.status = "Unsaved text discarded.".into();
                s.alert = None;
            })
        })),
        Alert::QuitUnsaved => row.child(primary_button("alert.keepOpen", "Keep Open").on_click(close)).child(prototype_button("alert.quitLose", "Quit and Lose Text").on_click(|_, _, cx| {
            update_session(cx, |s| s.alert = None);
            crate::menu::finish_quit(cx);
        })),
        Alert::RecordingCantWait => row
            .child(primary_button("alert.saveAudio", "Save Audio…").on_click(|_, _, cx| {
                // Read and write errors are silent in Swift too (SHELL-248).
                let _ = cx.global::<Core>().services.choose_save_path("LocalFlow dictation.wav");
                update_session(cx, |s| s.alert = None);
            }))
            .child(prototype_button("alert.discardRecording", "Discard").on_click(close)),
    };
    modal(id, 340., 20., cx, v_flex().gap(px(12.)).child(t(title).font(14., 600.)).child(t(message).size(13.)).child(buttons))
}

impl Render for Shell {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let alert = cx.global::<Session>().alert;
        let reviewing = cx.global::<Session>().insertion.is_reviewing();
        if !Self::onboarded(cx) {
            return div().size_full().bg(p.canvas).text_color(p.ink).child(self.onboarding.clone()).into_any_element();
        }
        let compact = window.viewport_size().width <= px(800.);
        cx.global_mut::<Flow>().compact = compact;
        let page = self.destination(cx);
        let notice = self.recovery_notice(cx);
        let sidebar = self.sidebar(cx);
        let alert_el = alert.map(|a| alert_view(a, cx).into_any_element());
        let review_el = reviewing.then(|| insertion::review_sheet(cx).into_any_element());
        h_flex()
            .id("shell.library")
            .key_context("Shell")
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
            .children(alert_el)
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

    // parity: SHELL-026 SHELL-027
    #[test]
    fn window_sizes_match_swift() {
        assert_eq!(DEFAULT_SIZE, size(px(1100.), px(760.)));
        assert_eq!(MIN_SIZE, size(px(720.), px(560.)));
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

    // parity: SHELL-040..SHELL-051 SHELL-060 SHELL-224 SHELL-029 SHELL-030 SHELL-068 SHELL-070 SHELL-072 SHELL-075 SHELL-077
    #[flow_ui::gpui::test]
    async fn sidebar_rows_navigate_and_mark_selection(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let window = open_shell(cx);
        frame(cx, window);
        assert_saw(&["LocalFlow", "Notetaker", "Transcriptions", "Insights", "Dictionary", "Settings"]);
        for (id, page) in [
            ("navigation.notetaker", Page::Meetings),
            ("navigation.insights", Page::Insights),
            ("navigation.dictionary", Page::Dictionary),
            ("navigation.settings", Page::Settings),
            ("navigation.transcriptions", Page::History),
        ] {
            cx.update_window(window.into(), |_, w, cx| w.click(id, cx)).unwrap();
            frame(cx, window);
            assert_eq!(get(cx, |s| s.selection), page);
            cx.update_window(window.into(), |_, w, _| {
                let row = w.find(id);
                assert_eq!(row.bounds().size.height, px(35.), "{id}");
            }).unwrap();
        }
        // Clicking persists nothing: the landing page stays derived from the purpose.
        cx.update(|cx| assert!(!cx.global::<Core>().prefs.contains("selection")));
    }

    // parity: SHELL-069 SHELL-071 SHELL-073 SHELL-076 SHELL-078 SHELL-080 SHELL-103 SHELL-106 SHELL-095
    #[flow_ui::gpui::test]
    async fn pages_show_unavailable_until_stores_exist(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let window = open_shell(cx);
        set(cx, |s| {
            s.stores_ready = false;
            s.meetings_available = false;
            s.dictation = None;
        });
        for (page, title) in [(Page::Meetings, "Meetings unavailable"), (Page::History, "Transcriptions unavailable"), (Page::Insights, "Insights unavailable"), (Page::Dictionary, "Dictionary unavailable")] {
            set(cx, |s| s.selection = page);
            frame(cx, window);
            assert_saw(&[title, SETUP_STARTING]);
        }
        // Settings is always available.
        set(cx, |s| s.selection = Page::Settings);
        frame(cx, window);
        assert!(!crate::testing::saw("unavailable"));
        // A database that can't open reports the launch failure, through the same views.
        set(cx, |s| {
            s.setup_status = SETUP_FAILED.into();
            s.selection = Page::History;
        });
        frame(cx, window);
        assert_saw(&[SETUP_FAILED]);
        cx.update(|cx| assert_eq!(readiness(cx), SETUP_FAILED));
    }

    // parity: SHELL-104 SHELL-105 SHELL-107..SHELL-120
    #[flow_ui::gpui::test]
    async fn setup_status_copy_reaches_the_unavailable_view(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let window = open_shell(cx);
        set(cx, |s| s.stores_ready = false);
        for copy in SETUP_STATUS_COPY {
            set(cx, |s| s.setup_status = (*copy).into());
            frame(cx, window);
            assert_saw(&[copy]);
        }
    }

    // parity: SHELL-053 SHELL-054 SHELL-055 SHELL-056 SHELL-057 SHELL-058
    #[flow_ui::gpui::test]
    async fn active_note_card_opens_its_meeting(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let window = open_shell(cx);
        frame(cx, window);
        cx.update_window(window.into(), |_, w, _| assert!(w.try_find("navigation.activeNote").is_none())).unwrap();
        let meeting = |state, title: Option<&str>| Some(MeetingStatus { id: "m1".into(), title: title.map(Into::into), state, elapsed_ms: 754_000 });
        for (state, label) in [(MeetingState::Recording, "Recording"), (MeetingState::Paused, "Paused"), (MeetingState::Preparing, "Preparing"), (MeetingState::Created, "Created"), (MeetingState::Finalizing, "Finalizing")] {
            set(cx, |s| s.meeting = meeting(state, Some("Weekly planning")));
            frame(cx, window);
            assert_saw(&["Weekly planning", "12:34"]);
            assert_eq!(state.badge_text(), label);
        }
        set(cx, |s| s.meeting = meeting(MeetingState::Recording, None));
        frame(cx, window);
        assert_saw(&["Untitled note"]);
        cx.update_window(window.into(), |_, w, cx| w.click("navigation.activeNote", cx)).unwrap();
        assert_eq!(get(cx, |s| s.selection), Page::Meetings);
        cx.update(|cx| {
            open_note("m1".into(), cx);
            assert_eq!(cx.global::<Session>().open_meeting.clone().map(|m| m.0), Some("m1".to_string()));
        });
        // A finished meeting has no card.
        set(cx, |s| s.meeting = meeting(MeetingState::Completed, None));
        frame(cx, window);
        cx.update_window(window.into(), |_, w, _| assert!(w.try_find("navigation.activeNote").is_none())).unwrap();
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
        set(cx, |s| {
            let d = s.dictation.as_mut().unwrap();
            d.storage_blocked = false;
            d.capacity_blocked = true;
        });
        frame(cx, window);
        assert_saw(&["Review needed", "History is full. Open Transcriptions and delete saved text before recording again."]);
        cx.update_window(window.into(), |_, w, _| assert!(w.try_find("recovery.retryStorage").is_none())).unwrap();
        set(cx, |s| {
            let d = s.dictation.as_mut().unwrap();
            d.capacity_blocked = false;
            d.unsaved = Some("Keep this".into());
        });
        frame(cx, window);
        assert_saw(&["Unsaved text", "This text will be lost if you quit. Copy does not save it.", "Keep this", "Retry save", "Copy", "Discard…"]);
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
        frame(cx, window);
        assert_saw(&["Discard unsaved text?", "This text has not been saved. Discarding it cannot be undone.", "Keep text", "Discard"]);
        cx.update_window(window.into(), |_, w, cx| w.click("alert.keep", cx)).unwrap();
        assert!(get(cx, |s| s.alert.is_none() && s.dictation.as_ref().unwrap().unsaved.is_some()));
        frame(cx, window);
        cx.update_window(window.into(), |_, w, cx| w.click("recovery.discard", cx)).unwrap();
        frame(cx, window);
        cx.update_window(window.into(), |_, w, cx| w.click("alert.confirmDiscard", cx)).unwrap();
        assert!(get(cx, |s| s.alert.is_none() && s.dictation.as_ref().unwrap().unsaved.is_none()));
        frame(cx, window);
        assert!(!crate::testing::saw("Unsaved text"));
        // Retry save, on a fresh buffer.
        set(cx, |s| s.dictation.as_mut().unwrap().unsaved = Some("Again".into()));
        frame(cx, window);
        cx.update_window(window.into(), |_, w, cx| w.click("recovery.retrySave", cx)).unwrap();
        assert_eq!(get(cx, |s| s.dictation.as_ref().unwrap().status.clone()), "Text saved for review.");
    }

    // parity: SHELL-093 SHELL-094 SHELL-096..SHELL-102 MENU-006
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
        });
    }

    // parity: SHELL-039 SHELL-015
    #[flow_ui::gpui::test]
    async fn appearance_preference_switches_the_palette(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        cx.update(|cx| {
            cx.global_mut::<Core>().prefs.set("appearance", "dark");
            apply_appearance(cx);
            assert_eq!(pal(cx).mode, Mode::Dark);
            cx.global_mut::<Core>().prefs.set("appearance", "light");
            refresh_display_options(cx);
            assert_eq!(pal(cx).mode, Mode::Light);
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

    // parity: SHELL-005 SHELL-010 SHELL-037 SHELL-063 SHELL-064 SHELL-065 SHELL-066 SHELL-062
    #[flow_ui::gpui::test]
    async fn router_keeps_selection_across_close(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let window = open_shell(cx);
        cx.update(|cx| show_microphones(cx));
        assert_eq!(get(cx, |s| (s.selection, s.microphones_anchor)), (Page::Settings, true));
        cx.update(|cx| window_closed(window.window_id(), cx));
        assert_eq!(get(cx, |s| (s.selection, s.window.is_none())), (Page::Settings, true));
    }
}
