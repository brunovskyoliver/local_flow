//! Settings: state, actions and the sections that aren't Server or Models.
//! Sections live in `settings/server.rs` and `settings/models.rs`; dialogs in `settings/sheets.rs`.
use crate::core::Core;
use flow_core::settings as core;
use flow_core::settings::{Connection, Failure, Health, Identity, InputSnapshot, Permission as Perm, RewriteSettings, Runtime, Shortcut, Snapshot};
use flow_platform::Permission;
use flow_ui::gpui::base::TestSupportExt;
use flow_ui::gpui::DragMoveEvent;
use flow_ui::prelude::*;
use std::cell::Cell;
use std::collections::BTreeMap;
use std::rc::Rc;
use std::time::Duration;

mod models;
mod scenario;
mod server;
mod sheets;
#[cfg(test)]
mod tests;

pub(super) use sheets::{ContextKind, Modal};

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Updates {
    Manual,
    Failed,
    Sparkle { automatic: bool, can_check: bool },
}

pub(super) struct Mics {
    pub entries: Vec<core::InputEntry>,
    pub snapshot: InputSnapshot,
}

/// What a row hands the drag.
#[derive(Clone)]
struct DragMic(String);
impl Render for DragMic {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
    }
}

pub struct SettingsPage {
    focus: FocusHandle,
    scroll: ScrollHandle,
    mic_top: Rc<Cell<Pixels>>,
    pub(super) mic_drop: Option<String>,
    pub(super) visible: bool,
    pub(super) scenario: String,
    pub(super) snapshot: Snapshot,
    pub(super) performing: bool,
    pub(super) error: Option<String>,
    pub(super) recording_error: Option<String>,
    pub(super) recording: bool,
    pub(super) testing: Option<&'static str>,
    pub(super) test_results: BTreeMap<&'static str, String>,
    pub(super) updates: Updates,
    pub(super) mics: Option<Mics>,
    pub(super) modal: Option<Modal>,
    apps: std::cell::RefCell<std::collections::HashMap<String, sheets::AppInfo>>,
    remove_focus: std::cell::RefCell<std::collections::HashMap<String, FocusHandle>>,
    voice_over: bool,
    /// The origin usage enrollment last looked at, so the Keychain isn't read on every refresh.
    usage_origin: Option<String>,
    // Server
    /// A plain-HTTP identity base for the local-server test; production uses the stored origin.
    pub(super) remote_base: Option<String>,
    pub(super) identity: Option<Identity>,
    pub(super) pinned: Option<String>,
    pub(super) busy: bool,
    pub(super) remote_error: Option<String>,
    pub(super) checking: bool,
    pub(super) check_result: Option<String>,
    pub(super) server_advanced: bool,
    pub(super) server_draft: Entity<InputState>,
    // Rewriting
    pub(super) rewrite: RewriteSettings,
    pub(super) endpoint: Entity<InputState>,
    pub(super) credential: Entity<InputState>,
    pub(super) credential_plain: Entity<InputState>,
    pub(super) credential_revealed: bool,
    pub(super) editing_credential: bool,
    pub(super) credential_error: Option<String>,
    pub(super) connection: Option<(Connection, Option<Health>, &'static str)>,
    pub(super) analysis: Option<String>,
    pub(super) connection_testing: bool,
    connection_revision: u64,
    pub(super) rewrite_advanced: bool,
    pub(super) diagnostics_open: bool,
    // Summaries
    pub(super) summary_url: Entity<InputState>,
    pub(super) summary_model: Entity<InputState>,
    pub(super) summary_key: Entity<InputState>,
    pub(super) summary_key_saved: bool,
    pub(super) editing_summary_key: bool,
    pub(super) summary_key_error: Option<String>,
    // Context sheet
    pub(super) bundle_draft: Entity<InputState>,
    pub(super) add_category: &'static str,
    pub(super) exclusion_error: Option<&'static str>,
    pub(super) kind_error: Option<&'static str>,
    _subs: Vec<Subscription>,
    _poll: Task<()>,
}

pub(super) fn val(e: &Entity<InputState>, cx: &App) -> String {
    e.read(cx).value().to_string()
}
fn prefs(cx: &App) -> &flow_core::prefs::Prefs {
    &cx.global::<Core>().prefs
}
pub(super) fn prefs_mut(cx: &mut App) -> &mut flow_core::prefs::Prefs {
    &mut cx.global_mut::<Core>().prefs
}
fn map_perm(s: flow_platform::PermissionState) -> Perm {
    match s {
        flow_platform::PermissionState::NotAsked => Perm::Unknown,
        flow_platform::PermissionState::Denied => Perm::Denied,
        _ => Perm::Granted,
    }
}

impl SettingsPage {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let scenario = cx.global::<Core>().scenario.clone().and_then(|s| s.strip_prefix("settings.").map(String::from)).unwrap_or_default();
        scenario::seed(&scenario, prefs_mut(cx));
        core::migrate(prefs_mut(cx));
        let p = prefs(cx);
        let (endpoint_text, url_text, model_text) = (p.string("rewriteEndpoint").unwrap_or_default(), p.string("summaryServerURL").unwrap_or_default(), p.string("summaryServerModel").unwrap_or_default());
        let endpoint = cx.new(|cx| InputState::new(window, cx).default_value(endpoint_text));
        let credential = cx.new(|cx| InputState::new(window, cx).placeholder("Enter server secret").masked(true));
        let credential_plain = cx.new(|cx| InputState::new(window, cx).placeholder("Enter server secret"));
        let summary_url = cx.new(|cx| InputState::new(window, cx).default_value(url_text));
        let summary_model = cx.new(|cx| InputState::new(window, cx).placeholder("Model").default_value(model_text));
        let summary_key = cx.new(|cx| InputState::new(window, cx).placeholder("API key").masked(true));
        let server_draft = cx.new(|cx| InputState::new(window, cx));
        let bundle_draft = cx.new(|cx| InputState::new(window, cx).placeholder("Bundle ID"));
        let subs = vec![
            cx.subscribe_in(&endpoint, window, |this, input, e: &TextInputEvent, w, cx| {
                if matches!(e, TextInputEvent::Change) {
                    let text = val(input, cx);
                    this.edit_endpoint(text, w, cx);
                }
            }),
            cx.subscribe_in(&credential, window, |this, _, e: &TextInputEvent, w, cx| match e {
                TextInputEvent::PressEnter { .. } => this.save_credential(w, cx),
                TextInputEvent::Change => cx.notify(),
                _ => {}
            }),
            cx.subscribe_in(&credential_plain, window, |this, _, e: &TextInputEvent, w, cx| match e {
                TextInputEvent::PressEnter { .. } => this.save_credential(w, cx),
                TextInputEvent::Change => cx.notify(),
                _ => {}
            }),
            cx.subscribe_in(&summary_url, window, |_, input, e: &TextInputEvent, _, cx| {
                if matches!(e, TextInputEvent::Change) {
                    let text = val(input, cx);
                    prefs_mut(cx).set("summaryServerURL", text);
                    cx.notify();
                }
            }),
            cx.subscribe_in(&summary_model, window, |_, input, e: &TextInputEvent, _, cx| {
                if matches!(e, TextInputEvent::Change) {
                    let text = val(input, cx);
                    prefs_mut(cx).set("summaryServerModel", text);
                    cx.notify();
                }
            }),
            cx.subscribe_in(&summary_key, window, |this, _, e: &TextInputEvent, w, cx| match e {
                TextInputEvent::PressEnter { .. } => this.save_summary_key(w, cx),
                TextInputEvent::Change => cx.notify(),
                _ => {}
            }),
            cx.subscribe_in(&server_draft, window, |this, _, e: &TextInputEvent, _, cx| match e {
                TextInputEvent::PressEnter { .. } => this.confirm_consent(cx),
                TextInputEvent::Change => cx.notify(),
                _ => {}
            }),
            cx.subscribe_in(&bundle_draft, window, |this, _, e: &TextInputEvent, w, cx| match e {
                TextInputEvent::PressEnter { .. } => this.add_context_app(w, cx),
                TextInputEvent::Change => cx.notify(),
                _ => {}
            }),
        ];
        // `observeSettingsWhileVisible`: polls while Settings is the selected page. Leaving is seen
        // on the next tick. ponytail: up to 500 ms late, an on-page-change hook when that matters.
        let poll = cx.spawn_in(window, async move |this, cx| {
            loop {
                cx.background_executor().timer(Duration::from_millis(500)).await;
                if this.update_in(cx, |this, w, cx| this.tick(w, cx)).is_err() {
                    break;
                }
            }
        });
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        let mut page = SettingsPage {
            focus,
            scroll: ScrollHandle::new(),
            mic_top: Rc::new(Cell::new(px(0.))),
            mic_drop: None,
            visible: true,
            scenario: scenario.clone(),
            snapshot: Snapshot::default(),
            performing: false,
            error: None,
            recording_error: None,
            recording: false,
            testing: None,
            test_results: BTreeMap::new(),
            updates: if cx.global::<Core>().services.can_check_for_updates() { Updates::Sparkle { automatic: false, can_check: true } } else { Updates::Manual },
            mics: None,
            modal: None,
            apps: Default::default(),
            remove_focus: Default::default(),
            voice_over: cx.global::<Core>().services.voice_over_on(),
            usage_origin: None,
            remote_base: None,
            identity: None,
            pinned: None,
            busy: false,
            remote_error: None,
            checking: false,
            check_result: None,
            server_advanced: false,
            server_draft,
            rewrite: RewriteSettings::default(),
            endpoint,
            credential,
            credential_plain,
            credential_revealed: false,
            editing_credential: false,
            credential_error: None,
            connection: None,
            analysis: None,
            connection_testing: false,
            connection_revision: 0,
            rewrite_advanced: false,
            diagnostics_open: false,
            summary_url,
            summary_model,
            summary_key,
            summary_key_saved: false,
            editing_summary_key: false,
            summary_key_error: None,
            bundle_draft,
            add_category: "work_chat",
            exclusion_error: None,
            kind_error: None,
            _subs: subs,
            _poll: poll,
        };
        scenario::apply_view(&mut page, window, cx);
        page.refresh(cx);
        page
    }

