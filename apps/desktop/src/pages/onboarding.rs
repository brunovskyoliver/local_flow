//! The first-run flow. The window shows this until `setupVersion >= 1` (`OnboardingView`).
mod parts;
mod remote;
mod scenario;
mod steps;
#[cfg(test)]
mod tests;

use crate::core::Core;
use crate::pages::Page;
use flow_core::onboarding::*;
use flow_platform::{Permission, PermissionState, SessionCommand, Unavailable};
use flow_ui::prelude::*;
use parts::Click;
use std::path::PathBuf;
use std::time::Duration;

/// `RemoteDictationModel`'s view state; the rest is in preferences.
#[derive(Default)]
pub struct RemoteState {
    pub identity: Option<String>,
    pub pinned: Option<String>,
    pub busy: bool,
    pub error: Option<String>,
    pub consent_open: bool,
    pub confirm_off: bool,
    pub google: bool,
}

pub struct OnboardingPage {
    pub setup: Setup,
    pub snap: Snapshot,
    /// `settings.performing` and `settings.error`.
    pub performing: bool,
    pub error: Option<String>,
    pub recording: bool,
    pub recording_error: Option<String>,
    pub memory: u64,
    pub downloaded: [bool; 5],
    pub selection: usize,
    pub ai_phase: AiPhase,
    pub local_helpers_ready: bool,
    pub remote: RemoteState,
    pub legacy_open: bool,
    pub credential_present: bool,
    pub credential_error: Option<String>,
    pub connection_testing: bool,
    /// `Ok` holds the optional server name and model that are present.
    pub connection: Option<Result<Vec<String>, String>>,
    pub analysis: Option<String>,
    /// A scenario or test fixes the snapshot; polling leaves it alone.
    pub frozen: bool,
    pending_credential_clear: bool,
    server_draft: Entity<InputState>,
    endpoint_input: Entity<InputState>,
    credential_input: Entity<InputState>,
    focus: FocusHandle,
    _subs: Vec<Subscription>,
    _polling: Option<Task<()>>,
}

/// `~/.mtplx/models`, or inside the data root when one is set, so an audit never reads the owner's.
fn models_dir() -> PathBuf {
    if cfg!(test) {
        return std::env::temp_dir().join("localflow-test-no-models");
    }
    let base = std::env::var_os("LOCALFLOW_DATA_ROOT").or_else(|| std::env::var_os("HOME")).map(PathBuf::from).unwrap_or_default();
    base.join(".mtplx/models")
}

fn perm(s: PermissionState) -> Perm {
    match s {
        PermissionState::NotAsked => Perm::Unknown,
        PermissionState::Granted | PermissionState::NotRequired => Perm::Granted,
        PermissionState::Denied => Perm::Denied,
    }
}

/// How a missing service reads in the row or line Swift uses for that failure.
fn missing(e: Unavailable) -> String {
    format!("This build can't use {} yet.", e.0)
}