    fn secret_present(cx: &App, name: &str) -> bool {
        matches!(cx.global::<Core>().services.secret(name), Ok(Some(_)))
    }

    /// `refreshSettingsState` and `model.refresh`: assigned only if it changed.
    pub(super) fn refresh(&mut self, cx: &mut Context<Self>) {
        let core_state = cx.global::<Core>();
        let permission = |p| map_perm(core_state.services.permission(p));
        let p = &core_state.prefs;
        let speech_model = core::speech_model(p);
        let mut next = Snapshot {
            speech_model,
            download_bytes: Some(core::speech_download_bytes(speech_model)),
            alternate: Some(core::Alternate::not_installed(core::other_speech_model(speech_model))),
            keep_model_ready: core::bool_pref(p, "keepModelReady"),
            microphone: permission(Permission::Microphone),
            input_monitoring: permission(Permission::InputMonitoring),
            accessibility: permission(Permission::Accessibility),
            system_audio: permission(Permission::SystemAudio),
            shortcut: Shortcut::load(p),
            storage_available: core_state.db.is_some(),
            ..Snapshot::default()
        };
        if let Some((completed, total, verifying)) = core_state.services.speech_install() {
            next.installing = true;
            next.completed = completed;
            next.total = total;
            next.verifying = verifying;
        }
        scenario::apply_snapshot(&self.scenario, &mut next);
        let pinned = core_state.services.secret(&core::remote_keychain("server-key")).ok().flatten().and_then(|k| core::base64url_decode(&k)).map(|k| core::fingerprint_of(&k));
        let rewrite = RewriteSettings::capture(p, |origin| Self::secret_present(cx, &core::rewrite_keychain(origin)));
        let saved = Self::secret_present(cx, &core::rewrite_keychain(core::SUMMARY_ACCOUNT));
        let changed = next != self.snapshot || pinned != self.pinned || rewrite != self.rewrite || saved != self.summary_key_saved;
        if changed {
            self.snapshot = next;
            self.pinned = pinned;
            self.rewrite = rewrite;
            self.summary_key_saved = saved;
            cx.notify();
        }
        self.follow_catalog(cx);
        self.follow_usage_binding(cx);
    }

    /// `prepareAutomaticEnrollment`, once per origin and device key: needs approval and a device key.
    /// ponytail: the store half; sending the reports is the usage service (SET-375).
    fn follow_usage_binding(&mut self, cx: &mut Context<Self>) {
        let core_state = cx.global::<Core>();
        let p = &core_state.prefs;
        if !p.bool_or("remote.enabled", false) || core::remote_state(p) != "approved" {
            self.usage_origin = None;
            return;
        }
        let origin = core::remote_server_url(p);
        if self.usage_origin.as_ref() == Some(&origin) {
            return;
        }
        let (Some(db), Ok(Some(key))) = (core_state.db.as_ref(), core_state.services.secret(&core::remote_keychain("device-key"))) else { return };
        let _ = core::prepare_automatic_enrollment(db, &origin, &core::usage_fingerprint(key.as_bytes()));
        self.usage_origin = Some(origin);
    }

    /// `MicrophonesViewModel.watch`: rebuilds from the catalog and reconciles the stored list.
    /// With no catalog the section stays hidden, as Swift's does until the catalog starts.
    /// ponytail: polls with `tick` every 500 ms, a CoreAudio property listener if that ever shows up in a profile.
    fn follow_catalog(&mut self, cx: &mut Context<Self>) {
        if matches!(self.scenario.as_str(), "microphones" | "voice-over") {
            return;
        }
        let Some(c) = cx.global::<Core>().services.input_catalog() else {
            return;
        };
        let inputs = c.devices.into_iter().map(|d| core::ConnectedInput { device_id: d.device_id, uid: d.uid, model_uid: d.model_uid, name: d.name, kind: d.kind.into(), alive: d.alive }).collect();
        let snapshot = InputSnapshot { inputs, default_input: c.default_input, clamshell: c.clamshell };
        if self.mics.as_ref().is_some_and(|m| m.snapshot == snapshot) {
            return;
        }
        let stored = core::load_inputs(prefs(cx));
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0., |d| d.as_secs_f64());
        let entries = core::reconcile_inputs(&stored, &snapshot, now);
        if core::inputs_meaningfully_changed(&stored, &entries) {
            core::save_inputs(prefs_mut(cx), entries.clone());
        }
        self.mics = Some(Mics { entries, snapshot });
        cx.notify();
    }

    fn tick(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let session = cx.try_global::<crate::shell::Session>();
        let visible = session.is_none_or(|s| s.selection == crate::pages::Page::Settings);
        if self.visible && !visible {
            self.left_page(window, cx);
        }
        self.visible = visible;
        if visible {
            self.refresh(cx);
            self.take_anchor(cx);
        }
    }

    /// `SettingsAnchor.microphones`: takes the router's request and scrolls there.
    /// ponytail: jumps; Swift animates with `PillStyle.morph`.
    pub(super) fn take_anchor(&mut self, cx: &mut Context<Self>) {
        if !cx.try_global::<crate::shell::Session>().is_some_and(|s| s.microphones_anchor) {
            return;
        }
        cx.global_mut::<crate::shell::Session>().microphones_anchor = false;
        if self.mics.is_some() {
            let y = self.mic_top.get() - self.scroll.bounds().top() - self.scroll.offset().y;
            self.scroll.set_offset(point(px(0.), -y));
            cx.notify();
        }
    }

    /// `onDisappear`: `closeRewriteSettings`, and the recorder stops.
    pub(super) fn left_page(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.hide_secret(window, cx);
        self.connection_revision += 1;
        self.connection_testing = false;
        self.connection = None;
        self.analysis = None;
        self.recording = false;
        cx.notify();
    }

    pub(super) fn scroll_handle(&self) -> &ScrollHandle {
        &self.scroll
    }

    // MARK: Actions

    /// `run`: ignored while performing; a failed action reads at the page bottom.
    pub(super) fn run(&mut self, action: &str, cx: &mut Context<Self>) {
        if self.performing {
            return;
        }
        self.performing = true;
        self.error = None;
        if cx.global::<Core>().services.settings_action(action).is_err() {
            self.error = Some(core::describe(&Failure::Other("flow_platform.Unavailable".into(), 0)));
        }
        self.performing = false;
        self.refresh(cx);
        cx.notify();
    }

    pub(super) fn set_bool(&mut self, key: &'static str, on: bool, cx: &mut Context<Self>) {
        prefs_mut(cx).set(key, on);
        self.refresh(cx);
        cx.notify();
    }

    /// Every picker writes through here, keyed by its element id.
    pub(super) fn apply_pick(&mut self, id: &str, value: &str, _window: &mut Window, cx: &mut Context<Self>) {
        let p = prefs_mut(cx);
        match id {
            "settings.appearance" => {
                p.set("appearance", value);
                let dark = match value {
                    "dark" => true,
                    "light" => false,
                    _ => matches!(cx.window_appearance(), WindowAppearance::Dark | WindowAppearance::VibrantDark),
                };
                let high_contrast = cx.global::<Core>().services.high_contrast();
                flow_ui::tokens::set_mode(Mode::new(dark, high_contrast), cx);
            }
            "settings.meetingLanguage" => p.set("settings.meetingLanguage", value),
            "settings.rewriteDefaultMode" => p.set("rewriteDefaultMode", value),
            "settings.summaryServer" => p.set("summaryServer", value),
            "settings.localModelIdleUnload" => p.set("localModelIdleUnload", value.parse::<i64>().unwrap_or(0)),
            "settings.serverOverride.dictation" | "settings.serverOverride.rewriting" | "settings.serverOverride.summaries" | "settings.serverOverride.meetings" => {
                let service = id.rsplit('.').next().unwrap_or_default();
                let key = if service == "rewriting" { "server.override.rewrite".to_string() } else { format!("server.override.{service}") };
                p.set(&key, value);
                if service == "summaries" && value == "custom" {
                    p.set("summaryServer", "remote");
                }
                self.check_result = None;
            }
            "context.addKind" => self.add_category = core::KINDS.iter().find(|k| k.0 == value).map_or("work_chat", |k| k.0),
            "context.running" => self.pick_running_app(value, _window, cx),
            _ => {
                if let Some(bundle) = id.strip_prefix("context.kind.") {
                    core::set_kind(p, bundle, Some(value));
                }
            }
        }
        self.refresh(cx);
        cx.notify();
    }

    // MARK: Shortcut

    pub(super) fn toggle_recording(&mut self, cx: &mut Context<Self>) {
        if self.recording {
            self.recording = false;
            cx.notify();
            return;
        }
        self.recording_error = None;
        match cx.global::<Core>().services.record_shortcut() {
            Ok(()) => self.recording = true,
            Err(_) => self.recording_error = Some(core::describe(&Failure::ShortcutUnavailable)),
        }
        cx.notify();
    }

    /// The recorder's completion: installs first, saves only if that worked.
    /// ponytail: unused until the Mac recorder (Feature 025) calls back.
    #[cfg_attr(not(test), allow(dead_code))]
    pub(super) fn recorded(&mut self, value: Option<Shortcut>, cx: &mut Context<Self>) {
        self.recording = false;
        if let Some(value) = value {
            self.error = None;
            let json = value.json();
            match cx.global::<Core>().services.install_shortcut(&json) {
                Ok(()) => value.save(prefs_mut(cx)),
                Err(_) => self.error = Some(core::describe(&Failure::ShortcutUnavailable)),
            }
        }
        self.refresh(cx);
        cx.notify();
    }

    /// Writes the purpose, saves Right Control if none is saved, then installs. Install failure
    /// goes to `setupStatus` in Swift, which this page doesn't show.
    pub(super) fn set_up_dictation(&mut self, cx: &mut Context<Self>) {
        let p = prefs_mut(cx);
        p.set("setup.purpose", "both");
        if !Shortcut::is_saved(p) {
            Shortcut::right_control().save(p);
        }
        let json = Shortcut::load(prefs(cx)).json();
        let _ = cx.global::<Core>().services.install_shortcut(&json);
        self.refresh(cx);
        cx.notify();
    }

    // MARK: Rewriting

    fn edit_endpoint(&mut self, text: String, window: &mut Window, cx: &mut Context<Self>) {
        let old = core::normalized_origin(&prefs(cx).string("rewriteEndpoint").unwrap_or_default());
        prefs_mut(cx).set("rewriteEndpoint", text.as_str());
        let new = core::normalized_origin(&text);
        if old != new {
            for origin in [old, new].into_iter().flatten() {
                core::set_insecure_override(prefs_mut(cx), &origin, false);
            }
            self.hide_secret(window, cx);
            self.credential_error = None;
            self.editing_credential = false;
        }
        self.invalidate_test();
        self.after_settings_change(cx);
    }

    fn invalidate_test(&mut self) {
        self.connection_revision += 1;
        self.connection_testing = false;
        self.connection = None;
        self.analysis = None;
    }

    /// Rewriting turns off once it is blocked.
    fn after_settings_change(&mut self, cx: &mut Context<Self>) {
        self.refresh(cx);
        if self.rewrite.blocked_reason().is_some() && prefs(cx).bool_or("rewriteEnabled", false) {
            prefs_mut(cx).set("rewriteEnabled", false);
        }
        cx.notify();
    }

    pub(super) fn set_rewrite_enabled(&mut self, on: bool, cx: &mut Context<Self>) {
        let allowed = on && self.rewrite.blocked_reason().is_none();
        self.set_bool("rewriteEnabled", allowed, cx);
    }

    pub(super) fn set_insecure(&mut self, on: bool, cx: &mut Context<Self>) {
        if self.rewrite.is_unencrypted_remote() {
            let origin = self.rewrite.origin.clone();
            core::set_insecure_override(prefs_mut(cx), &origin, on);
        }
        self.invalidate_test();
        self.after_settings_change(cx);
    }

    fn draft_input(&self) -> &Entity<InputState> {
        if self.credential_revealed { &self.credential_plain } else { &self.credential }
    }
    pub(super) fn credential_draft(&self, cx: &App) -> String {
        val(self.draft_input(), cx)
    }

    pub(super) fn hide_secret(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.credential_revealed = false;
        self.credential.update(cx, |s, cx| s.set_value("", window, cx));
        self.credential_plain.update(cx, |s, cx| s.set_value("", window, cx));
    }

    pub(super) fn save_credential(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let draft = self.credential_draft(cx);
        if draft.is_empty() || !self.rewrite.valid() {
            return;
        }
        if let Err(e) = core::validate_credential(&draft) {
            self.credential_error = Some(core::credential_message(Some(e)).into());
            cx.notify();
            return;
        }
        let name = core::rewrite_keychain(&self.rewrite.origin);
        match cx.global::<Core>().services.set_secret(&name, &draft) {
            Ok(()) => {
                self.credential_error = None;
                self.editing_credential = false;
                self.hide_secret(window, cx);
                self.invalidate_test();
            }
            Err(_) => self.credential_error = Some(core::credential_message(None).into()),
        }
        self.after_settings_change(cx);
    }

    pub(super) fn reveal_secret(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let name = core::rewrite_keychain(&self.rewrite.origin);
        match cx.global::<Core>().services.secret(&name) {
            Ok(Some(secret)) => {
                self.credential_plain.update(cx, |s, cx| s.set_value(secret, window, cx));
                self.credential_revealed = true;
                self.credential_error = None;
            }
            _ => self.credential_error = Some(core::credential_message(None).into()),
        }
        cx.notify();
    }

    pub(super) fn remove_secret(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let name = core::rewrite_keychain(&self.rewrite.origin);
        match cx.global::<Core>().services.remove_secret(&name) {
            Ok(()) => {
                self.credential_error = None;
                self.editing_credential = false;
                self.hide_secret(window, cx);
                self.invalidate_test();
            }
            Err(_) => self.credential_error = Some(core::credential_message(None).into()),
        }
        self.after_settings_change(cx);
    }

    pub(super) fn save_summary_key(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let draft = val(&self.summary_key, cx);
        if draft.is_empty() {
            return;
        }
        if let Err(e) = core::validate_credential(&draft) {
            self.summary_key_error = Some(core::credential_message(Some(e)).into());
            cx.notify();
            return;
        }
        match cx.global::<Core>().services.set_secret(&core::rewrite_keychain(core::SUMMARY_ACCOUNT), &draft) {
            Ok(()) => {
                self.summary_key_error = None;
                self.editing_summary_key = false;
                self.summary_key.update(cx, |s, cx| s.set_value("", window, cx));
            }
            Err(_) => self.summary_key_error = Some(core::credential_message(None).into()),
        }
        self.refresh(cx);
        cx.notify();
    }

    /// Preflight sends nothing. A stale answer is dropped by revision.
    pub(super) fn test_connection(&mut self, cx: &mut Context<Self>) {
        self.refresh(cx);
        self.invalidate_test();
        if let Some(blocked) = self.rewrite.preflight() {
            self.connection = Some((blocked, None, "preflight"));
            cx.notify();
            return;
        }
        let endpoint = self.rewrite.origin.clone();
        let secret = cx.global::<Core>().services.secret(&core::rewrite_keychain(&endpoint)).ok().flatten();
        self.connection_testing = true;
        let revision = self.connection_revision;
        cx.notify();
        cx.spawn(async move |this, cx| {
            let answer = cx
                .background_spawn(async move {
                    let health = core::rewrite_health(&endpoint, secret.as_deref());
                    let connected = health.as_ref().is_ok_and(|h| h.evaluate() == Connection::Connected);
                    let analysis = connected.then(|| core::analysis_status_text(&endpoint, secret.as_deref()));
                    (health, analysis)
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.connection_revision != revision {
                    return;
                }
                this.connection_testing = false;
                this.connection = Some(match answer.0 {
                    Ok(h) => (h.evaluate(), Some(h), "health_response"),
                    Err(c) => (c, None, "transport_error"),
                });
                this.analysis = answer.1;
                cx.notify();
            });
        })
        .detach();
    }

    // MARK: Permissions

    pub(super) fn allow(&mut self, permission: Permission, current: Perm, cx: &mut Context<Self>) {
        if self.performing {
            return;
        }
        self.error = None;
        let services = &cx.global::<Core>().services;
        let granted = current != Perm::Denied && matches!(services.request_permission(permission), Ok(flow_platform::PermissionState::Granted));
        if !granted && permission == Permission::Accessibility {
            // `requestAccessibilityPermission`: a best-effort reveal, so the user can add the app by hand.
            let _ = services.reveal_app();
        }
        if !granted && services.open_permission_settings(permission).is_err() {
            self.error = Some(core::describe(&Failure::Other("flow_platform.Unavailable".into(), 0)));
        }
        if permission == Permission::InputMonitoring && !core::meeting_only(prefs(cx)) {
            let json = Shortcut::load(prefs(cx)).json();
            let _ = cx.global::<Core>().services.install_shortcut(&json);
        }
        self.refresh(cx);
        let status = match (permission, granted) {
            (Permission::Microphone, true) => Some("Microphone allowed."),
            (Permission::Microphone, false) => Some("Microphone permission is needed for dictation."),
            (Permission::Accessibility, true) => Some("Accessibility allowed. Insertion is available in supported fields."),
            (Permission::Accessibility, false) => Some("Enable LocalFlow in Accessibility settings. The app is shown in Finder if you need to add it."),
            _ => None,
        };
        if let Some(status) = status {
            self.snapshot.status = status.into();
        }
        cx.notify();
    }

    // MARK: Microphones

    pub(super) fn edit_mics(&mut self, f: impl FnOnce(&[core::InputEntry]) -> Vec<core::InputEntry>, cx: &mut Context<Self>) {
        let Some(mics) = self.mics.as_mut() else { return };
        let next = core::validated_inputs(f(&mics.entries));
        mics.entries = next.clone();
        core::save_inputs(prefs_mut(cx), next);
        cx.notify();
    }
    /// The Move up and Move down accessibility actions, one step at a time.
    pub(super) fn move_mic(&mut self, id: &str, delta: isize, cx: &mut Context<Self>) {
        self.edit_mics(
            |entries| {
                let mut out = entries.to_vec();
                if let Some(i) = out.iter().position(|e| e.id == id) {
                    let to = i as isize + delta;
                    if to >= 0 && (to as usize) < out.len() {
                        out.swap(i, to as usize);
                    }
                }
                out
            },
            cx,
        );
    }

    // MARK: Sections

    fn section_title(title: &'static str) -> impl IntoElement {
        div().id(SharedString::from(format!("settings.section.{title}"))).test_support().pt(px(29.)).pb(px(13.)).child(div().id(SharedString::from(format!("settings.section.{title}.text"))).child(t(title).font(14., 500.)).test_support()).test_support()
    }

    fn general(&self, cx: &mut Context<Self>) -> Div {
        let meeting_only = core::meeting_only(prefs(cx));
        let first = if meeting_only {
            row(
                "Set up dictation",
                Some("Hold a key in any app to talk. Meetings stay as they are.".into()),
                prototype_button("settings.setUpDictation", "Set Up").min_width(99.).disabled(self.performing).on_click(cx.listener(|this, _, _, cx| this.set_up_dictation(cx))),
                cx,
            )
        } else {
            let title = if self.recording { "Listening…".to_string() } else { self.snapshot.shortcut.title() };
            row(
                "Shortcut",
                self.recording.then(|| "Press a shortcut, then release. Esc to cancel.".to_string()),
                prototype_button("settings.shortcut", title).min_width(99.).disabled(self.snapshot.busy || self.performing).on_click(cx.listener(|this, _, _, cx| this.toggle_recording(cx))),
                cx,
            )
        };
        let p = prefs(cx);
        let (appearance, learn, progress, language) = (core::appearance(p), core::bool_pref(p, "learnCorrections"), core::bool_pref(p, "showsBackgroundProgress"), core::meeting_language(p));
        group(cx)
            .child(first)
            .child(hairline(cx))
            .child(row("Appearance", None, picker("settings.appearance", "Appearance", 110., appearance, &[("System", "system"), ("Light", "light"), ("Dark", "dark")], false, cx), cx))
            .child(hairline(cx))
            .child(row("Learn corrections", None, switch("settings.learnCorrections", "Learn corrections", learn, false, cx.listener(|this, on: &bool, _, cx| this.set_bool("learnCorrections", *on, cx))), cx))
            .child(hairline(cx))
            .child(row("Show meeting progress", None, switch("settings.showsBackgroundProgress", "Show meeting progress", progress, false, cx.listener(|this, on: &bool, _, cx| this.set_bool("showsBackgroundProgress", *on, cx))), cx))
            .child(hairline(cx))
            .child(row("Meeting language", None, picker("settings.meetingLanguage", "Meeting language", 210., language, &[("Automatic (English/Slovak)", "automatic"), ("Slovak", "slovak"), ("English", "english")], false, cx), cx))
    }

    fn updates_section(&self, cx: &mut Context<Self>) -> Div {
        match self.updates {
            Updates::Manual | Updates::Failed => {
                let reason = if self.updates == Updates::Manual { "This build uses manual updates. Download the latest version from GitHub." } else { "The updater could not start. Reopen LocalFlow to retry." };
                let link = prototype_button("settings.updateDownloads", "View Downloads").on_click(cx.listener(|this, _, _, cx| {
                    if cx.global::<Core>().services.open_url(core::RELEASES_URL).is_err() {
                        this.error = Some(core::describe(&Failure::Other("flow_platform.Unavailable".into(), 0)));
                        cx.notify();
                    }
                }));
                group(cx).child(row("Software updates", Some(reason.into()), link, cx))
            }
            Updates::Sparkle { automatic, can_check } => group(cx)
                .child(row(
                    "Latest version",
                    Some("You choose when to install.".into()),
                    prototype_button("settings.checkForUpdates", "Check for Updates…").disabled(!can_check).on_click(cx.listener(|this, _, _, cx| {
                        if cx.global::<Core>().services.check_for_updates().is_err() {
                            this.error = Some(core::describe(&Failure::Other("flow_platform.Unavailable".into(), 0)));
                            cx.notify();
                        }
                    })),
                    cx,
                ))
                .child(hairline(cx))
                .child(row(
                    "Check automatically",
                    Some("Installation waits until active work finishes.".into()),
                    switch(
                        "settings.automaticUpdates",
                        "Check for updates automatically",
                        automatic,
                        false,
                        cx.listener(|this, _: &bool, _, cx| this.run("toggleAutomaticUpdates", cx)),
                    ),
                    cx,
                )),
        }
    }

    fn microphones(&self, mics: &Mics, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let list = core::mic_list(&mics.entries, &mics.snapshot);
        let muted = pal(cx).muted;
        let mut body = group(cx).id("settings.microphones.list");
        for r in list.rows {
            let id = r.id.clone();
            let drop_id = r.id.clone();
            let remove_id = r.id.clone();
            let remove = (!r.is_default).then(|| prototype_button("settings.microphones.remove", "Remove").on_click(cx.listener(move |this, _, _, cx| this.edit_mics(|e| e.iter().filter(|x| x.id != remove_id).cloned().collect(), cx))));
            // Kit has no custom accessibility actions, so VoiceOver users get them as real buttons.
            // ponytail: read when the page opens; Swift's actions need no switch at all.
            let move_button = |suffix: &str, verb: &'static str, delta: isize, show: bool, cx: &mut Context<Self>| {
                let (mic, label) = (id.clone(), r.a11y_label());
                (self.voice_over && show).then(|| prototype_button(SharedString::from(format!("settings.microphones.{suffix}.{mic}")), verb).a11y_label(format!("{verb}: {label}")).on_click(cx.listener(move |this, _, _, cx| this.move_mic(&mic, delta, cx))))
            };
            let (up, down) = (move_button("moveUp", "Move up", -1, r.rank > 1, cx), move_button("moveDown", "Move down", 1, r.rank < r.count, cx));
            let accent = pal(cx).accent;
            let drag = DragMic(id.clone());
            body = body
                .child(
                    div()
                        .id(SharedString::from(format!("settings.microphones.row.{id}")))
                        .test_support()
                        .when(!(r.available || r.is_default), |d| d.opacity(0.55))
                        .on_drag(drag, |d, _, _, cx| cx.new(|_| d.clone()))
                        .relative()
                        .on_drag_move::<DragMic>(cx.listener({
                            let id = id.clone();
                            move |this, e: &DragMoveEvent<DragMic>, _, cx| {
                                if e.bounds.contains(&e.event.position) && this.mic_drop.as_ref() != Some(&id) {
                                    this.mic_drop = Some(id.clone());
                                    cx.notify();
                                }
                            }
                        }))
                        .when(cx.has_active_drag() && self.mic_drop.as_ref() == Some(&id), |d| {
                            d.child(div().id("settings.microphones.dropBar").test_support().absolute().top_0().left_0().right_0().h(px(2.)).bg(accent))
                        })
                        .on_drop(cx.listener(move |this, d: &DragMic, _, cx| this.edit_mics(|e| core::move_input(e, &d.0, &drop_id), cx)))
                        .child(row(r.title(), Some(r.detail()), h_flex().gap(px(8.)).children(up).children(down).children(remove), cx)),
                )
                .child(hairline(cx));
        }
        let items: Vec<(String, String)> = list.add.iter().map(|i| (format!("{} · {}", i.name, core::kind_label(&i.kind)), i.uid.clone())).collect();
        let this = cx.entity().downgrade();
        // `Menu` with `PrototypeButtonStyle`: the tint pill, 13 medium, and no indicator.
        let pl = pal(cx);
        let unavailable = list.add_disabled.is_some();
        let add = Button::new("settings.microphones.add").custom(flow_ui::controls::ButtonCustomVariant::new(cx).color(pl.tint).foreground(pl.ink).hover(pl.tint).active(pl.button).shadow(false)).bg(pl.tint).accessibility_label("Add…").h_auto().px(px(12.)).py(px(7.)).rounded(px(8.)).border_0().child(t("Add…").font(13., 500.).a11y_hidden()).disabled(unavailable).when(unavailable, |b| b.opacity(0.45)).dropdown_menu(move |mut menu, _, _| {
            for (title, uid) in items.clone() {
                let this = this.clone();
                menu = menu.item(PopupMenuItem::new(title).on_click(move |_, _, cx| {
                    let uid = uid.clone();
                    let _ = this.update(cx, |this, cx| this.add_mic(&uid, cx));
                }));
            }
            menu
        });
        let top = self.mic_top.clone();
        vec![
            div().child(canvas(move |b, _, _| top.set(b.top()), |_, _, _, _| {}).w_full().h(px(0.))).child(Self::section_title("Microphones")).into_any_element(),
            div().id("settings.microphones.description").pb(px(12.)).child(t("LocalFlow records from the first microphone on this list that is connected.").size(12.).color(muted)).test_support().into_any_element(),
            body.child(row("Add microphone", list.add_disabled.map(String::from), add, cx)).test_support().into_any_element(),
        ]
    }

    pub(super) fn add_mic(&mut self, uid: &str, cx: &mut Context<Self>) {
        let Some(input) = self.mics.as_ref().and_then(|m| m.snapshot.inputs.iter().find(|i| i.uid == uid).cloned()) else { return };
        let id = format!("mic-{uid}");
        // `try?` in Swift: full, duplicate and invalid do nothing.
        self.edit_mics(|e| core::add_input(e, &input, id, 0.).unwrap_or_else(|_| e.to_vec()), cx);
    }

    fn context(&self, cx: &mut Context<Self>) -> Div {
        let p = prefs(cx);
        let (context_on, rewrite_on, stored_rewrite, style_on) = (core::bool_pref(p, "contextEnabled"), core::bool_pref(p, "rewriteEnabled"), core::bool_pref(p, "contextRewriteEnabled"), core::bool_pref(p, "contextStyleEnabled"));
        let blocked = core::context_rewrite_blocked(context_on, rewrite_on);
        let excluded = core::app_count(core::exclusions(p).len());
        let overrides = core::overrides(p).len();
        let kinds = if overrides == 0 { "Built in".to_string() } else { core::app_count(overrides) };
        group(cx)
            .child(row("Use app context", Some(core::CONTEXT_DISCLOSURE.into()), switch("settings.contextEnabled", "Use app context", context_on, false, cx.listener(|this, on: &bool, _, cx| this.set_bool("contextEnabled", *on, cx))), cx))
            .child(hairline(cx))
            .child(row(
                "Send context to rewrite server",
                Some(blocked.unwrap_or("Experimental").into()),
                switch("settings.contextRewriteEnabled", "Send context to rewrite server", blocked.is_none() && stored_rewrite, blocked.is_some(), cx.listener(|this, on: &bool, _, cx| this.set_bool("contextRewriteEnabled", *on, cx))),
                cx,
            ))
            .child(hairline(cx))
            .child(row("Match style to the app", Some("Experimental".into()), switch("settings.contextStyleEnabled", "Match style to the app", style_on, !context_on, cx.listener(|this, on: &bool, _, cx| this.set_bool("contextStyleEnabled", *on, cx))), cx))
            .child(hairline(cx))
            .child(row("Excluded apps", Some(excluded), prototype_button("settings.contextExclusions", "Edit…").on_click(cx.listener(|this, _, _, cx| this.open_modal(Modal::Context(ContextKind::Exclusions), cx))), cx))
            .child(hairline(cx))
            .child(row("App kinds", Some(kinds), prototype_button("settings.contextKinds", "Edit…").on_click(cx.listener(|this, _, _, cx| this.open_modal(Modal::Context(ContextKind::Kinds), cx))), cx))
    }

    fn rewrite_section(&self, window: &Window, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let pl = pal(cx);
        let served = core::routing(prefs(cx)).switch_applies();
        let enabled = core::bool_pref(prefs(cx), "rewriteEnabled");
        let blocked = self.rewrite.blocked_reason();
        let mode = core::rewrite_mode(prefs(cx));
        let timeout = core::rewrite_timeout(prefs(cx));
        let mut body = group(cx)
            .child(row(
                "Enable rewriting",
                blocked.map(String::from),
                div().id("settings.rewriteEnabled.tip").test_support().tooltip({
                    let note = core::bypass_note(&self.snapshot.shortcut);
                    move |w, cx| {
                        flow_ui::probe::note(note);
                        Tooltip::new(note).build(w, cx)
                    }
                }).child(switch("settings.rewriteEnabled", "Enable rewriting", enabled, blocked.is_some() && !enabled, cx.listener(|this, on: &bool, _, cx| this.set_rewrite_enabled(*on, cx)))),
                cx,
            ))
            .child(hairline(cx))
            .child(row(
                "Default mode",
                None,
                div().id("settings.rewriteDefaultMode.tip").test_support().tooltip(move |w, cx| {
                    flow_ui::probe::note(core::mode_definition(mode));
                    Tooltip::new(core::mode_definition(mode)).build(w, cx)
                }).child(picker(
                    "settings.rewriteDefaultMode",
                    "Default mode",
                    120.,
                    mode,
                    &[("Exact", "exact"), ("Clean", "clean"), ("Polished", "polished"), ("Concise", "concise")],
                    false,
                    cx,
                )),
                cx,
            ));
        if !served {
            body = body.child(hairline(cx)).children(self.rewrite_fields(window, cx));
        }
        let mut advanced = v_flex().w_full().child(disclosure("settings.rewriteAdvanced", "Advanced", self.rewrite_advanced, cx.listener(|this, _, _, cx| {
            this.rewrite_advanced = !this.rewrite_advanced;
            cx.notify();
        }), cx));
        if self.rewrite_advanced {
            advanced = advanced.child(row(
                "Timeout",
                None,
                stepper("settings.rewriteTimeout", "Rewrite timeout in seconds", format!("{timeout} seconds"), cx.listener(|_, _, _, cx| {
                    let v = core::rewrite_timeout(prefs(cx));
                    prefs_mut(cx).set("rewriteTimeoutSeconds", (v - 1).max(5));
                    cx.notify();
                }), cx.listener(|_, _, _, cx| {
                    let v = core::rewrite_timeout(prefs(cx));
                    prefs_mut(cx).set("rewriteTimeoutSeconds", (v + 1).min(60));
                    cx.notify();
                }), cx),
                cx,
            ));
            if let Some((Connection::Connected, Some(h), _)) = self.connection.as_ref().filter(|_| !served) {
                advanced = advanced.child(div().id("settings.rewriteIdentity").w_full().pb(px(12.)).child(selectable("settings.rewriteIdentity.text", h.identity_text(), 12., false, pl.muted, 15.)));
            }
            if let Some((c, _, code)) = self.connection.as_ref().filter(|_| cfg!(debug_assertions)) {
                advanced = advanced.child(disclosure("settings.rewriteDiagnostics", "Developer diagnostics", self.diagnostics_open, cx.listener(|this, _, _, cx| {
                    this.diagnostics_open = !this.diagnostics_open;
                    cx.notify();
                }), cx));
                if self.diagnostics_open {
                    advanced = advanced.child(div().py(px(8.)).child(selectable("settings.rewriteDiagnostics.text", format!("connection_test={} code={code}", c.category()), 11., true, pl.ink, 13.)));
                }
            }
        }
        body = body.child(hairline(cx)).child(div().id("settings.rewriteAdvancedRow").w_full().py(px(14.)).child(advanced).test_support());
        let warning = self.rewrite.warning().map(|w| div().id("settings.rewriteWarning").test_support().pb(px(12.)).child(t(w).size(12.).color(pl.warning)).into_any_element());
        let mut out = vec![Self::section_title("Rewriting").into_any_element()];
        out.extend(warning);
        out.push(body.into_any_element());
        out
    }

    /// The rewrite server's address, secret, override and test: in Rewriting, or in Server › Advanced.
    pub(super) fn rewrite_fields(&self, window: &Window, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let pl = pal(cx);
        let mut out = vec![
            v_flex()
                .w_full()
                .gap(px(8.))
                .pt(px(18.))
                .pb(px(14.))
                .child(t("Server URL").font(12., 500.).color(pl.muted))
                .child(input_surface("link", Some("http://127.0.0.1:8080"), Input::new(&self.endpoint).id("settings.rewriteEndpoint").aria_label("Rewrite server endpoint").accessibility_id("settings.rewriteEndpoint"), &self.endpoint, window, cx))
                .into_any_element(),
            self.credential_controls(window, cx).into_any_element(),
        ];
        if self.rewrite.is_unencrypted_remote() {
            let allowed = self.rewrite.insecure_override;
            out.push(hairline(cx).into_any_element());
            out.push(row("Allow unencrypted connection", None, switch("settings.rewriteInsecureOverride", "Allow unencrypted connection to this server (insecure)", allowed, false, cx.listener(|this, on: &bool, _, cx| this.set_insecure(*on, cx))), cx).into_any_element());
        }
        out.push(hairline(cx).into_any_element());
        out.push(
            row(
                "Connection",
                self.connection.as_ref().map(|c| c.0.status_text().to_string()),
                prototype_button("settings.rewriteTestConnection", if self.connection_testing { "Testing…" } else { "Test connection" }).disabled(self.connection_testing || !self.rewrite.valid()).on_click(cx.listener(|this, _, _, cx| this.test_connection(cx))),
                cx,
            )
            .into_any_element(),
        );
        if let Some(a) = &self.analysis {
            out.push(div().id("settings.analysisStatus").test_support().w_full().child(t(a.clone()).size(12.).color(pl.muted)).into_any_element());
        }
        out
    }

    fn credential_controls(&self, window: &Window, cx: &mut Context<Self>) -> Div {
        let pl = pal(cx);
        let present = self.rewrite.credential_present;
        let header = h_flex().id("settings.secretHeader").w_full().justify_between().child(t("Server secret").font(12., 500.).color(pl.muted)).when(present, |d| d.child(sf_label("checkmark.shield", "Saved in Keychain", 11., pl.muted))).test_support();
        let mut out = v_flex().w_full().gap(px(8.)).pb(px(18.)).child(header);
        if present && !self.editing_credential {
            out = out.child(h_flex().w_full().gap(px(8.)).child(div().flex_1().child(saved_secret("Server secret saved", cx))).child(prototype_button("settings.rewriteCredentialEdit", "Edit").a11y_label("Edit rewrite server credential").on_click(cx.listener(|this, _, _, cx| {
                this.editing_credential = true;
                cx.notify();
            }))));
        } else {
            let state = self.draft_input();
            let draft_empty = self.credential_draft(cx).is_empty();
            out = out.child(
                h_flex()
                    .id("settings.credentialRow")
                    .test_support()
                    .w_full()
                    .gap(px(8.))
                    .child(div().flex_1().child(input_surface("key", None, Input::new(state).id("settings.rewriteCredential").aria_label("Rewrite server credential").accessibility_id("settings.rewriteCredential"), state, window, cx)))
                    .child(prototype_button("settings.rewriteCredentialSave", "Save").a11y_label("Set rewrite server credential").disabled(draft_empty || !self.rewrite.valid()).on_click(cx.listener(|this, _, w, cx| this.save_credential(w, cx)))),
            );
            if present {
                let revealed = self.credential_revealed;
                out = out.child(
                    h_flex()
                        .w_full()
                        .gap(px(12.))
                        .child(plain_button("settings.rewriteCredentialReveal", if revealed { "Hide saved secret" } else { "Reveal saved secret" }).content(t(if revealed { "Hide saved secret" } else { "Reveal saved secret" }).size(12.).a11y_hidden()).a11y_label(if revealed { "Hide rewrite server credential" } else { "Reveal rewrite server credential" }).on_click(cx.listener(move |this, _, w, cx| {
                            if revealed {
                                this.hide_secret(w, cx);
                                cx.notify();
                            } else {
                                this.reveal_secret(w, cx);
                            }
                        })))
                        .child(div().flex_1())
                        .child(plain_button("settings.rewriteCredentialRemove", "Remove").content(t("Remove").size(12.).color(pl.warning).a11y_hidden()).a11y_label("Remove rewrite server credential").on_click(cx.listener(|this, _, w, cx| this.remove_secret(w, cx))))
                        .child(plain_button("settings.rewriteCredentialCancel", "Cancel").content(t("Cancel").size(12.).a11y_hidden()).on_click(cx.listener(|this, _, w, cx| {
                            this.hide_secret(w, cx);
                            this.editing_credential = false;
                            cx.notify();
                        }))),
                );
            }
        }
        if let Some(e) = &self.credential_error {
            out = out.child(t(e.clone()).size(12.).color(pl.warning));
        }
        out
    }

    fn summaries(&self, window: &Window, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let server = core::summary_server(prefs(cx));
        let mut body = group(cx).child(row("Server", None, picker("settings.summaryServer", "Server", 110., server, &[("Remote", "remote"), ("This Mac", "local")], false, cx), cx));
        if server == "remote" {
            body = body.child(hairline(cx)).child(self.summary_fields(window, cx));
        }
        vec![Self::section_title("Summaries").into_any_element(), body.into_any_element()]
    }

    /// In Summaries, or in Server › Advanced.
    pub(super) fn summary_fields(&self, window: &Window, cx: &mut Context<Self>) -> Div {
        let pl = pal(cx);
        let label = |s: &'static str| t(s).font(12., 500.).color(pl.muted);
        let mut out = v_flex()
            .w_full()
            .gap(px(14.))
            .py(px(18.))
            .child(label("Server URL"))
            .child(div().id("settings.summaryURLField").test_support().child(input_surface("link", Some("http://host:8000/v1"), Input::new(&self.summary_url).id("settings.summaryServerURL").aria_label("Server URL").accessibility_id("settings.summaryServerURL"), &self.summary_url, window, cx)))
            .child(div().id("settings.summaryModelLabel").child(label("Model")).test_support())
            .child(input_surface("cpu", None, Input::new(&self.summary_model).id("settings.summaryServerModel").aria_label("Model").accessibility_id("settings.summaryServerModel"), &self.summary_model, window, cx))
            .child(label("API key"));
        if self.summary_key_saved && !self.editing_summary_key {
            out = out.child(h_flex().w_full().gap(px(8.)).child(div().flex_1().child(saved_secret("API key saved", cx))).child(prototype_button("settings.summaryServerKeyEdit", "Edit").on_click(cx.listener(|this, _, _, cx| {
                this.editing_summary_key = true;
                cx.notify();
            }))));
        } else {
            let empty = val(&self.summary_key, cx).is_empty();
            out = out.child(
                h_flex()
                    .id("settings.summaryKeyRow")
                    .test_support()
                    .w_full()
                    .gap(px(8.))
                    .child(div().flex_1().child(input_surface("key", None, Input::new(&self.summary_key).id("settings.summaryServerKey").aria_label("API key").accessibility_id("settings.summaryServerKey"), &self.summary_key, window, cx)))
                    .child(prototype_button("settings.summaryServerKeySave", "Save").disabled(empty).on_click(cx.listener(|this, _, w, cx| this.save_summary_key(w, cx))))
                    .when(self.summary_key_saved, |d| {
                        d.child(prototype_button("settings.summaryServerKeyCancel", "Cancel").on_click(cx.listener(|this, _, w, cx| {
                            this.summary_key.update(cx, |s, cx| s.set_value("", w, cx));
                            this.editing_summary_key = false;
                            cx.notify();
                        })))
                    }),
            );
        }
        if let Some(e) = &self.summary_key_error {
            out = out.child(t(e.clone()).size(12.).color(pl.warning));
        }
        out
    }

    /// `permissionsSection`, public because onboarding shows it alone (SET-022).
    pub fn permissions_section(&self, cx: &mut Context<Self>) -> Div {
        let s = &self.snapshot;
        let rows: Vec<(&'static str, Permission, Perm)> = if core::meeting_only(prefs(cx)) {
            vec![("Microphone", Permission::Microphone, s.microphone)]
        } else {
            vec![("Microphone", Permission::Microphone, s.microphone), ("Input Monitoring", Permission::InputMonitoring, s.input_monitoring), ("Accessibility", Permission::Accessibility, s.accessibility)]
        };
        let missing: Vec<_> = rows.into_iter().filter(|r| r.2 != Perm::Granted).collect();
        if missing.is_empty() {
            return v_flex();
        }
        let mut body = group(cx);
        for (i, (name, permission, state)) in missing.into_iter().enumerate() {
            if i > 0 {
                body = body.child(hairline(cx));
            }
            let button = prototype_button(SharedString::from(format!("settings.allow.{name}")), "Allow…").min_width(99.).a11y_label(format!("Allow {name}")).disabled(self.performing).on_click(cx.listener(move |this, _, _, cx| this.allow(permission, state, cx)));
            body = body.child(row(name, None, button, cx));
        }
        v_flex().w_full().child(Self::section_title("Permissions needed")).child(body)
    }
}