impl OnboardingPage {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let (mut setup, memory, google_prefs) = {
            let core = cx.global::<Core>();
            (Setup::new(&core.prefs), core.services.physical_memory(), core.services.google_sign_in_available())
        };
        // `AppServices.start()`: before any shortcut is configured.
        setup.resume_unfinished(&mut cx.global_mut::<Core>().prefs);
        let dir = models_dir();
        let downloaded = CATALOG.map(|m| m.is_downloaded(&dir));
        let endpoint = cx.global::<Core>().prefs.string("rewriteEndpoint").unwrap_or_default();
        let server_draft = cx.new(|cx| InputState::new(window, cx).placeholder("https://server.example.com"));
        let endpoint_input = cx.new(|cx| InputState::new(window, cx).placeholder("https://studio.local:8080").default_value(endpoint));
        let credential_input = cx.new(|cx| InputState::new(window, cx).placeholder("The server's LOCALFLOW_REWRITE_TOKEN").masked(true));
        let subs = vec![
            cx.subscribe_in(&endpoint_input, window, |this, input, e: &TextInputEvent, _, cx| {
                if matches!(e, TextInputEvent::Change) {
                    let text = input.read(cx).value().to_string();
                    this.edit_endpoint(text, cx);
                }
            }),
            cx.subscribe_in(&server_draft, window, |this, _, e: &TextInputEvent, _, cx| match e {
                TextInputEvent::Change => cx.notify(),
                TextInputEvent::PressEnter { .. } => this.confirm_consent(cx),
                _ => {}
            }),
            cx.observe_window_activation(window, |this, w, cx| {
                if w.is_window_active() {
                    this.refresh(cx);
                }
            }),
        ];
        let mut page = OnboardingPage {
            setup,
            snap: Snapshot::default(),
            performing: false,
            error: None,
            recording: false,
            recording_error: None,
            memory,
            selection: default_model(&downloaded, memory),
            downloaded,
            ai_phase: AiPhase::Idle,
            local_helpers_ready: false,
            remote: RemoteState { google: google_prefs, ..Default::default() },
            legacy_open: false,
            credential_present: false,
            credential_error: None,
            connection_testing: false,
            connection: None,
            analysis: None,
            frozen: false,
            pending_credential_clear: false,
            server_draft,
            endpoint_input,
            credential_input,
            focus: cx.focus_handle(),
            _subs: subs,
            _polling: None,
        };
        page.effects(cx);
        page.refresh(cx);
        page.apply_scenario(cx);
        // `settingsPageChanged` loop: every 500 ms while the window is active and setup unfinished.
        page._polling = Some(cx.spawn_in(window, async move |this, cx| {
            loop {
                cx.background_executor().timer(Duration::from_millis(500)).await;
                let alive = this.update_in(cx, |this, w, cx| {
                    if w.is_window_active() && !is_complete(&cx.global::<Core>().prefs) {
                        this.refresh(cx);
                    }
                });
                if alive.is_err() {
                    break;
                }
            }
        }));
        page
    }

    fn core<'a>(&self, cx: &'a App) -> &'a Core {
        cx.global::<Core>()
    }

    fn word(&self, cx: &App) -> &'static str {
        self.core(cx).services.device_word()
    }

    fn meeting_only(&self) -> bool {
        self.setup.purpose == Purpose::Meetings
    }

    pub fn selected_model(&self) -> LocalAiModel {
        CATALOG[self.selection]
    }

    /// A click handler that updates this page.
    fn click(&mut self, cx: &mut Context<Self>, f: impl Fn(&mut Self, &mut Context<Self>) + 'static) -> Click {
        Box::new(cx.listener(move |this, _: &ClickEvent, _, cx| f(this, cx)))
    }

    /// `refreshSettingsState`: what polling can see of permissions, shortcut and storage.
    pub fn refresh(&mut self, cx: &mut Context<Self>) {
        if self.frozen {
            return;
        }
        let core = cx.global::<Core>();
        let s = &core.services;
        let mut next = self.snap.clone();
        next.microphone = perm(s.permission(Permission::Microphone));
        next.input_monitoring = perm(s.permission(Permission::InputMonitoring));
        next.accessibility = perm(s.permission(Permission::Accessibility));
        next.system_audio = perm(s.permission(Permission::SystemAudio));
        next.shortcut = Shortcut::load(&core.prefs);
        next.storage_available = core.db.is_some();
        next.speech_model = speech_model_name(&speech_model_raw(&core.prefs)).to_string();
        let resume = self.ai_phase == AiPhase::Failed(AI_ERROR_APPROVAL.into()) && s.background_services_enabled();
        if next != self.snap {
            self.snap = next;
            cx.notify();
        }
        if resume {
            self.start_local_ai(cx);
        }
    }

    /// After any coordinator call: run what it asked for, apply step-entry rules, redraw.
    pub fn after(&mut self, cx: &mut Context<Self>) {
        self.effects(cx);
        // `.task(id: step)`: Right Control is the first-run default; a saved shortcut stays.
        if self.setup.step == Step::Personalize && !self.meeting_only() && !Shortcut::is_saved(&cx.global::<Core>().prefs) {
            self.configure_shortcut(Shortcut::right_control(), cx);
        }
        cx.notify();
    }

    fn effects(&mut self, cx: &mut Context<Self>) {
        for effect in std::mem::take(&mut self.setup.effects) {
            match effect {
                Effect::StartDownloads { local_ai } => {
                    if !self.snap.model_installed && !self.snap.installing {
                        self.start_speech(cx);
                    }
                    if local_ai {
                        self.start_local_ai(cx);
                    }
                }
                Effect::StartMeetingModels => {
                    self.snap.meeting_models_error = cx.global::<Core>().services.install_meeting_models().err().map(missing);
                }
                Effect::CancelMeetingModels => self.snap.meeting_models_error = None,
                Effect::AbandonServer => self.turn_off_remote(cx),
                Effect::OpenNotetaker if cx.has_global::<crate::shell::Session>() => crate::shell::update_session(cx, |s| s.selection = Page::Meetings),
                Effect::OpenNotetaker => {}
            }
        }
    }

    fn start_speech(&mut self, cx: &mut Context<Self>) {
        self.error = cx.global::<Core>().services.install_speech_model().err().map(missing);
        cx.notify();
    }

    /// `LocalAISetup.start()`: a no-op while running or ready, so a later model change is ignored.
    pub fn start_local_ai(&mut self, cx: &mut Context<Self>) {
        if self.ai_phase.running() || self.ai_phase == AiPhase::Ready {
            return;
        }
        self.ai_phase = match cx.global::<Core>().services.install_local_ai(self.selected_model().id) {
            Ok(()) => AiPhase::PreparingRuntime,
            Err(e) => AiPhase::Failed(missing(e)),
        };
        cx.notify();
    }

    /// `LocalAISetup.finish`, for when the installer reports its outcome.
    pub fn local_ai_finished(&mut self, outcome: AiPhase, cx: &mut Context<Self>) {
        if outcome == AiPhase::Ready {
            self.local_helpers_ready = true;
            local_ai_ready(&mut cx.global_mut::<Core>().prefs);
        }
        self.ai_phase = outcome;
        cx.notify();
    }

    fn server_ready(&self, cx: &App) -> bool {
        server_ready(&self.core(cx).prefs, self.setup.purpose, matches!(self.connection, Some(Ok(_))))
    }

    pub fn can_advance(&self, cx: &App) -> bool {
        match self.setup.step {
            Step::Introduction | Step::Purpose | Step::Ai => true,
            Step::AiDetails if self.setup.ai_mode == AiMode::Remote => self.server_ready(cx),
            Step::AiDetails => self.selected_model().fits(self.memory),
            Step::Downloads => self.setup.downloads_ready(&self.snap),
            Step::Permissions | Step::Personalize => !self.recording && if self.meeting_only() { self.snap.ready_for_meetings() } else { self.snap.ready_for_test() && !self.performing },
            Step::Test => self.setup.test_succeeded,
            Step::Complete => false,
        }
    }

    pub fn primary_title(&self) -> String {
        match self.setup.step {
            Step::Introduction => "Get started".into(),
            Step::AiDetails if self.setup.ai_mode == AiMode::Remote => "Use this server".into(),
            Step::AiDetails => format!("{} {}", if self.downloaded[self.selection] { "Use" } else { "Download" }, self.selected_model().name),
            Step::Test => "Finish setup".into(),
            Step::Personalize if self.meeting_only() => "Finish setup".into(),
            _ => "Continue".into(),
        }
    }

    pub fn hint(&self, cx: &App) -> Option<String> {
        match self.setup.step {
            Step::AiDetails if self.setup.ai_mode == AiMode::Remote && !self.server_ready(cx) => Some("Sign in to continue".into()),
            Step::Downloads if !self.snap.model_installed => Some("Waiting for speech recognition…".into()),
            Step::Downloads if !self.setup.downloads_ready(&self.snap) => Some("Waiting for meeting models…".into()),
            Step::Permissions | Step::Personalize if self.meeting_only() => self.snap.meeting_blocked_reason().map(str::to_string),
            Step::Permissions | Step::Personalize => self.snap.test_blocked_reason(),
            _ => None,
        }
    }

    pub fn primary(&mut self, cx: &mut Context<Self>) {
        if !self.can_advance(cx) {
            return;
        }
        if self.setup.step == Step::AiDetails && self.setup.ai_mode == AiMode::Remote {
            let credential = self.credential_present;
            let prefs = &mut cx.global_mut::<Core>().prefs;
            // An enrolled device uses the server for every service it offers; the legacy path only rewrites.
            if enrolled(prefs) {
                prefs.set("server.useForEverything", true);
            }
            set_rewrite_enabled(prefs, credential);
        }
        self.setup.advance(&self.snap, &mut cx.global_mut::<Core>().prefs);
        self.after(cx);
    }

    /// `settings.run` for a permission. Input Monitoring is ignored on the meeting path.
    pub fn allow(&mut self, p: Permission, cx: &mut Context<Self>) {
        if self.performing || (p == Permission::InputMonitoring && self.meeting_only()) {
            return;
        }
        self.error = None;
        let services = &cx.global::<Core>().services;
        let refused = p == Permission::Microphone && self.snap.microphone == Perm::Denied;
        let failure = if refused {
            services.open_permission_settings(p).err()
        } else {
            match services.request_permission(p) {
                Ok(PermissionState::Granted) => None,
                Err(e) if p == Permission::Microphone => Some(e),
                // Swift falls through to the Settings pane whenever the prompt doesn't grant it.
                _ => services.open_permission_settings(p).err(),
            }
        };
        self.error = failure.map(missing);
        self.refresh(cx);
        cx.notify();
    }

    /// `configureShortcut`: skip for meetings, refuse while busy, install, and only then save.
    pub fn configure_shortcut(&mut self, value: Shortcut, cx: &mut Context<Self>) {
        if self.performing || self.meeting_only() {
            return;
        }
        self.error = None;
        if self.snap.busy || self.snap.installing {
            self.error = Some("Another dictation or model operation is still running. Wait for it to finish.".into());
            cx.notify();
            return;
        }
        match cx.global::<Core>().services.install_shortcut(&value.json()) {
            Ok(()) => {
                value.save(&mut cx.global_mut::<Core>().prefs);
                self.snap.shortcut = value;
                self.snap.shortcut_ready = true;
            }
            Err(e) => self.error = Some(missing(e)),
        }
        cx.notify();
    }

    pub fn toggle_recording(&mut self, cx: &mut Context<Self>) {
        if self.recording {
            self.recording = false;
            cx.notify();
            return;
        }
        self.recording_error = None;
        if self.snap.accessibility != Perm::Granted {
            self.recording_error = Some("Allow Accessibility to record and prioritize shortcuts.".into());
        } else {
            match cx.global::<Core>().services.record_shortcut() {
                Ok(()) => self.recording = true,
                Err(e) => self.recording_error = Some(missing(e)),
            }
        }
        cx.notify();
    }

    /// The recorder's result: a value is configured, nil just ends.
    pub fn recorded(&mut self, value: Option<Shortcut>, cx: &mut Context<Self>) {
        self.recording = false;
        if let Some(v) = value {
            self.configure_shortcut(v, cx);
        }
        cx.notify();
    }

    pub fn arm_test(&mut self, cx: &mut Context<Self>) {
        if !self.setup.begin_arming(&self.snap) {
            return;
        }
        let core = cx.global::<Core>();
        // No model load when the server serves dictation.
        let prepared = if enrolled(&core.prefs) { Ok(()) } else { core.services.load_speech_model().map_err(missing) };
        self.setup.finish_arming(prepared, &self.snap);
        cx.notify();
    }

    fn request_toggle(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if remote_on(&cx.global::<Core>().prefs) {
            self.remote.confirm_off = true;
        } else {
            self.remote.error = None;
            let stored = cx.global::<Core>().prefs.string("remote.serverURL").unwrap_or_default();
            self.server_draft.update(cx, |s, cx| {
                s.set_value(stored, window, cx);
                s.focus(window, cx);
            });
            self.remote.consent_open = true;
        }
        cx.notify();
    }

    fn cancel_consent(&mut self, cx: &mut Context<Self>) {
        self.remote.consent_open = false;
        cx.notify();
    }

    pub fn confirm_consent(&mut self, cx: &mut Context<Self>) {
        if !self.remote.consent_open {
            return;
        }
        let draft = self.server_draft.read(cx).value().to_string();
        if !confirm_remote_consent(&mut cx.global_mut::<Core>().prefs, &draft) {
            self.remote.error = Some("Enter the server's https:// address without a path.".into());
            cx.notify();
            return;
        }
        self.remote.consent_open = false;
        self.fetch_identity(cx);
    }

    pub fn fetch_identity(&mut self, cx: &mut Context<Self>) {
        self.remote.error = None;
        let url = cx.global::<Core>().prefs.string("remote.serverURL").unwrap_or_default();
        match cx.global::<Core>().services.fetch_server_identity(&url) {
            Ok(fingerprint) => self.remote.identity = Some(fingerprint),
            Err(_) => {
                self.remote.identity = None;
                self.remote.error = Some("The server did not answer with a LocalFlow identity. Check the address.".into());
            }
        }
        cx.notify();
    }

    pub fn trust_server(&mut self, cx: &mut Context<Self>) {
        let Some(fingerprint) = self.remote.identity.clone() else { return };
        if cx.global::<Core>().services.set_secret("remote.serverKey", &fingerprint).is_err() {
            self.remote.error = Some("The server identity could not be saved.".into());
        } else {
            let prefs = &mut cx.global_mut::<Core>().prefs;
            prefs.remove("remote.notice");
            prefs.set("remote.state", "pinned");
            self.remote.pinned = Some(fingerprint);
            self.remote.identity = None;
        }
        cx.notify();
    }

    pub fn sign_in(&mut self, provider: &str, cx: &mut Context<Self>) {
        self.remote.error = None;
        match cx.global::<Core>().services.enroll_device(provider) {
            Ok(state) => cx.global_mut::<Core>().prefs.set("remote.state", state),
            // Nothing reached a server, so this is Swift's sign-in failure, not "could not be reached".
            Err(_) => self.remote.error = Some("Sign-in did not finish.".into()),
        }
        cx.notify();
    }

    fn confirm_turn_off(&mut self, cx: &mut Context<Self>) {
        self.remote.confirm_off = false;
        self.turn_off_remote(cx);
        cx.notify();
    }

    /// `turnOffRemoteDictation()`.
    fn turn_off_remote(&mut self, cx: &mut Context<Self>) {
        self.remote.identity = None;
        self.remote.pinned = None;
        self.remote.error = None;
        reset_remote(&mut cx.global_mut::<Core>().prefs);
    }

    /// `settings.rewriteEndpoint`'s setter: per keystroke.
    fn edit_endpoint(&mut self, text: String, cx: &mut Context<Self>) {
        let credential = self.credential_present;
        let prefs = &mut cx.global_mut::<Core>().prefs;
        let old = rewrite_origin(&prefs.string("rewriteEndpoint").unwrap_or_default());
        let new = rewrite_origin(&text);
        let changed = old != new;
        if changed {
            for origin in [&old, &new].into_iter().flatten() {
                set_insecure_override(prefs, origin, false);
            }
        }
        prefs.set("rewriteEndpoint", text);
        if rewrite_refusal(prefs, credential && !changed).is_some() {
            prefs.set("rewriteEnabled", false);
        }
        if changed {
            self.credential_error = None;
            self.credential_present = new.is_some_and(|o| matches!(cx.global::<Core>().services.secret(&format!("rewrite.{o}")), Ok(Some(_))));
        }
        self.connection = None;
        self.analysis = None;
        cx.notify();
    }

    fn set_insecure(&mut self, on: bool, cx: &mut Context<Self>) {
        let credential = self.credential_present;
        let prefs = &mut cx.global_mut::<Core>().prefs;
        if let Some(origin) = rewrite_origin(&prefs.string("rewriteEndpoint").unwrap_or_default()) {
            set_insecure_override(prefs, &origin, on);
        }
        if rewrite_refusal(prefs, credential).is_some() {
            prefs.set("rewriteEnabled", false);
        }
        self.connection = None;
        self.analysis = None;
        cx.notify();
    }

    /// Saves a typed key, then preflights, then asks the server.
    pub fn connect(&mut self, window_free: &mut Context<Self>) {
        let cx = window_free;
        let draft = self.credential_input.read(cx).value().to_string();
        let endpoint = cx.global::<Core>().prefs.string("rewriteEndpoint").unwrap_or_default();
        let origin = rewrite_origin(&endpoint);
        self.analysis = None;
        if !draft.is_empty() {
            self.credential_error = match (&origin, credential_problem(&draft)) {
                (None, _) => Some("Enter a valid endpoint before setting a credential.".into()),
                (_, Some(problem)) => Some(problem.into()),
                (Some(o), None) => match cx.global::<Core>().services.set_secret(&format!("rewrite.{o}"), &draft) {
                    Ok(()) => {
                        self.credential_present = true;
                        self.pending_credential_clear = true;
                        None
                    }
                    Err(_) => Some("Could not access the credential in Keychain.".into()),
                },
            };
        }
        if let Some(refusal) = rewrite_refusal(&cx.global::<Core>().prefs, self.credential_present) {
            self.connection = Some(Err(refusal.to_string()));
            cx.notify();
            return;
        }
        match cx.global::<Core>().services.rewrite_health(&endpoint) {
            Ok((server, model, analysis)) => {
                self.connection = Some(Ok([server, model].into_iter().flatten().collect()));
                self.analysis = Some(analysis);
            }
            Err(_) => self.connection = Some(Err("Could not reach the server.".into())),
        }
        cx.notify();
    }

    fn progress(&self, cx: &App) -> impl IntoElement {
        let p = pal(cx);
        let path = self.setup.path();
        let current = path.iter().position(|s| *s == self.setup.step).unwrap_or(0);
        h_flex()
            .id("onboarding.progress")
            .gap(px(5.))
            .role(flow_ui::gpui::accesskit::Role::Group)
            .aria_label(format!("Step {} of {}", current + 1, path.len()))
            .children((0..path.len()).map(|i| div().h(px(5.)).w(px(if i == current { 22. } else { 8. })).rounded_full().bg(if i <= current { p.accent } else { p.line })))
            .test_support()
    }

    fn footer(&mut self, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let step = self.setup.step;
        let back = (step != Step::Introduction && step != Step::Complete).then(|| {
            let press = self.click(cx, |this, cx| {
                this.setup.back();
                this.after(cx);
            });
            plain_button("onboarding.back", "Back").on_click(press).content(t("Back").size(14.).color(p.muted).a11y_hidden())
        });
        let skip_ai = (step == Step::Ai).then(|| {
            let press = self.click(cx, |this, cx| {
                this.setup.skip_ai(&mut cx.global_mut::<Core>().prefs);
                this.after(cx);
            });
            prototype_button("onboarding.skipAI", "Skip for now").on_click(press)
        });
        let skip_test = (step == Step::Test && !self.setup.test_succeeded).then(|| {
            let press = self.click(cx, |this, cx| {
                this.setup.skip_test(&this.snap.clone(), &mut cx.global_mut::<Core>().prefs);
                this.after(cx);
            });
            prototype_button("onboarding.skipTest", "Skip test").a11y_label("Skip test. Finish setup without recording a dictation.").on_click(press)
        });
        let primary = (step != Step::Complete).then(|| {
            let press = self.click(cx, |this, cx| this.primary(cx));
            primary_button("onboarding.primary", self.primary_title()).disabled(!self.can_advance(cx)).on_click(press)
        });
        h_flex()
            .relative()
            .w_full()
            .flex_none()
            .gap(px(12.))
            .px(px(40.))
            .py(px(18.))
            .child(div().absolute().top_0().left_0().right_0().child(hairline(cx)))
            .children(back)
            .child(div().flex_1())
            .when_some(self.hint(cx), |d, h| d.child(t(h).size(12.).color(p.muted)))
            .children(skip_ai)
            .children(skip_test)
            .children(primary)
    }
}