impl Render for SettingsPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let pl = pal(cx);
        let compact = cx.global::<flow_ui::tokens::Flow>().compact;
        let routing = core::routing(prefs(cx));
        let mut column = v_flex()
            .child(div().id("settings.pageTitle").child(t("Settings").font(26., 500.).tracking(-0.4)).test_support())
            .child(Self::section_title("Server"))
            .child(self.server_section(window, cx))
            .child(Self::section_title("Updates"))
            .child(self.updates_section(cx))
            .child(Self::section_title("General"))
            .child(self.general(cx));
        if let Some(mics) = &self.mics {
            column = column.children(self.microphones(mics, cx));
        }
        column = column
            .child(Self::section_title("App context"))
            .child(self.context(cx))
            .child(Self::section_title("Models"))
            .child(self.models(cx))
            .children(self.rewrite_section(window, cx));
        if !routing.switch_applies() {
            column = column.children(self.summaries(window, cx));
        }
        column = column.child(self.permissions_section(cx));
        // Swift selects only the general error.
        if let Some(line) = &self.recording_error {
            column = column.child(div().id("settings.recordingError").pt(px(16.)).child(t(line.clone()).size(14.).color(pl.warning)).test_support());
        }
        if let Some(line) = &self.error {
            column = column.child(div().pt(px(16.)).child(selectable("settings.error", line.clone(), 14., false, pl.warning, 17.)));
        }
        let overlay = self.modal_overlay(window, cx);
        div()
            .id("settings")
            .track_focus(&self.focus)
            .relative()
            .size_full()
            .on_mouse_down(MouseButton::Left, cx.listener(|this, _, w, cx| w.focus(&this.focus, cx)))
            .on_key_down(cx.listener(|this, e: &KeyDownEvent, w, cx| this.key(&e.keystroke.key, w, cx)))
            .child(base::TextSelectionLayer)
            .child(
                div()
                    .id("settings.scroll")
                    .size_full()
                    .overflow_y_scroll()
                    .track_scroll(&self.scroll)
                    .flex()
                    .flex_col()
                    .items_center()
                    .text_color(pl.ink)
                    .text_size(px(14.))
                    .child(div().id("settings.content").w_full().max_w(px(960.)).px(px(if compact { 23. } else { 47. })).pt(px(if compact { 31. } else { 47. })).pb(px(64.)).flex_none().child(column).test_support()),
            )
            .children(overlay)
    }
}

// MARK: Parts

/// `settingsGroup`: padding 19, canvas, radius 12.
pub(super) fn group(cx: &App) -> Div {
    v_flex().w_full().px(px(19.)).bg(pal(cx).canvas).rounded(px(12.))
}

/// `SettingsRow`.
pub(super) fn row(title: impl Into<SharedString>, detail: Option<String>, control: impl IntoElement, cx: &App) -> impl IntoElement {
    let compact = cx.global::<flow_ui::tokens::Flow>().compact;
    let m = pal(cx).muted;
    let title: SharedString = title.into();
    let id = format!("settings.row.{title}");
    h_flex()
        .id(SharedString::from(id.clone()))
        .w_full()
        // `HStack(spacing:)` also spaces the `Spacer(minLength: 0)`, so text and control sit two spacings apart.
        .gap(px(if compact { 20. } else { 44. }))
        .py(px(19.))
        .child(v_flex().id(SharedString::from(format!("{id}.text"))).flex_1().min_w_0().gap(px(5.)).child(t(title).size(14.)).when_some(detail, |d, s| d.child(div().py(px(1.)).child(t(s).size(12.).color(m).line_spacing(4.).swift_lines()))).test_support())
        .child(div().flex_none().child(control))
        .test_support()
}

pub(super) fn switch(id: &'static str, label: &'static str, on: bool, disabled: bool, f: impl Fn(&bool, &mut Window, &mut App) + 'static) -> impl IntoElement {
    FlowSwitch::new(id).checked(on).disabled(disabled).accessibility_label(label).on_click(f)
}