impl Render for OnboardingPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if self.pending_credential_clear {
            self.pending_credential_clear = false;
            self.credential_input.update(cx, |s, cx| s.set_value("", window, cx));
        }
        if window.focused(cx).is_none() {
            self.focus.focus(window, cx);
        }
        let p = pal(cx);
        let reduce = cx.global::<Flow>().reduce_motion;
        let step = self.setup.step;
        let content = v_flex().w_full().items_start().gap(px(24.)).children(self.content(cx));
        let content = if reduce {
            content.into_any_element()
        } else {
            content.with_animation(("onboarding.step", step as u64), Animation::new(Duration::from_millis(250)), |d, delta| d.opacity(delta)).into_any_element()
        };
        let footer = self.footer(cx).into_any_element();
        let overlays = self.overlays(cx);
        v_flex()
            .id("onboarding")
            .track_focus(&self.focus)
            .relative()
            .size_full()
            .bg(p.canvas)
            .text_color(p.ink)
            .text_size(px(14.))
            .on_key_down(cx.listener(|this, e: &KeyDownEvent, _, cx| match e.keystroke.key.as_str() {
                "enter" if this.remote.consent_open => this.confirm_consent(cx),
                "enter" if !this.remote.confirm_off => this.primary(cx),
                "escape" if this.remote.consent_open => this.cancel_consent(cx),
                "escape" if this.remote.confirm_off => {
                    this.remote.confirm_off = false;
                    cx.notify();
                }
                // `onExitCommand`: cancels a dictation. It does not go Back.
                "escape" => {
                    let _ = cx.global::<Core>().services.session_command(SessionCommand::CancelDictation);
                }
                _ => {}
            }))
            .child(
                h_flex()
                    .w_full()
                    .flex_none()
                    .gap(px(6.))
                    .h(px(84.))
                    .px(px(40.))
                    .pt(px(52.))
                    .pb(px(12.))
                    .child(icon("chart.bar.xaxis", 19., p.ink))
                    .child(t("LocalFlow").font(17., 700.).tracking(-0.4))
                    .child(div().flex_1())
                    .when(step != Step::Complete, |d| d.child(self.progress(cx))),
            )
            .child(
                div().id("onboarding.scroll").flex_1().min_h_0().w_full().overflow_y_scroll().flex().flex_col().items_center().child(
                    div().w_full().max_w(px(680.)).flex_none().px(px(40.)).py(px(28.)).child(content),
                ),
            )
            .child(footer)
            .children(overlays)
    }
}