/// A native `Picker`: fixed width, the value and two chevrons on a grey fill. The menu goes through
/// `apply_pick` with this element's id.
/// `PrototypeButtonStyle`: 7 + Figtree's 15 pt SwiftUI line + 7 is 29 pt. The Kit line is 16.
// ponytail: settings only; other pages have the same 30 pt button, move this into FlowButton at cutover.
pub(super) fn prototype_button(id: impl Into<ElementId>, label: impl Into<SharedString>) -> FlowButton {
    let label: SharedString = label.into();
    flow_ui::components::prototype_button(id, label.clone()).content(t(label).font(13., 500.).swift_lines().a11y_hidden())
}

pub(super) fn picker(id: impl Into<SharedString>, label: impl Into<SharedString>, width: f32, current: &str, options: &[(&'static str, &'static str)], disabled: bool, cx: &mut Context<SettingsPage>) -> AnyElement {
    let id: SharedString = id.into();
    let pl = pal(cx);
    let title = options.iter().find(|o| o.1 == current).map_or(current.to_string(), |o| o.0.to_string());
    let options: Vec<(&'static str, &'static str)> = options.to_vec();
    let current = current.to_string();
    let this = cx.entity().downgrade();
    let key = id.clone();
    let fill = pl.ink.opacity(if pl.mode.is_dark() { 0.14 } else { 0.2 });
    let chevrons = icon("chevron.up.chevron.down", 12., pl.ink);
    // A native picker hugs its longest option and centres in its frame: a zero-height stack of the
    // options sets the width. Plain strings so the render probe and VoiceOver don't read them.
    let sizer = v_flex().h_0().overflow_hidden().text_size(px(13.5)).pr(px(27.)).children(options.iter().map(|o| div().whitespace_nowrap().child(o.0)));
    let frame = format!("{id}.frame");
    let button = Button::new(ElementId::Name(id))
        .custom(flow_ui::controls::ButtonCustomVariant::new(cx).color(fill).foreground(pl.ink).hover(fill).active(fill).shadow(false))
        .bg(fill)
        .accessibility_label(label.into())
        .disabled(disabled)
        .when(disabled, |b| b.opacity(0.45))
        .h(px(24.))
        .max_w(px(width))
        .pl(px(12.))
        .pr(px(8.))
        .rounded(px(7.))
        .child(v_flex().child(h_flex().w_full().justify_between().child(t(title).size(13.5).lines(1).a11y_hidden()).child(chevrons)).child(sizer))
        .dropdown_menu(move |mut menu, _, _| {
            for (name, value) in options.clone() {
                let (this, key) = (this.clone(), key.clone());
                menu = menu.item(PopupMenuItem::new(name).checked(value == current).on_click(move |_, w, cx| {
                    let _ = this.update(cx, |this, cx| this.apply_pick(&key, value, w, cx));
                }));
            }
            menu
        });
    h_flex().id(SharedString::from(frame)).w(px(width)).justify_center().child(button).test_support().into_any_element()
}

/// `PillMenu`: the title and a chevron, as a menu.
pub(super) fn pill_menu(id: impl Into<SharedString>, title: String, options: Vec<(String, String)>, cx: &mut Context<SettingsPage>) -> AnyElement {
    let id: SharedString = id.into();
    let pl = pal(cx);
    let this = cx.entity().downgrade();
    let key = id.clone();
    Button::new(ElementId::Name(id))
        .custom(flow_ui::controls::ButtonCustomVariant::new(cx).color(pl.button).foreground(pl.ink).hover(pl.button).active(pl.button).shadow(false))
        .bg(pl.button)
        .accessibility_label(SharedString::from(title.clone()))
        .h_auto()
        .px(px(12.))
        .py(px(7.))
        .rounded(px(8.))
        .child(h_flex().gap(px(6.)).child(t(title).size(13.).a11y_hidden()).child(icon("chevron.down", 9., pl.muted)))
        .dropdown_menu(move |mut menu, _, _| {
            for (name, value) in options.clone() {
                let (this, key) = (this.clone(), key.clone());
                menu = menu.item(PopupMenuItem::new(name).on_click(move |_, w, cx| {
                    let _ = this.update(cx, |this, cx| this.apply_pick(&key, &value, w, cx));
                }));
            }
            menu
        })
    .into_any_element()
}

/// `Stepper`: the label, then NSStepper's 20x24 rounded cell. Kit has no stepper, so the halves are
/// two real buttons, `<id>.down` and `<id>.up`.
pub(super) fn stepper(id: &'static str, label: &'static str, value: String, down: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static, up: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static, cx: &App) -> AnyElement {
    let pl = pal(cx);
    let half = |suffix: &str, symbol: &'static str, verb: &str| plain_button(SharedString::from(format!("{id}.{suffix}")), suffix.to_string()).a11y_label(format!("{label}, {verb}")).content(div().w(px(STEPPER.0)).h(px(STEPPER.1 / 2.)).flex().items_center().justify_center().child(icon(symbol, 13., pl.ink)).into_any_element());
    h_flex()
        .gap(px(8.))
        .child(t(value).size(13.).mono_digits())
        .child(v_flex().id(SharedString::from(format!("{id}.cell"))).w(px(STEPPER.0)).h(px(STEPPER.1)).rounded(px(5.)).bg(pl.ink.opacity(if pl.mode.is_dark() { 0.14 } else { 0.08 })).child(half("up", "chevron.up", "increase").on_click(up)).child(half("down", "chevron.down", "decrease").on_click(down)).test_support())
        .into_any_element()
}
/// NSStepper's width and height as measured from the reference app, in points.
pub(super) const STEPPER: (f32, f32) = (20., 24.);

/// `.textSelection(.enabled)`: `SelectableText` paints and selects; the transparent `Txt` under it
/// keeps layout, the accessibility text and the render probe. `Txt` paints its own glyphs, so it
/// can't select by itself.
/// ponytail: one line of text only, which is all Settings selects today except identity and errors, whose overlay wraps at the same width.
pub(super) fn selectable(id: impl Into<SharedString>, text: impl Into<SharedString>, size: f32, mono: bool, color: Hsla, line: f32) -> impl IntoElement {
    let id: SharedString = id.into();
    let text: SharedString = text.into();
    let txt = t(text.clone()).size(size).color(flow_ui::gpui::transparent_black());
    div()
        .id(ElementId::Name(id.clone()))
        .relative()
        .w_full()
        .child(if mono { txt.mono() } else { txt })
        .child(
            div()
                .absolute()
                .inset_0()
                .text_size(px(size))
                .text_color(color)
                .font_family(if mono { flow_ui::txt::MONO } else { FIGTREE })
                .line_height(px(line))
                .child(base::SelectableText::new(ElementId::Name(format!("{id}.run").into()), text)),
        )
        .test_support()
}

/// `DisclosureGroup`.
pub(super) fn disclosure(id: &'static str, title: &'static str, open: bool, f: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static, cx: &App) -> AnyElement {
    let m = pal(cx).muted;
    h_flex().child(plain_button(id, title).content(h_flex().h(px(22.)).gap(px(2.)).child(icon(if open { "chevron.down" } else { "chevron.right" }, 10., m)).child(t(title).size(12.).color(m).a11y_hidden()).into_any_element()).on_click(f))
    .into_any_element()
}

/// `RewriteInputSurface`.
pub(super) fn input_surface(symbol: &'static str, link_hint: Option<&'static str>, input: Input, state: &Entity<InputState>, window: &Window, cx: &App) -> Div {
    let pl = pal(cx);
    let focused = state.read(cx).focus_handle(cx).is_focused(window);
    let empty = state.read(cx).value().is_empty();
    h_flex()
        .w_full()
        .min_h(px(40.))
        .px(px(12.))
        .gap(px(10.))
        .bg(pl.surface)
        .rounded(px(8.))
        .border(px(if focused { 2. } else { 1. }))
        .border_color(if focused { pl.accent } else { pl.line })
        .child(div().w(px(16.)).flex().justify_center().child(icon(symbol, 14., pl.muted)))
        .child(
            div()
                .flex_1()
                .min_w_0()
                .relative()
                .text_size(px(13.))
                .child(input.appearance(false).px_0())
                // Kit paints every placeholder in one theme colour, so a link-shaped one is drawn here.
                .when_some(link_hint.filter(|_| empty), |d, hint| d.child(h_flex().absolute().inset_0().child(t(hint).size(13.).lines(1).color(pl.link())))),
        )
}

fn saved_secret(label: &'static str, cx: &App) -> Div {
    let pl = pal(cx);
    h_flex()
        .w_full()
        .min_h(px(40.))
        .px(px(12.))
        .gap(px(10.))
        .bg(pl.surface)
        .rounded(px(8.))
        .border_1()
        .border_color(pl.line)
        .child(div().w(px(16.)).flex().justify_center().child(icon("key", 14., pl.muted)))
        .child(div().id(label).test_support().role(flow_ui::gpui::accesskit::Role::Label).aria_label(label).child(t("••••••••••••").size(13.).tracking(2.).a11y_hidden()))
}

/// Used by the model section: a runtime is `Ready`.
pub(super) fn is_loaded(s: &Snapshot) -> bool {
    s.runtime == Runtime::Ready
}
