//! The first-run flow: a port of `OnboardingCoordinator`, the readiness rules of
//! `SettingsViewModel.Snapshot`, the preference writes of `AppPreferences` and the local AI catalog.
use crate::db::Db;
use crate::prefs::Prefs;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::path::Path;

/// Synthetic rows for tests, the audit and the Swift reference app.
pub fn seed(_db: &Db) {}

pub const CURRENT_SETUP_VERSION: i64 = 1;
pub const REMOTE_CONSENT_VERSION: i64 = 2;
/// flowd's production port (`AppIdentity`).
pub const FLOWD_PORT: u16 = 8080;
pub const MTPLX_PORT: u16 = 8000;
/// whisper-large-v3-turbo.json plus speaker-diarization-offline.json.
pub const MEETING_BYTES: i64 = 1_647_039_790;
pub const SPEECH_FALLBACK_BYTES: i64 = 632_162_964;
const REMOTE_KEYS: [&str; 5] = ["remote.serverURL", "remote.state", "remote.consentVersion", "remote.fallbackThresholdMs", "remote.notice"];

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Step {
    Introduction,
    Purpose,
    Ai,
    AiDetails,
    Downloads,
    Permissions,
    Personalize,
    Test,
    Complete,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Purpose {
    Dictation,
    Meetings,
    Both,
}

impl Purpose {
    pub fn raw(self) -> &'static str {
        match self {
            Purpose::Dictation => "dictation",
            Purpose::Meetings => "meetings",
            Purpose::Both => "both",
        }
    }
    /// A missing or invalid value means `both`.
    pub fn stored(prefs: &Prefs) -> Purpose {
        match prefs.string("setup.purpose").as_deref() {
            Some("dictation") => Purpose::Dictation,
            Some("meetings") => Purpose::Meetings,
            _ => Purpose::Both,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum AiMode {
    Local,
    Remote,
    Off,
}

/// What a transition asks the composition root to do. Swift passes closures; the page drains these.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Effect {
    StartDownloads { local_ai: bool },
    StartMeetingModels,
    CancelMeetingModels,
    AbandonServer,
    OpenNotetaker,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub enum Perm {
    #[default]
    Unknown,
    Granted,
    Denied,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize, Default)]
pub enum ShortcutKind {
    #[default]
    #[serde(rename = "fn_globe")]
    FnGlobe,
    #[serde(rename = "key_combination")]
    KeyCombination,
    #[serde(rename = "modifier_only")]
    ModifierOnly,
}

const CONTROL: u32 = 0x1000;
const OPTION: u32 = 0x0800;
const SHIFT: u32 = 0x0200;
const COMMAND: u32 = 0x0100;
const FN: u32 = 1 << 23;
const SIDES: [(u64, u32, &str); 8] = [
    (0x01, CONTROL, "Left Control"),
    (0x2000, CONTROL, "Right Control"),
    (0x20, OPTION, "Left Option"),
    (0x40, OPTION, "Right Option"),
    (0x02, SHIFT, "Left Shift"),
    (0x04, SHIFT, "Right Shift"),
    (0x08, COMMAND, "Left Command"),
    (0x10, COMMAND, "Right Command"),
];

/// `ShortcutPreference`, in the JSON shape Swift's encoder writes.
#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Shortcut {
    pub version: u32,
    pub kind: ShortcutKind,
    pub enabled: bool,
    pub key_code: u32,
    pub modifiers: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_modifiers: Option<u64>,
}

impl Default for Shortcut {
    fn default() -> Self {
        Shortcut { version: 1, kind: ShortcutKind::FnGlobe, enabled: true, key_code: 49, modifiers: CONTROL | OPTION, device_modifiers: None }
    }
}

impl Shortcut {
    pub fn right_control() -> Self {
        Shortcut { kind: ShortcutKind::ModifierOnly, modifiers: CONTROL, device_modifiers: Some(0x2000), ..Default::default() }
    }
    pub fn right_option() -> Self {
        Shortcut { kind: ShortcutKind::ModifierOnly, modifiers: OPTION, device_modifiers: Some(0x40), ..Default::default() }
    }
    pub fn fn_globe() -> Self {
        Shortcut::default()
    }
    /// A missing or undecodable value is fn / Globe, as `ShortcutPreference.load()` returns.
    pub fn load(prefs: &Prefs) -> Self {
        prefs.get("shortcut").unwrap_or_default()
    }
    pub fn is_saved(prefs: &Prefs) -> bool {
        prefs.contains("shortcut")
    }
    pub fn save(&self, prefs: &mut Prefs) {
        prefs.set("shortcut", self);
    }
    /// `ShortcutPreference.isValid`.
    pub fn is_valid(&self) -> bool {
        let device_mask = SIDES.iter().fold(0, |all, side| all | side.0);
        if let Some(device) = self.device_modifiers {
            if device == 0 || device & !device_mask != 0 || self.kind == ShortcutKind::FnGlobe {
                return false;
            }
            if !SIDES.iter().all(|(mask, modifier, _)| device & mask == 0 || self.modifiers & modifier != 0) {
                return false;
            }
        }
        if self.version != 1 || self.modifiers & !(CONTROL | OPTION | SHIFT | COMMAND | FN) != 0 {
            return false;
        }
        match self.kind {
            ShortcutKind::FnGlobe => true,
            ShortcutKind::ModifierOnly => self.modifiers != 0,
            ShortcutKind::KeyCombination => self.key_code < 128 && !(54..=63).contains(&self.key_code) && !(self.key_code == 53 && self.modifiers == 0),
        }
    }
    pub fn parse(json: &str) -> Option<Shortcut> {
        serde_json::from_str(json).ok()
    }
    pub fn json(&self) -> String {
        serde_json::to_string(self).expect("shortcut serializes")
    }
    pub fn title(&self) -> String {
        if !self.enabled {
            return "Disabled".into();
        }
        if self.kind == ShortcutKind::FnGlobe {
            return "fn / Globe".into();
        }
        let mut parts: Vec<String> = vec![];
        for (modifier, symbol) in [(CONTROL, "⌃"), (OPTION, "⌥"), (SHIFT, "⇧"), (COMMAND, "⌘")] {
            if self.modifiers & modifier == 0 {
                continue;
            }
            let names: Vec<String> =
                SIDES.iter().filter(|(mask, m, _)| *m == modifier && self.device_modifiers.unwrap_or(0) & mask != 0).map(|(_, _, n)| n.to_string()).collect();
            if names.is_empty() {
                parts.push(symbol.into());
            } else {
                parts.extend(names);
            }
        }
        if self.modifiers & FN != 0 {
            parts.push("fn".into());
        }
        if self.kind == ShortcutKind::KeyCombination {
            parts.push(key_title(self.key_code));
        }
        parts.join(" ")
    }
}

// ponytail: letter keys need the keyboard layout (Swift uses UCKeyTranslate); they come with the
// shortcut service in Feature 025 and read "Key N" until then.
fn key_title(code: u32) -> String {
    let special = [
        (36, "Return"), (48, "Tab"), (49, "Space"), (51, "⌫"), (53, "Esc"), (65, "."), (67, "*"), (69, "+"), (71, "Clear"), (75, "/"), (76, "Enter"),
        (78, "−"), (81, "="), (82, "0"), (83, "1"), (84, "2"), (85, "3"), (86, "4"), (87, "5"), (88, "6"), (89, "7"), (91, "8"), (92, "9"),
        (114, "Help"), (115, "Home"), (116, "Page Up"), (117, "⌦"), (119, "End"), (121, "Page Down"), (123, "←"), (124, "→"), (125, "↓"), (126, "↑"),
    ];
    if let Some((_, t)) = special.iter().find(|(c, _)| *c == code) {
        return t.to_string();
    }
    let functions = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90];
    if let Some(i) = functions.iter().position(|c| *c == code) {
        return format!("F{}", i + 1);
    }
    format!("Key {code}")
}

/// One event the recorder's tap saw, as `ShortcutCaptureState.receive` takes it.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum KeyEvent {
    KeyDown,
    KeyUp,
    FlagsChanged,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Capture {
    Pending,
    Cancelled,
    Captured(Shortcut),
}

/// `ShortcutCaptureState`: one chord only. Commits after the key and modifiers release.
#[derive(Default)]
pub struct ShortcutCapture {
    candidate: Option<Shortcut>,
    key_released: bool,
    finished: bool,
}

impl ShortcutCapture {
    /// `modifiers` is the Carbon-style mask of `flags`; `physical` the side-specific device mask.
    pub fn receive(&mut self, event: KeyEvent, key_code: u32, modifiers: u32, physical: Option<u64>) -> Capture {
        if self.finished {
            return Capture::Pending;
        }
        if event == KeyEvent::KeyDown && key_code == 53 {
            self.finished = true;
            return Capture::Cancelled;
        }
        let is_combo = self.candidate.as_ref().is_some_and(|c| c.kind == ShortcutKind::KeyCombination);
        match event {
            KeyEvent::KeyDown if !is_combo => {
                self.candidate = Some(Shortcut { kind: ShortcutKind::KeyCombination, key_code, modifiers, device_modifiers: physical, ..Default::default() });
            }
            KeyEvent::FlagsChanged if !is_combo && modifiers != 0 => {
                let mut value = self.candidate.take().unwrap_or(Shortcut { kind: ShortcutKind::ModifierOnly, modifiers: 0, ..Default::default() });
                value.modifiers |= modifiers;
                if let Some(mask) = physical {
                    value.device_modifiers = Some(value.device_modifiers.unwrap_or(0) | mask);
                }
                self.candidate = Some(value);
            }
            KeyEvent::KeyUp if self.candidate.as_ref().is_some_and(|c| c.key_code == key_code) => self.key_released = true,
            _ => {}
        }
        let Some(mut value) = self.candidate.clone() else { return Capture::Pending };
        if modifiers != 0 || !(value.kind == ShortcutKind::ModifierOnly || self.key_released) {
            return Capture::Pending;
        }
        if value.kind == ShortcutKind::ModifierOnly && value.modifiers == FN {
            value.kind = ShortcutKind::FnGlobe;
        }
        if !value.is_valid() {
            return Capture::Pending;
        }
        self.finished = true;
        Capture::Captured(value)
    }
}

/// `SettingsViewModel.Snapshot`: what the gates read.
#[derive(Clone, Debug, PartialEq)]
pub struct Snapshot {
    pub model_installed: bool,
    pub model_install_error: Option<String>,
    pub speaker_model_installed: bool,
    pub speaker_model_installing: bool,
    pub meeting_model_installed: bool,
    pub meeting_model_installing: bool,
    pub meeting_models_error: Option<String>,
    pub meeting_progress: (i64, i64),
    pub speech_model: String,
    pub download_bytes: Option<i64>,
    pub progress: (i64, i64),
    pub verifying: bool,
    pub microphone: Perm,
    pub input_monitoring: Perm,
    pub accessibility: Perm,
    pub system_audio: Perm,
    pub shortcut: Shortcut,
    pub shortcut_ready: bool,
    pub storage_available: bool,
    pub busy: bool,
    pub installing: bool,
    pub runtime_leased: bool,
    pub controls_available: bool,
}

impl Default for Snapshot {
    fn default() -> Self {
        Snapshot {
            model_installed: false,
            model_install_error: None,
            speaker_model_installed: false,
            speaker_model_installing: false,
            meeting_model_installed: false,
            meeting_model_installing: false,
            meeting_models_error: None,
            meeting_progress: (0, 0),
            speech_model: "Parakeet Ultra".into(),
            download_bytes: None,
            progress: (0, 0),
            verifying: false,
            microphone: Perm::Unknown,
            input_monitoring: Perm::Unknown,
            accessibility: Perm::Unknown,
            system_audio: Perm::Unknown,
            shortcut: Shortcut::default(),
            shortcut_ready: false,
            storage_available: false,
            busy: false,
            installing: false,
            runtime_leased: false,
            controls_available: true,
        }
    }
}

impl Snapshot {
    pub fn has_missing_permissions(&self) -> bool {
        self.microphone != Perm::Granted || self.input_monitoring != Perm::Granted || self.accessibility != Perm::Granted
    }
    pub fn ready_for_meetings(&self) -> bool {
        self.storage_available && self.microphone == Perm::Granted
    }
    pub fn meeting_blocked_reason(&self) -> Option<&'static str> {
        if self.microphone != Perm::Granted {
            return Some("Allow Microphone access to record.");
        }
        if !self.storage_available {
            return Some("Local storage is not ready. Check Settings before recording.");
        }
        None
    }
    pub fn meeting_models_ready(&self) -> bool {
        self.model_installed && self.speaker_model_installed && self.meeting_model_installed
    }
    pub fn meeting_pack_installed(&self) -> bool {
        self.meeting_model_installed && self.speaker_model_installed
    }
    pub fn ready_for_test(&self) -> bool {
        self.storage_available
            && self.model_installed
            && self.microphone == Perm::Granted
            && self.input_monitoring == Perm::Granted
            && self.shortcut_ready
            && self.shortcut.enabled
            && !self.busy
            && !self.installing
            && !self.runtime_leased
            && self.controls_available
    }
    pub fn test_blocked_reason(&self) -> Option<String> {
        if !self.model_installed {
            return Some(self.model_install_error.clone().unwrap_or_else(|| "Finish downloading speech recognition first.".into()));
        }
        let reason = if self.microphone != Perm::Granted {
            "Allow Microphone access to record."
        } else if self.input_monitoring != Perm::Granted {
            "Allow Input Monitoring to use the shortcut."
        } else if !self.shortcut.enabled {
            "Enable a dictation shortcut."
        } else if !self.shortcut_ready {
            if self.shortcut.kind == ShortcutKind::KeyCombination && self.accessibility != Perm::Granted {
                "Allow Accessibility for this shortcut, or choose a modifier key."
            } else {
                "Starting the dictation shortcut…"
            }
        } else if self.installing || !self.controls_available {
            "Wait for the model operation to finish."
        } else if self.busy {
            "Wait for the current dictation to finish."
        } else if !self.storage_available {
            "Local storage is not ready. Check Settings before recording."
        } else {
            return None;
        };
        Some(reason.into())
    }
}

/// `OnboardingCoordinator`. Nothing but the listed preferences persists, so a relaunch starts
/// over at the introduction with `aiMode == .local`.
#[derive(Debug)]
pub struct Setup {
    pub step: Step,
    pub purpose: Purpose,
    pub ai_mode: AiMode,
    pub meetings_requested: bool,
    pub test_armed: bool,
    pub test_succeeded: bool,
    pub preparing_test: bool,
    pub test_error: Option<String>,
    pub effects: Vec<Effect>,
    armed_session: Option<u64>,
    server_purpose: Option<Purpose>,
    meetings_automatic: bool,
    downloads_started: bool,
}

impl Setup {
    pub fn new(prefs: &Prefs) -> Self {
        Setup {
            step: Step::Introduction,
            purpose: Purpose::stored(prefs),
            ai_mode: AiMode::Local,
            meetings_requested: false,
            test_armed: false,
            test_succeeded: false,
            preparing_test: false,
            test_error: None,
            effects: vec![],
            armed_session: None,
            server_purpose: None,
            meetings_automatic: false,
            downloads_started: false,
        }
    }

    /// A quit mid-setup: what a meeting path stored doesn't count as a finished setup.
    pub fn resume_unfinished(&mut self, prefs: &mut Prefs) {
        if is_complete(prefs) || Purpose::stored(prefs) != Purpose::Meetings {
            return;
        }
        if prefs.bool_or("server.only", false) || prefs.bool_or("remote.enabled", false) {
            self.abandon_server_choice(prefs);
        }
        prefs.set("setup.purpose", Purpose::Both.raw());
        self.purpose = Purpose::Both;
    }

    fn abandon_server_choice(&mut self, prefs: &mut Prefs) {
        self.server_purpose = None;
        undo_server_choice(prefs);
        self.effects.push(Effect::AbandonServer);
    }

    fn abandon_if_changed(&mut self, prefs: &mut Prefs) {
        if let Some(chosen) = self.server_purpose
            && (chosen != self.purpose || self.ai_mode != AiMode::Remote)
        {
            self.abandon_server_choice(prefs);
        }
    }

    /// `Downloads` was reached once: the point where Swift's `beginSetupDownloads` runs.
    pub fn downloads_begun(&self) -> bool {
        self.downloads_started
    }

    pub fn path(&self) -> Vec<Step> {
        let mut steps = vec![Step::Introduction, Step::Purpose, Step::Ai];
        if self.ai_mode != AiMode::Off {
            steps.push(Step::AiDetails);
        }
        if !self.meetings_on_server() {
            steps.push(Step::Downloads);
        }
        steps.extend([Step::Permissions, Step::Personalize]);
        if self.purpose != Purpose::Meetings {
            steps.push(Step::Test);
        }
        steps
    }

    fn meetings_on_server(&self) -> bool {
        self.purpose == Purpose::Meetings && self.ai_mode == AiMode::Remote
    }

    fn ready(&self, s: &Snapshot) -> bool {
        if self.purpose == Purpose::Meetings { s.ready_for_meetings() } else { s.ready_for_test() }
    }

    pub fn downloads_ready(&self, s: &Snapshot) -> bool {
        if self.purpose == Purpose::Meetings { s.meeting_models_ready() } else { s.model_installed }
    }

    pub fn advance(&mut self, s: &Snapshot, prefs: &mut Prefs) {
        match self.step {
            Step::Introduction => self.step = Step::Purpose,
            Step::Purpose => {
                prefs.set("setup.purpose", self.purpose.raw());
                self.abandon_if_changed(prefs);
                self.step = Step::Ai;
            }
            Step::Ai => {
                self.abandon_if_changed(prefs);
                if self.ai_mode == AiMode::Remote {
                    self.server_purpose = Some(self.purpose);
                }
                if self.ai_mode == AiMode::Off {
                    self.begin_downloads();
                } else {
                    self.step = Step::AiDetails;
                }
            }
            Step::AiDetails => {
                if self.meetings_on_server() {
                    self.withdraw_automatic();
                    prefs.set("server.only", true);
                    self.step = Step::Permissions;
                } else {
                    self.begin_downloads();
                }
            }
            Step::Downloads => {
                if self.downloads_ready(s) {
                    self.step = Step::Permissions;
                }
            }
            Step::Permissions => {
                if self.ready(s) {
                    self.step = Step::Personalize;
                }
            }
            Step::Personalize => {
                if self.ready(s) {
                    if self.purpose == Purpose::Meetings {
                        self.finish(s, prefs);
                    } else {
                        self.step = Step::Test;
                    }
                }
            }
            Step::Test => {
                if self.test_succeeded {
                    self.finish(s, prefs);
                }
            }
            Step::Complete => {}
        }
    }

    pub fn skip_ai(&mut self, prefs: &mut Prefs) {
        if self.step != Step::Ai {
            return;
        }
        self.ai_mode = AiMode::Off;
        self.abandon_if_changed(prefs);
        self.begin_downloads();
    }

    fn begin_downloads(&mut self) {
        self.step = Step::Downloads;
        self.downloads_started = true;
        self.effects.push(Effect::StartDownloads { local_ai: self.ai_mode == AiMode::Local });
        if self.purpose == Purpose::Dictation || self.ai_mode == AiMode::Remote {
            self.withdraw_automatic();
            return;
        }
        if !self.meetings_requested {
            self.meetings_automatic = true;
        }
        self.download_meeting_models();
    }

    fn withdraw_automatic(&mut self) {
        if !self.meetings_automatic {
            return;
        }
        self.meetings_automatic = false;
        self.meetings_requested = false;
        self.effects.push(Effect::CancelMeetingModels);
    }

    pub fn download_meeting_models(&mut self) {
        if self.step != Step::Downloads || self.meetings_requested {
            return;
        }
        self.meetings_requested = true;
        self.effects.push(Effect::StartMeetingModels);
    }

    pub fn retry_meeting_models(&mut self) {
        if self.step != Step::Downloads {
            return;
        }
        self.meetings_requested = false;
        self.download_meeting_models();
    }

    pub fn back(&mut self) {
        let path = self.path();
        let Some(i) = path.iter().position(|s| *s == self.step).filter(|i| *i > 0) else { return };
        self.test_armed = false;
        self.test_error = None;
        self.armed_session = None;
        self.step = path[i - 1];
    }

    /// `armTest`'s first half: true when the caller should prepare the speech model.
    pub fn begin_arming(&mut self, s: &Snapshot) -> bool {
        if self.step != Step::Test || self.preparing_test || self.test_armed || !s.ready_for_test() {
            return false;
        }
        self.preparing_test = true;
        self.test_error = None;
        true
    }

    /// `armTest`'s second half. `prepared` carries the failure text.
    pub fn finish_arming(&mut self, prepared: Result<(), String>, s: &Snapshot) {
        self.preparing_test = false;
        match prepared {
            Ok(()) => self.start_test(s),
            Err(e) if self.step == Step::Test => self.test_error = Some(e),
            Err(_) => {}
        }
    }

    pub fn start_test(&mut self, s: &Snapshot) {
        if self.step != Step::Test || !s.ready_for_test() {
            return;
        }
        self.test_succeeded = false;
        self.test_error = None;
        self.armed_session = None;
        self.test_armed = true;
    }

    /// Only a session admitted after arming may provide test evidence.
    pub fn dictation_started(&mut self, id: u64) {
        if self.step == Step::Test && self.test_armed {
            self.armed_session = Some(id);
        }
    }

    /// Call only after a new nonempty dictation is durably saved.
    pub fn record_successful_dictation(&mut self, id: u64) {
        if self.step == Step::Test && self.test_armed && self.armed_session == Some(id) {
            self.test_armed = false;
            self.test_succeeded = true;
        }
    }

    pub fn dictation_ended(&mut self, id: u64, message: &str) {
        if self.step == Step::Test && self.test_armed && self.armed_session == Some(id) {
            self.test_armed = false;
            self.armed_session = None;
            self.test_error = Some(message.into());
        }
    }

    pub fn skip_test(&mut self, s: &Snapshot, prefs: &mut Prefs) {
        if self.step == Step::Test {
            self.finish(s, prefs);
        }
    }

    fn finish(&mut self, _s: &Snapshot, prefs: &mut Prefs) {
        self.test_armed = false;
        self.armed_session = None;
        self.test_error = None;
        complete_onboarding(prefs);
        self.step = Step::Complete;
        if self.purpose == Purpose::Meetings {
            self.effects.push(Effect::OpenNotetaker);
        }
    }
}

pub fn is_complete(prefs: &Prefs) -> bool {
    prefs.int_or("setupVersion", 0) >= CURRENT_SETUP_VERSION
}

/// The stored raw value, else `parakeet-ultra` on a first run and `parakeet-v3` otherwise.
pub fn speech_model_raw(prefs: &Prefs) -> String {
    prefs.string("speechModel").unwrap_or_else(|| if prefs.int_or("setupVersion", 0) == 0 { "parakeet-ultra" } else { "parakeet-v3" }.into())
}

pub fn speech_model_name(raw: &str) -> &'static str {
    if raw == "parakeet-ultra" { "Parakeet Ultra" } else { "Parakeet v3" }
}

/// `completeOnboarding()`: the speech model first, then the gate that swaps the window.
pub fn complete_onboarding(prefs: &mut Prefs) {
    prefs.set("speechModel", speech_model_raw(prefs));
    prefs.set("setupVersion", CURRENT_SETUP_VERSION);
}

pub fn undo_server_choice(prefs: &mut Prefs) {
    prefs.set("server.only", false);
    prefs.remove("server.useForEverything");
    prefs.set("rewriteEnabled", false);
}

/// Every `remote.*` value goes except `remote.enabled = false`.
pub fn reset_remote(prefs: &mut Prefs) {
    prefs.set("remote.enabled", false);
    for key in REMOTE_KEYS {
        prefs.remove(key);
    }
    prefs.remove("server.capabilities");
}

pub fn remote_on(prefs: &Prefs) -> bool {
    prefs.bool_or("remote.enabled", false)
}

pub fn remote_state(prefs: &Prefs) -> String {
    prefs.string("remote.state").unwrap_or_else(|| "off".into())
}

/// Signed in to the server: approved, or waiting for the administrator.
pub fn enrolled(prefs: &Prefs) -> bool {
    remote_on(prefs) && matches!(remote_state(prefs).as_str(), "approved" | "pending")
}

/// The rewrite-only server serves no meetings.
pub fn server_ready(prefs: &Prefs, purpose: Purpose, legacy_connected: bool) -> bool {
    enrolled(prefs) || (purpose != Purpose::Meetings && legacy_connected)
}

/// `RemoteDictationModel.statusText`, identity present or not.
pub fn remote_status(prefs: &Prefs, has_identity: bool) -> Option<&'static str> {
    if !remote_on(prefs) {
        return None;
    }
    let notice = prefs.string("remote.notice");
    if notice.as_deref() == Some("update_required") {
        return Some("Update LocalFlow or the server");
    }
    Some(match remote_state(prefs).as_str() {
        "pinned" if notice.as_deref() == Some("sign_in_again") => "Sign in again",
        "pinned" => "Sign in to finish",
        "pending" => "Waiting for approval",
        "approved" => "Approved",
        "rejected" => "Rejected",
        "revoked" => "Removed from the server",
        "pin_mismatch" => "Server identity changed",
        _ if has_identity => "Compare the fingerprint",
        _ => "Checking the server…",
    })
}

pub fn remote_privacy(prefs: &Prefs) -> String {
    let retention = "Meetings handed off to the server stay there until merged, at most 7 days.";
    let meeting_only = Purpose::stored(prefs) == Purpose::Meetings;
    if !remote_on(prefs) {
        return format!("Nothing leaves this Mac until you confirm what is sent and the administrator approves this Mac. {retention}");
    }
    let lead = match (remote_state(prefs).as_str(), meeting_only) {
        ("approved", true) => "Approved. Meeting audio, transcripts and summaries will use this server. Recordings wait on this Mac when the server can't be reached.",
        ("approved", false) => "Approved. Dictation, rewriting, summaries and meetings will use this server. Speech recognition on this Mac takes over when the server can't be reached.",
        ("pending", true) => "Waiting for approval. You can continue: until the administrator approves this Mac, nothing is sent and recordings wait here.",
        ("pending", false) => "Waiting for approval. You can continue: until the administrator approves this Mac, nothing is sent and dictation is transcribed here.",
        _ => "Nothing is sent until the administrator approves this Mac.",
    };
    format!("{lead} {retention}")
}

fn split_authority(rest: &str) -> Option<(&str, &str)> {
    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    Some((&rest[..end], &rest[end..]))
}

fn split_host_port(authority: &str) -> Option<(String, Option<u32>)> {
    let (host, port) = if let Some(rest) = authority.strip_prefix('[') {
        let close = rest.find(']')?;
        let tail = &rest[close + 1..];
        let port = match tail.strip_prefix(':') {
            Some(p) => Some(p),
            None if tail.is_empty() => None,
            None => return None,
        };
        (format!("[{}]", &rest[..close]), port)
    } else {
        match authority.rsplit_once(':') {
            Some((h, p)) => (h.to_string(), Some(p)),
            None => (authority.to_string(), None),
        }
    };
    let port = match port {
        Some(p) => Some(p.parse::<u32>().ok()?),
        None => None,
    };
    Some((host.to_lowercase(), port))
}

/// `RemoteDictationSettings.origin`: an `https://` origin with no path, query, fragment or
/// credentials. Lowercases the host and keeps the port.
pub fn remote_origin(text: &str) -> Option<String> {
    let trimmed = text.trim();
    if trimmed.chars().any(|c| c.is_whitespace()) {
        return None;
    }
    let (authority, tail) = split_authority(trimmed.strip_prefix("https://")?)?;
    if !(tail.is_empty() || tail == "/") || authority.contains('@') {
        return None;
    }
    let (host, port) = split_host_port(authority)?;
    if host.is_empty() {
        return None;
    }
    Some(match port {
        Some(p) => format!("https://{host}:{p}"),
        None => format!("https://{host}"),
    })
}

/// The host of a stored URL, or the text itself (`OnboardingView.serverHost`).
pub fn server_host(url: &str) -> String {
    url.split_once("://")
        .and_then(|(_, rest)| split_authority(rest))
        .and_then(|(a, _)| split_host_port(a))
        .map(|(h, _)| h.trim_matches(['[', ']']).to_string())
        .filter(|h| !h.is_empty())
        .unwrap_or_else(|| url.to_string())
}

/// `setRemoteServerURL` and consent: only now are the address and the switch stored.
pub fn confirm_remote_consent(prefs: &mut Prefs, draft: &str) -> bool {
    let Some(origin) = remote_origin(draft) else { return false };
    prefs.set("remote.serverURL", origin);
    prefs.set("remote.consentVersion", REMOTE_CONSENT_VERSION);
    prefs.set("remote.enabled", true);
    true
}

/// `RewriteSettings.normalizedOrigin`: `scheme://host:port` with an explicit port.
pub fn rewrite_origin(endpoint: &str) -> Option<String> {
    let trimmed = endpoint.trim();
    if trimmed.is_empty() || trimmed.len() > 2048 || trimmed.chars().any(|c| c.is_whitespace()) {
        return None;
    }
    let (scheme, rest) = trimmed.split_once("://")?;
    let scheme = scheme.to_lowercase();
    if scheme != "http" && scheme != "https" {
        return None;
    }
    let (authority, _) = split_authority(rest)?;
    if authority.contains('@') {
        return None;
    }
    let (host, port) = split_host_port(authority)?;
    if host.is_empty() || !host.chars().all(|c| c as u32 > 32 && c as u32 != 127) {
        return None;
    }
    let port = port.unwrap_or(if scheme == "https" { 443 } else { 80 });
    if !(1..=65_535).contains(&port) {
        return None;
    }
    let origin = format!("{scheme}://{host}:{port}");
    (origin.len() <= 255).then_some(origin)
}

/// `RewriteSettings.host(of:)` for a normalized origin.
pub fn origin_host(origin: &str) -> String {
    server_host(origin)
}

pub fn is_loopback(host: &str) -> bool {
    let v = host.to_lowercase();
    if v == "localhost" || v == "::1" || v == "[::1]" {
        return true;
    }
    let octets: Vec<&str> = v.split('.').collect();
    octets.len() == 4 && octets[0] == "127" && octets.iter().all(|o| !o.is_empty() && o.bytes().all(|b| b.is_ascii_digit()) && o.parse::<u32>().is_ok_and(|n| n <= 255))
}

/// `http://` to something other than loopback.
pub fn is_unencrypted_remote(endpoint: &str) -> bool {
    rewrite_origin(endpoint).is_some_and(|o| o.starts_with("http://") && !is_loopback(&origin_host(&o)))
}

pub fn insecure_override(prefs: &Prefs, origin: &str) -> bool {
    prefs.get::<Map<String, Value>>("rewriteInsecureOverrides").is_some_and(|m| m.get(origin) == Some(&Value::Bool(true)))
}

/// Stored for off-loopback `http://` origins only; turning it off removes the entry.
pub fn set_insecure_override(prefs: &mut Prefs, origin: &str, on: bool) {
    if !origin.starts_with("http://") || is_loopback(&origin_host(origin)) {
        return;
    }
    let mut map: Map<String, Value> = prefs.get("rewriteInsecureOverrides").unwrap_or_default();
    if on {
        map.insert(origin.into(), Value::Bool(true));
    } else {
        map.remove(origin);
    }
    prefs.set("rewriteInsecureOverrides", map);
}

/// Precedence: blocked plain HTTP, then missing credential, then invalid endpoint. Nil when
/// rewriting may turn on (`RewriteSettings.refusalCategory`).
pub fn rewrite_refusal(prefs: &Prefs, credential_present: bool) -> Option<&'static str> {
    let endpoint = prefs.string("rewriteEndpoint").unwrap_or_default();
    let Some(origin) = rewrite_origin(&endpoint) else { return Some("invalid") };
    if is_unencrypted_remote(&endpoint) && !insecure_override(prefs, &origin) {
        return Some("Allow the unencrypted connection to this server first, or use https://.");
    }
    if !is_loopback(&origin_host(&origin)) && !credential_present {
        return Some("Set a credential for this server first.");
    }
    None
}

/// `settings.rewriteEnabled = true`: applies only when nothing blocks it (ONB-116).
pub fn set_rewrite_enabled(prefs: &mut Prefs, credential_present: bool) {
    prefs.set("rewriteEnabled", rewrite_refusal(prefs, credential_present).is_none());
}

/// Bounds on the stored secret, checked before the credential store is called.
pub fn credential_problem(secret: &str) -> Option<&'static str> {
    if secret.is_empty() {
        Some("Enter a credential first.")
    } else if secret.len() > 4096 {
        Some("The credential must be no more than 4,096 bytes.")
    } else if secret.trim() != secret || secret.contains(['\n', '\r']) {
        Some("Remove surrounding whitespace and line breaks.")
    } else {
        None
    }
}

/// `LocalAISetup.finish(.ready)`; `localHelpersReady` is the caller's in-memory flag.
pub fn local_ai_ready(prefs: &mut Prefs) {
    prefs.set("rewriteEndpoint", format!("http://127.0.0.1:{FLOWD_PORT}"));
    prefs.set("rewriteEnabled", true);
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub struct LocalAiModel {
    pub id: &'static str,
    pub name: &'static str,
    pub detail: &'static str,
    pub download_bytes: i64,
    pub peak_gb: f64,
    pub minimum_gb: u64,
}

impl LocalAiModel {
    pub fn fits(&self, physical_memory: u64) -> bool {
        physical_memory >= self.minimum_gb << 30
    }
    /// `.formatted()` of the peak: no trailing zero.
    pub fn peak(&self) -> String {
        localized(&format!("{}", self.peak_gb))
    }
    /// A finished pull in `models`, from LocalFlow or MTPLX.app.
    pub fn is_downloaded(&self, models: &Path) -> bool {
        let folder = models.join(self.id.replace('/', "--"));
        if !folder.join("mtplx_runtime.json").exists() {
            return false;
        }
        std::fs::read(folder.join(".mtplx-source.json"))
            .ok()
            .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
            .is_some_and(|v| v["repo_id"] == self.id)
    }
}

pub const CATALOG: [LocalAiModel; 5] = [
    LocalAiModel { id: "Youssofal/Qwen3.5-4B-MTPLX-Optimized-Speed", name: "Qwen 3.5 4B Speed", detail: "Fastest rewrites. The model LocalFlow's timeouts are tuned for.", download_bytes: 2_567_456_768, peak_gb: 2.9, minimum_gb: 8 },
    LocalAiModel { id: "Youssofal/Qwen3.5-4B-MTPLX-Optimized-Quality", name: "Qwen 3.5 4B Quality", detail: "8-bit weights. A little slower, closer to your wording.", download_bytes: 4_576_426_393, peak_gb: 4.8, minimum_gb: 16 },
    LocalAiModel { id: "Youssofal/Qwen3.5-9B-MTPLX-Optimized-Speed", name: "Qwen 3.5 9B Speed", detail: "Better meeting notes. Rewrites take longer.", download_bytes: 8_695_118_965, peak_gb: 10., minimum_gb: 24 },
    LocalAiModel { id: "Youssofal/Ternary-Bonsai-2-27B-MTPLX-Optimized-Speed", name: "Bonsai 2 27B", detail: "A 27B model in about 12 GB. Strong notes on mid-size Macs.", download_bytes: 8_847_918_956, peak_gb: 11.8, minimum_gb: 32 },
    LocalAiModel { id: "Youssofal/Qwen3.8-27B-MTPLX-Optimized-Speed", name: "Qwen 3.8 27B Speed", detail: "Highest quality. For Macs with plenty of memory.", download_bytes: 20_703_486_926, peak_gb: 25., minimum_gb: 48 },
];

/// Default model index: first downloaded and fitting, otherwise the recommended one.
pub fn default_model(downloaded: &[bool; 5], physical_memory: u64) -> usize {
    CATALOG.iter().enumerate().position(|(i, m)| downloaded[i] && m.fits(physical_memory)).unwrap_or(0)
}

/// `LocalAIPhase`. Failures hold the message `LocalAIError.message` gives.
#[derive(Clone, PartialEq, Debug)]
pub enum AiPhase {
    Idle,
    PreparingRuntime,
    DownloadingModel(i64, i64),
    Starting,
    Ready,
    Failed(String),
}

impl AiPhase {
    pub fn running(&self) -> bool {
        matches!(self, AiPhase::PreparingRuntime | AiPhase::DownloadingModel(..) | AiPhase::Starting)
    }
}

pub const AI_ERROR_MISSING: &str = "This copy of LocalFlow is missing its local AI files. Reinstall it.";
pub const AI_ERROR_DOWNLOAD: &str = "The download stopped. Check your connection and retry.";
pub const AI_ERROR_INTEGRITY: &str = "A downloaded file did not match its pinned checksum. Retry.";
pub const AI_ERROR_PACKAGES: &str = "The AI runtime could not be installed. Details are in local-ai-setup.log.";
pub const AI_ERROR_APPROVAL: &str = "Allow LocalFlow under System Settings → General → Login Items, then retry.";
pub const AI_ERROR_REGISTRATION: &str = "LocalFlow could not register its background services. Move it to Applications and retry.";
pub const AI_ERROR_TIMEOUT: &str = "The model did not start in time. Details are in local-ai-setup.log.";

pub fn ai_error_port() -> String {
    format!("Another AI server is using port {MTPLX_PORT} or {FLOWD_PORT}. Quit MTPLX.app or stop it, then retry.")
}

/// `DownloadRow.State`.
#[derive(Clone, PartialEq, Debug)]
pub enum RowState {
    Waiting(String),
    Working(String),
    Progress(i64, i64),
    Done,
    Failed(String),
}

impl RowState {
    /// The bar's fraction; `None` is indeterminate.
    pub fn fraction(completed: i64, total: i64) -> f64 {
        (completed as f64 / total.max(1) as f64).clamp(0., 1.)
    }
    /// The bar's accessibility value.
    pub fn percent(fraction: Option<f64>) -> String {
        match fraction {
            Some(f) => format!("{} percent", (f.clamp(0., 1.) * 100.).round() as i64),
            None => "In progress".into(),
        }
    }
}

pub fn speech_state(s: &Snapshot, error: Option<&str>) -> RowState {
    if s.model_installed {
        return RowState::Done;
    }
    if let Some(e) = &s.model_install_error {
        return RowState::Failed(e.clone());
    }
    if let Some(e) = error.filter(|_| !s.installing) {
        return RowState::Failed(e.into());
    }
    if !s.installing {
        return RowState::Waiting("Queued".into());
    }
    if s.verifying {
        return RowState::Working("Verifying…".into());
    }
    RowState::Progress(s.progress.0, s.progress.1)
}

pub fn ai_state(phase: &AiPhase) -> RowState {
    match phase {
        AiPhase::Idle => RowState::Waiting("Queued".into()),
        AiPhase::PreparingRuntime => RowState::Working("Installing MTPLX…".into()),
        AiPhase::DownloadingModel(c, t) => RowState::Progress(*c, *t),
        AiPhase::Starting => RowState::Working("Starting…".into()),
        AiPhase::Ready => RowState::Done,
        AiPhase::Failed(e) => RowState::Failed(e.clone()),
    }
}

pub fn meeting_state(s: &Snapshot) -> RowState {
    if s.meeting_pack_installed() {
        return RowState::Done;
    }
    if let Some(e) = &s.meeting_models_error {
        return RowState::Failed(e.clone());
    }
    if s.meeting_model_installing && s.meeting_progress.1 > 0 {
        return RowState::Progress(s.meeting_progress.0, s.meeting_progress.1);
    }
    if s.speaker_model_installing {
        return RowState::Working("Speaker labels…".into());
    }
    RowState::Waiting(if s.installing { "After speech recognition" } else { "Queued" }.into())
}

static DECIMAL: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new('.' as u32);

/// The current locale's decimal separator, set once at launch from `Services::decimal_separator`.
pub fn set_decimal_separator(c: char) {
    DECIMAL.store(c as u32, std::sync::atomic::Ordering::Relaxed);
}

pub fn decimal_separator() -> char {
    char::from_u32(DECIMAL.load(std::sync::atomic::Ordering::Relaxed)).unwrap_or('.')
}

/// A number already formatted with `.`, in the current locale (Swift's `.formatted()`).
pub fn localized(number: &str) -> String {
    number.replace('.', &decimal_separator().to_string())
}

/// `ByteCountFormatter` with `.file`: decimal units, whole KB, one decimal MB, two decimals GB.
pub fn bytes(v: i64) -> String {
    bytes_in(v, decimal_separator())
}

fn bytes_in(v: i64, separator: char) -> String {
    let f = v as f64;
    let trim = |n: f64, places: usize, unit: &str| {
        let s = format!("{n:.places$}");
        let s = if s.contains('.') { s.trim_end_matches('0').trim_end_matches('.') } else { &s };
        format!("{} {unit}", s.replace('.', &separator.to_string()))
    };
    match v {
        0 => "Zero KB".into(),
        1 => "1 byte".into(),
        _ if v < 1000 => format!("{v} bytes"),
        _ if v < 1_000_000 => trim(f / 1e3, 0, "KB"),
        _ if v < 1_000_000_000 => trim(f / 1e6, 1, "MB"),
        _ => trim(f / 1e9, 2, "GB"),
    }
}

pub fn memory(v: u64) -> String {
    format!("{} GB", v >> 30)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ready() -> Snapshot {
        Snapshot {
            model_installed: true,
            speaker_model_installed: true,
            meeting_model_installed: true,
            microphone: Perm::Granted,
            input_monitoring: Perm::Granted,
            accessibility: Perm::Granted,
            shortcut_ready: true,
            storage_available: true,
            ..Default::default()
        }
    }

    fn at(step: Step, purpose: Purpose, ai: AiMode) -> (Setup, Prefs) {
        let prefs = Prefs::memory();
        let mut s = Setup::new(&prefs);
        s.step = step;
        s.purpose = purpose;
        s.ai_mode = ai;
        (s, prefs)
    }

    // parity: ONB-150 ONB-166
    #[test]
    fn numbers_use_the_locale_separator() {
        assert_eq!(bytes_in(2_570_000_000, ','), "2,57 GB");
        assert_eq!(bytes_in(2_570_000_000, '.'), "2.57 GB");
        assert_eq!(bytes_in(1_500_000, ','), "1,5 MB");
        assert_eq!(bytes_in(2_000_000_000, ','), "2 GB");
    }

    // parity: ONB-034 ONB-065 ONB-066 ONB-067 ONB-068 ONB-069 ONB-070 ONB-071 ONB-072 ONB-073 ONB-074 ONB-075
    #[test]
    fn path_follows_choices() {
        use {AiMode::*, Purpose::*, Step as S};
        let long = vec![S::Introduction, S::Purpose, S::Ai, S::AiDetails, S::Downloads, S::Permissions, S::Personalize, S::Test];
        let skip = vec![S::Introduction, S::Purpose, S::Ai, S::Downloads, S::Permissions, S::Personalize, S::Test];
        assert_eq!(at(S::Ai, Both, Local).0.path(), long);
        assert_eq!(at(S::Ai, Both, Remote).0.path(), long);
        assert_eq!(at(S::Ai, Both, Off).0.path(), skip);
        assert_eq!(at(S::Ai, Dictation, Local).0.path(), long);
        assert_eq!(at(S::Ai, Dictation, Remote).0.path(), long);
        assert_eq!(at(S::Ai, Dictation, Off).0.path(), skip);
        assert_eq!(at(S::Ai, Meetings, Local).0.path(), long[..7].to_vec());
        assert_eq!(at(S::Ai, Meetings, Remote).0.path(), vec![S::Introduction, S::Purpose, S::Ai, S::AiDetails, S::Permissions, S::Personalize]);
        assert_eq!(at(S::Ai, Meetings, Off).0.path(), skip[..6].to_vec());
        assert_ne!(at(S::Ai, Both, Local).0.path().len(), at(S::Ai, Both, Off).0.path().len(), "the capsule count follows the choice");
        assert!(!at(S::Ai, Meetings, Remote).0.path().contains(&S::Test), "only dictation paths have a test");
        assert!(!at(S::Ai, Both, Local).0.path().contains(&S::Complete), "the capsules exclude complete");
    }

    // parity: ONB-005
    /// A relaunch starts over whatever the last run reached and set: nothing here is stored.
    #[test]
    fn a_relaunch_forgets_the_step_and_session_choices() {
        let mut p = Prefs::memory();
        let snap = ready();
        let mut s = Setup::new(&p);
        s.purpose = Purpose::Dictation;
        s.ai_mode = AiMode::Remote;
        s.advance(&snap, &mut p);
        s.advance(&snap, &mut p);
        assert_eq!(s.step, Step::Ai, "the run really moved on");
        s.download_meeting_models();
        s.test_armed = true;
        s.test_succeeded = true;
        let fresh = Setup::new(&p);
        assert_eq!((fresh.step, fresh.ai_mode), (Step::Introduction, AiMode::Local));
        assert!(!fresh.meetings_requested && !fresh.test_armed && !fresh.test_succeeded);
    }

    // parity: ONB-006 ONB-007 ONB-008 ONB-009 ONB-132 ONB-409
    #[test]
    fn resume_rules() {
        let mut p = Prefs::memory();
        assert_eq!(Setup::new(&p).purpose, Purpose::Both);
        p.set("setup.purpose", "nonsense");
        assert_eq!(Setup::new(&p).purpose, Purpose::Both);
        p.set("setup.purpose", "dictation");
        p.set("appearance", "dark");
        let mut s = Setup::new(&p);
        s.resume_unfinished(&mut p);
        assert_eq!((s.purpose, s.step, s.ai_mode), (Purpose::Dictation, Step::Introduction, AiMode::Local));
        assert_eq!(p.string("appearance").as_deref(), Some("dark"));

        let mut p = Prefs::memory();
        p.set("setup.purpose", "meetings");
        p.set("server.only", true);
        p.set("remote.enabled", true);
        p.set("remote.serverURL", "https://s");
        let mut s = Setup::new(&p);
        s.resume_unfinished(&mut p);
        assert_eq!(s.purpose, Purpose::Both);
        assert_eq!(p.string("setup.purpose").as_deref(), Some("both"));
        assert!(!p.bool_or("server.only", true));
        assert_eq!(s.effects, vec![Effect::AbandonServer]);

        // Either flag alone abandons; neither just moves the purpose.
        for (key, abandons) in [("server.only", true), ("remote.enabled", true), ("unrelated", false)] {
            let mut p = Prefs::memory();
            p.set("setup.purpose", "meetings");
            p.set(key, true);
            let mut s = Setup::new(&p);
            s.resume_unfinished(&mut p);
            assert_eq!(s.purpose, Purpose::Both, "{key}");
            assert_eq!(s.effects.contains(&Effect::AbandonServer), abandons, "{key}");
        }

        // A finished install keeps meetings.
        let mut p = Prefs::memory();
        p.set("setupVersion", 1);
        p.set("setup.purpose", "meetings");
        let mut s = Setup::new(&p);
        s.resume_unfinished(&mut p);
        assert_eq!((s.purpose, p.string("setup.purpose").as_deref()), (Purpose::Meetings, Some("meetings")));

        // Finished: nothing changes, and no setup.purpose appears on an install without one.
        let mut p = Prefs::memory();
        p.set("setupVersion", 1);
        p.set("server.only", true);
        Setup::new(&p).resume_unfinished(&mut p);
        assert!(!p.contains("setup.purpose"));
        assert!(p.bool_or("server.only", false));
    }

    // parity: ONB-093 ONB-094 ONB-095 ONB-096 ONB-097 ONB-098 ONB-099 ONB-100 ONB-101 ONB-102 ONB-103 ONB-104 ONB-064 ONB-268
    #[test]
    fn advance_walks_steps_and_requests_models() {
        let snap = ready();
        let mut p = Prefs::memory();
        let mut s = Setup::new(&p);
        s.advance(&snap, &mut p);
        assert_eq!(s.step, Step::Purpose);
        s.purpose = Purpose::Dictation;
        assert!(!p.contains("setup.purpose"));
        s.advance(&snap, &mut p);
        assert_eq!((s.step, p.string("setup.purpose").as_deref()), (Step::Ai, Some("dictation")));
        s.advance(&snap, &mut p);
        assert_eq!(s.step, Step::AiDetails);
        s.advance(&snap, &mut p);
        assert_eq!(s.step, Step::Downloads);
        assert_eq!(s.effects, vec![Effect::StartDownloads { local_ai: true }]);

        // Automatic meeting models table.
        for (purpose, ai, auto) in [
            (Purpose::Both, AiMode::Local, true),
            (Purpose::Both, AiMode::Off, true),
            (Purpose::Meetings, AiMode::Local, true),
            (Purpose::Meetings, AiMode::Off, true),
            (Purpose::Dictation, AiMode::Local, false),
            (Purpose::Dictation, AiMode::Off, false),
            (Purpose::Both, AiMode::Remote, false),
            (Purpose::Dictation, AiMode::Remote, false),
        ] {
            let (mut s, mut p) = at(Step::AiDetails, purpose, ai);
            s.advance(&snap, &mut p);
            assert_eq!(s.meetings_requested, auto, "{purpose:?} {ai:?}");
            assert_eq!(s.effects.contains(&Effect::StartMeetingModels), auto);
        }

        // Going back doesn't ask twice; a server path withdraws only what was automatic.
        let (mut s, mut p) = at(Step::AiDetails, Purpose::Both, AiMode::Local);
        s.advance(&snap, &mut p);
        s.back();
        s.effects.clear();
        s.advance(&snap, &mut p);
        assert!(!s.effects.contains(&Effect::StartMeetingModels));
        s.ai_mode = AiMode::Remote;
        s.step = Step::AiDetails;
        s.effects.clear();
        s.advance(&snap, &mut p);
        assert!(s.effects.contains(&Effect::CancelMeetingModels));
        assert!(!s.meetings_requested);

        // Meetings on a server skips downloads and stores server.only.
        let (mut s, mut p) = at(Step::AiDetails, Purpose::Meetings, AiMode::Remote);
        s.advance(&snap, &mut p);
        assert_eq!(s.step, Step::Permissions);
        assert!(p.bool_or("server.only", false));

        // Gates.
        let (mut s, mut p) = at(Step::Downloads, Purpose::Both, AiMode::Local);
        s.advance(&Snapshot::default(), &mut p);
        assert_eq!(s.step, Step::Downloads);
        s.advance(&Snapshot { model_installed: true, ..Default::default() }, &mut p);
        assert_eq!(s.step, Step::Permissions);
        s.advance(&Snapshot::default(), &mut p);
        assert_eq!(s.step, Step::Permissions);
        s.advance(&snap, &mut p);
        assert_eq!(s.step, Step::Personalize);
        s.advance(&snap, &mut p);
        assert_eq!(s.step, Step::Test);
        s.advance(&snap, &mut p);
        assert_eq!(s.step, Step::Test, "no finish before success");
    }

    // parity: ONB-052 ONB-105 ONB-106 ONB-108 ONB-109 ONB-266 ONB-267 ONB-043 ONB-115 ONB-264
    #[test]
    fn skip_abandon_and_back() {
        let snap = ready();
        let (mut s, mut p) = at(Step::Ai, Purpose::Both, AiMode::Remote);
        p.set("remote.enabled", true);
        p.set("remote.serverURL", "https://s");
        p.set("remote.state", "approved");
        p.set("remote.notice", "sign_in_again");
        p.set("remote.consentVersion", 2);
        p.set("server.capabilities", 3);
        p.set("server.only", true);
        p.set("server.useForEverything", true);
        p.set("rewriteEnabled", true);
        s.advance(&snap, &mut p);
        // A different purpose abandons, from the purpose step as well.
        let (mut other, mut other_prefs) = at(Step::Ai, Purpose::Both, AiMode::Remote);
        other.advance(&snap, &mut other_prefs);
        other.back();
        other.back();
        other.purpose = Purpose::Dictation;
        other.effects.clear();
        other.advance(&snap, &mut other_prefs);
        assert_eq!(other.step, Step::Ai);
        assert!(other.effects.contains(&Effect::AbandonServer));
        // Back with the same choice keeps it.
        s.back();
        s.effects.clear();
        s.advance(&snap, &mut p);
        assert!(!s.effects.contains(&Effect::AbandonServer));
        assert_eq!(s.step, Step::AiDetails);
        s.back();
        s.skip_ai(&mut p);
        assert_eq!((s.step, s.ai_mode), (Step::Downloads, AiMode::Off));
        assert!(s.effects.contains(&Effect::AbandonServer));
        assert!(!p.bool_or("server.only", true));
        assert!(!p.contains("server.useForEverything"));
        assert!(!p.bool_or("rewriteEnabled", true));
        reset_remote(&mut p);
        for k in ["remote.serverURL", "remote.state", "remote.notice", "remote.consentVersion", "server.capabilities"] {
            assert!(!p.contains(k), "{k}");
        }
        assert!(p.contains("remote.enabled") && !remote_on(&p));

        // Skip is only for the AI step, and Back after it lands on ai with Off kept.
        let (mut s, mut p) = at(Step::Purpose, Purpose::Both, AiMode::Local);
        s.skip_ai(&mut p);
        assert_eq!(s.step, Step::Purpose);
        let (mut s, mut p) = at(Step::Ai, Purpose::Dictation, AiMode::Local);
        s.skip_ai(&mut p);
        s.back();
        assert_eq!((s.step, s.ai_mode), (Step::Ai, AiMode::Off));

        // Manual download on Dictation stays requested; retry asks again.
        let (mut s, mut p) = at(Step::Ai, Purpose::Dictation, AiMode::Off);
        s.advance(&snap, &mut p);
        assert!(!s.meetings_requested);
        s.download_meeting_models();
        assert!(s.meetings_requested);
        s.effects.clear();
        s.download_meeting_models();
        assert!(s.effects.is_empty(), "once");
        s.retry_meeting_models();
        assert_eq!(s.effects, vec![Effect::StartMeetingModels]);
        s.step = Step::AiDetails;
        s.ai_mode = AiMode::Remote;
        s.effects.clear();
        s.advance(&snap, &mut p);
        assert!(s.meetings_requested && !s.effects.contains(&Effect::CancelMeetingModels), "manual is never withdrawn");

        // Back clears the armed test, keeps success, and persists nothing.
        let (mut s, mut p) = at(Step::Test, Purpose::Both, AiMode::Local);
        s.test_armed = true;
        s.test_error = Some("x".into());
        s.test_succeeded = true;
        s.back();
        assert_eq!(s.step, Step::Personalize);
        assert!(!s.test_armed && s.test_error.is_none() && s.test_succeeded);
        assert!(!p.contains("setup.purpose"));
        p.set("a", 1);
    }

    // parity: ONB-054 ONB-399 ONB-400 ONB-401 ONB-402 ONB-410 ONB-002 ONB-398 ONB-397
    #[test]
    fn finish_writes_setup_version_and_speech_model() {
        let snap = ready();
        let (mut s, mut p) = at(Step::Personalize, Purpose::Meetings, AiMode::Local);
        assert!(!is_complete(&p));
        s.advance(&snap, &mut p);
        assert_eq!(s.step, Step::Complete);
        assert_eq!(s.effects, vec![Effect::OpenNotetaker]);
        assert_eq!(p.int_or("setupVersion", 0), 1);
        assert_eq!(p.string("speechModel").as_deref(), Some("parakeet-ultra"));
        assert!(is_complete(&p));

        let (mut s, mut p) = at(Step::Test, Purpose::Both, AiMode::Local);
        p.set("speechModel", "parakeet-v3");
        s.test_armed = true;
        s.skip_test(&snap, &mut p);
        assert_eq!(s.step, Step::Complete);
        assert!(s.effects.is_empty() && !s.test_armed);
        assert_eq!(p.string("speechModel").as_deref(), Some("parakeet-v3"));

        let mut p = Prefs::memory();
        p.set("setupVersion", 1);
        assert_eq!(speech_model_raw(&p), "parakeet-v3");
    }

    // parity: ONB-390 ONB-392
    #[test]
    fn test_evidence_needs_the_armed_session() {
        let snap = ready();
        let (mut s, mut p) = at(Step::Test, Purpose::Both, AiMode::Local);
        assert!(!s.begin_arming(&Snapshot::default()), "silently returns if not ready");
        assert!(s.begin_arming(&snap));
        assert!(s.preparing_test);
        s.finish_arming(Ok(()), &snap);
        assert!(s.test_armed && !s.preparing_test);
        s.record_successful_dictation(7);
        assert!(!s.test_succeeded, "a session from before arming is no evidence");
        s.dictation_started(7);
        s.record_successful_dictation(8);
        assert!(!s.test_succeeded);
        s.dictation_ended(7, "The microphone stopped.");
        assert_eq!((s.test_armed, s.test_error.as_deref()), (false, Some("The microphone stopped.")));
        s.start_test(&snap);
        assert!(s.test_armed && s.test_error.is_none());
        s.dictation_started(9);
        s.record_successful_dictation(9);
        assert!(s.test_succeeded && !s.test_armed);
        s.advance(&snap, &mut p);
        assert_eq!(s.step, Step::Complete);
        // A failed prepare shows its error.
        let (mut s, _) = at(Step::Test, Purpose::Both, AiMode::Local);
        s.begin_arming(&snap);
        s.finish_arming(Err("The speech model is unavailable.".into()), &snap);
        assert_eq!(s.test_error.as_deref(), Some("The speech model is unavailable."));
        assert!(!s.test_armed);
    }

    // parity: ONB-048 ONB-081 ONB-082 ONB-084 ONB-086 ONB-083 ONB-085 ONB-089 ONB-092 ONB-090 ONB-091 ONB-117 ONB-325 ONB-326 ONB-337 ONB-338 ONB-339
    #[test]
    fn readiness_and_block_order() {
        let mut s = Snapshot::default();
        let (dl, _) = at(Step::Downloads, Purpose::Both, AiMode::Local);
        let (dm, _) = at(Step::Downloads, Purpose::Meetings, AiMode::Local);
        s.model_installed = true;
        assert!(dl.downloads_ready(&s) && !dm.downloads_ready(&s));
        s.speaker_model_installed = true;
        s.meeting_model_installed = true;
        assert!(dm.downloads_ready(&s));

        let mut s = ready();
        assert!(s.ready_for_test() && s.ready_for_meetings());
        s.storage_available = false;
        assert_eq!(s.meeting_blocked_reason(), Some("Local storage is not ready. Check Settings before recording."));
        assert_eq!(s.test_blocked_reason().as_deref(), Some("Local storage is not ready. Check Settings before recording."));
        s.storage_available = true;
        s.busy = true;
        assert_eq!(s.test_blocked_reason().as_deref(), Some("Wait for the current dictation to finish."));
        assert!(!s.ready_for_test());
        s.busy = false;
        s.controls_available = false;
        assert_eq!(s.test_blocked_reason().as_deref(), Some("Wait for the model operation to finish."));
        assert!(!s.ready_for_test());
        s.controls_available = true;
        s.shortcut_ready = false;
        assert_eq!(s.test_blocked_reason().as_deref(), Some("Starting the dictation shortcut…"));
        s.shortcut.kind = ShortcutKind::KeyCombination;
        s.accessibility = Perm::Denied;
        assert_eq!(s.test_blocked_reason().as_deref(), Some("Allow Accessibility for this shortcut, or choose a modifier key."));
        s.shortcut.enabled = false;
        assert_eq!(s.test_blocked_reason().as_deref(), Some("Enable a dictation shortcut."));
        s.input_monitoring = Perm::Denied;
        assert_eq!(s.test_blocked_reason().as_deref(), Some("Allow Input Monitoring to use the shortcut."));
        s.microphone = Perm::Denied;
        assert_eq!(s.test_blocked_reason().as_deref(), Some("Allow Microphone access to record."));
        assert_eq!(s.meeting_blocked_reason(), Some("Allow Microphone access to record."));
        s.model_installed = false;
        assert_eq!(s.test_blocked_reason().as_deref(), Some("Finish downloading speech recognition first."));
        s.model_install_error = Some("Model installation cancelled.".into());
        assert_eq!(s.test_blocked_reason().as_deref(), Some("Model installation cancelled."));

        // Each input of `readyForTest` alone turns it off.
        let knocks: [fn(&mut Snapshot); 10] = [
            |s| s.storage_available = false,
            |s| s.model_installed = false,
            |s| s.microphone = Perm::Denied,
            |s| s.input_monitoring = Perm::Denied,
            |s| s.shortcut_ready = false,
            |s| s.shortcut.enabled = false,
            |s| s.busy = true,
            |s| s.installing = true,
            |s| s.runtime_leased = true,
            |s| s.controls_available = false,
        ];
        for (i, knock) in knocks.iter().enumerate() {
            let mut s = ready();
            knock(&mut s);
            assert!(!s.ready_for_test(), "input {i}");
        }

        // Accessibility and system audio never block.
        let mut s = ready();
        s.accessibility = Perm::Denied;
        s.system_audio = Perm::Denied;
        assert!(s.ready_for_test() && s.ready_for_meetings());
        assert!(s.has_missing_permissions());
    }

    // parity: ONB-211 ONB-237
    #[test]
    fn origins_and_overrides() {
        assert_eq!(remote_origin(" https://Server.Example.com:8443/ ").as_deref(), Some("https://server.example.com:8443"));
        assert_eq!(remote_origin("https://server.example.com").as_deref(), Some("https://server.example.com"));
        for bad in ["http://a", "https://", "https://u:p@a", "https://a/x", "https://a?x=1", "https://a#f", "a.example", "https://a b", ""] {
            assert_eq!(remote_origin(bad), None, "{bad}");
        }
        assert_eq!(rewrite_origin("https://Studio.local").as_deref(), Some("https://studio.local:443"));
        assert_eq!(rewrite_origin("http://studio.local:8080/x").as_deref(), Some("http://studio.local:8080"));
        assert_eq!(rewrite_origin("ftp://a"), None);
        assert_eq!(rewrite_origin("http://u@a"), None);
        assert_eq!(rewrite_origin("http://a:70000"), None);
        assert!(is_unencrypted_remote("http://studio.local:8080"));
        assert!(!is_unencrypted_remote("http://127.0.0.1:8080"));
        assert!(!is_unencrypted_remote("https://studio.local"));
        assert_eq!(origin_host("http://studio.local:8080"), "studio.local");
        assert_eq!(server_host("https://server.example.com:8443"), "server.example.com");

        let mut p = Prefs::memory();
        set_insecure_override(&mut p, "http://127.0.0.1:80", true);
        assert!(!insecure_override(&p, "http://127.0.0.1:80"));
        set_insecure_override(&mut p, "https://a:443", true);
        assert!(!p.contains("rewriteInsecureOverrides"));
        set_insecure_override(&mut p, "http://a:80", true);
        assert!(insecure_override(&p, "http://a:80"));
        set_insecure_override(&mut p, "http://a:80", false);
        assert!(!insecure_override(&p, "http://a:80"));
    }

    // parity: ONB-116 ONB-063 ONB-241 ONB-235
    #[test]
    fn rewrite_flag_only_turns_on_when_nothing_blocks_it() {
        let mut p = Prefs::memory();
        set_rewrite_enabled(&mut p, true);
        assert!(!p.bool_or("rewriteEnabled", true), "empty endpoint stays off");
        p.set("rewriteEndpoint", "https://s");
        set_rewrite_enabled(&mut p, false);
        assert!(!p.bool_or("rewriteEnabled", true));
        assert_eq!(rewrite_refusal(&p, false), Some("Set a credential for this server first."));
        set_rewrite_enabled(&mut p, true);
        assert!(p.bool_or("rewriteEnabled", false));
        p.set("rewriteEndpoint", "http://s");
        assert_eq!(rewrite_refusal(&p, true), Some("Allow the unencrypted connection to this server first, or use https://."));
        assert_eq!(credential_problem(""), Some("Enter a credential first."));
        assert_eq!(credential_problem(" a"), Some("Remove surrounding whitespace and line breaks."));
        assert_eq!(credential_problem(&"a".repeat(4097)), Some("The credential must be no more than 4,096 bytes."));
        assert_eq!(credential_problem("key"), None);
    }

    // parity: ONB-079 ONB-080 ONB-181 ONB-182 ONB-183 ONB-184 ONB-185 ONB-186 ONB-187 ONB-188 ONB-189 ONB-190 ONB-191 ONB-221 ONB-223 ONB-224 ONB-225 ONB-226 ONB-227 ONB-228 ONB-229 ONB-216
    #[test]
    fn remote_status_privacy_and_gate() {
        let mut p = Prefs::memory();
        p.set("remote.state", "approved");
        assert!(!enrolled(&p), "approved means nothing with the switch off");
        p.set("remote.enabled", true);
        assert!(enrolled(&p));
        p.set("remote.state", "pending");
        assert!(enrolled(&p), "pending may continue");
        p.set("remote.state", "pinned");
        assert!(!enrolled(&p));
        let mut p = Prefs::memory();
        assert_eq!(remote_status(&p, false), None);
        assert!(remote_privacy(&p).starts_with("Nothing leaves this Mac until you confirm"));
        assert!(!confirm_remote_consent(&mut p, "http://nope"));
        assert!(!remote_on(&p));
        assert!(confirm_remote_consent(&mut p, "https://s.example"));
        assert_eq!(p.string("remote.serverURL").as_deref(), Some("https://s.example"));
        assert_eq!(p.int_or("remote.consentVersion", 0), 2);
        assert!(remote_on(&p));
        assert_eq!(remote_status(&p, false), Some("Checking the server…"));
        assert_eq!(remote_status(&p, true), Some("Compare the fingerprint"));
        for (state, text) in [("pinned", "Sign in to finish"), ("pending", "Waiting for approval"), ("approved", "Approved"), ("rejected", "Rejected"), ("revoked", "Removed from the server"), ("pin_mismatch", "Server identity changed")] {
            p.set("remote.state", state);
            assert_eq!(remote_status(&p, false), Some(text));
            let enrolled_state = matches!(state, "approved" | "pending");
            assert_eq!(enrolled(&p), enrolled_state);
            assert_eq!(server_ready(&p, Purpose::Meetings, true), enrolled_state, "rewrite-only never counts for meetings");
            assert!(server_ready(&p, Purpose::Both, true));
            assert_eq!(server_ready(&p, Purpose::Both, false), enrolled_state);
            assert!(remote_privacy(&p).ends_with("at most 7 days."));
        }
        p.set("remote.state", "pinned");
        p.set("remote.notice", "sign_in_again");
        assert_eq!(remote_status(&p, false), Some("Sign in again"));
        p.set("remote.notice", "update_required");
        assert_eq!(remote_status(&p, false), Some("Update LocalFlow or the server"));
        p.remove("remote.notice");
        p.set("remote.state", "approved");
        assert!(remote_privacy(&p).starts_with("Approved. Dictation"));
        p.set("setup.purpose", "meetings");
        assert!(remote_privacy(&p).starts_with("Approved. Meeting audio"));
        p.set("remote.state", "pending");
        assert!(remote_privacy(&p).contains("recordings wait here"));
        p.set("setup.purpose", "both");
        assert!(remote_privacy(&p).contains("dictation is transcribed here"));
        p.set("remote.state", "rejected");
        assert!(remote_privacy(&p).starts_with("Nothing is sent until"));
    }

    // parity: ONB-223 ONB-224 ONB-225 ONB-226 ONB-227 ONB-228
    #[test]
    fn privacy_lines_word_for_word() {
        const KEPT: &str = " Meetings handed off to the server stay there until merged, at most 7 days.";
        let mut p = Prefs::memory();
        assert_eq!(remote_privacy(&p), format!("Nothing leaves this Mac until you confirm what is sent and the administrator approves this Mac.{KEPT}"));
        assert!(confirm_remote_consent(&mut p, "https://s.example"));
        p.set("remote.state", "approved");
        assert_eq!(remote_privacy(&p), format!("Approved. Dictation, rewriting, summaries and meetings will use this server. Speech recognition on this Mac takes over when the server can't be reached.{KEPT}"));
        p.set("remote.state", "pending");
        assert_eq!(remote_privacy(&p), format!("Waiting for approval. You can continue: until the administrator approves this Mac, nothing is sent and dictation is transcribed here.{KEPT}"));
        p.set("remote.state", "pin_mismatch");
        assert_eq!(remote_privacy(&p), format!("Nothing is sent until the administrator approves this Mac.{KEPT}"));
        p.set("setup.purpose", "meetings");
        p.set("remote.state", "approved");
        assert_eq!(remote_privacy(&p), format!("Approved. Meeting audio, transcripts and summaries will use this server. Recordings wait on this Mac when the server can't be reached.{KEPT}"));
        p.set("remote.state", "pending");
        assert_eq!(remote_privacy(&p), format!("Waiting for approval. You can continue: until the administrator approves this Mac, nothing is sent and recordings wait here.{KEPT}"));
    }

    // parity: ONB-274
    /// Leaving the step cancels nothing; coming back asks for nothing again.
    #[test]
    fn downloads_outlive_the_step() {
        let snap = ready();
        let (mut s, mut p) = at(Step::AiDetails, Purpose::Both, AiMode::Local);
        s.advance(&snap, &mut p);
        assert!(s.effects.contains(&Effect::StartMeetingModels));
        s.effects.clear();
        s.back();
        assert_eq!(s.step, Step::AiDetails);
        assert!(s.effects.is_empty(), "Back cancels nothing");
        s.advance(&snap, &mut p);
        assert!(!s.effects.contains(&Effect::StartMeetingModels), "no second request");
        assert!(!s.effects.contains(&Effect::CancelMeetingModels));
        s.effects.clear();
        s.advance(&snap, &mut p);
        assert_eq!(s.step, Step::Permissions);
        assert!(s.effects.is_empty(), "Continue cancels nothing");
    }

    // parity: ONB-150 ONB-159 ONB-160 ONB-161 ONB-162 ONB-163 ONB-168 ONB-169 ONB-170 ONB-173
    #[test]
    fn catalog_fit_and_downloaded() {
        assert_eq!(bytes(CATALOG[0].download_bytes), "2.57 GB");
        assert_eq!(bytes(CATALOG[1].download_bytes), "4.58 GB");
        assert_eq!(bytes(CATALOG[2].download_bytes), "8.7 GB");
        assert_eq!(bytes(CATALOG[3].download_bytes), "8.85 GB");
        assert_eq!(bytes(CATALOG[4].download_bytes), "20.7 GB");
        assert_eq!(CATALOG.map(|m| m.minimum_gb), [8, 16, 24, 32, 48]);
        assert_eq!(CATALOG.map(|m| m.peak()), ["2.9".to_string(), "4.8".into(), "10".into(), "11.8".into(), "25".into()]);
        assert!(CATALOG[0].fits(8 << 30));
        assert!(!CATALOG[0].fits((8 << 30) - 1));
        assert_eq!(default_model(&[false; 5], 16 << 30), 0);
        assert_eq!(default_model(&[false, true, false, false, true], 16 << 30), 1);
        assert_eq!(default_model(&[false, false, false, false, true], 16 << 30), 0, "doesn't fit");

        let dir = std::env::temp_dir().join(format!("flow-mtplx-{}", std::process::id()));
        let m = CATALOG[0];
        let folder = dir.join(m.id.replace('/', "--"));
        std::fs::create_dir_all(&folder).unwrap();
        assert!(!m.is_downloaded(&dir));
        std::fs::write(folder.join("mtplx_runtime.json"), "{}").unwrap();
        assert!(!m.is_downloaded(&dir));
        std::fs::write(folder.join(".mtplx-source.json"), r#"{"repo_id":"other"}"#).unwrap();
        assert!(!m.is_downloaded(&dir));
        std::fs::write(folder.join(".mtplx-source.json"), format!(r#"{{"repo_id":"{}"}}"#, m.id)).unwrap();
        assert!(m.is_downloaded(&dir));
        std::fs::remove_dir_all(dir).unwrap();
    }

    // parity: ONB-285 ONB-286 ONB-287 ONB-288 ONB-289 ONB-290 ONB-313
    #[test]
    fn speech_row_states() {
        let mut s = Snapshot::default();
        assert_eq!(speech_state(&s, None), RowState::Waiting("Queued".into()));
        assert_eq!(speech_state(&s, Some("unrelated")), RowState::Failed("unrelated".into()));
        s.installing = true;
        assert_eq!(speech_state(&s, Some("unrelated")), RowState::Progress(0, 0), "an error doesn't interrupt an install");
        s.progress = (5, 10);
        assert_eq!(speech_state(&s, None), RowState::Progress(5, 10));
        s.verifying = true;
        assert_eq!(speech_state(&s, None), RowState::Working("Verifying…".into()));
        s.model_install_error = Some("Model installation cancelled.".into());
        assert_eq!(speech_state(&s, None), RowState::Failed("Model installation cancelled.".into()));
        s.model_installed = true;
        assert_eq!(speech_state(&s, None), RowState::Done);
    }

    // parity: ONB-291 ONB-292 ONB-293 ONB-294 ONB-295
    #[test]
    fn ai_row_states() {
        assert_eq!(ai_state(&AiPhase::Idle), RowState::Waiting("Queued".into()));
        assert_eq!(ai_state(&AiPhase::PreparingRuntime), RowState::Working("Installing MTPLX…".into()));
        assert_eq!(ai_state(&AiPhase::DownloadingModel(1, 2)), RowState::Progress(1, 2));
        assert_eq!(ai_state(&AiPhase::Starting), RowState::Working("Starting…".into()));
        assert_eq!(ai_state(&AiPhase::Ready), RowState::Done);
    }

    // Strings only: no installer reports these yet, so no row is credited.
    #[test]
    fn ai_failure_messages() {
        assert_eq!(AI_ERROR_MISSING, "This copy of LocalFlow is missing its local AI files. Reinstall it.");
        assert_eq!(AI_ERROR_DOWNLOAD, "The download stopped. Check your connection and retry.");
        assert_eq!(AI_ERROR_INTEGRITY, "A downloaded file did not match its pinned checksum. Retry.");
        assert_eq!(AI_ERROR_PACKAGES, "The AI runtime could not be installed. Details are in local-ai-setup.log.");
        assert_eq!(ai_error_port(), "Another AI server is using port 8000 or 8080. Quit MTPLX.app or stop it, then retry.");
        assert_eq!(AI_ERROR_APPROVAL, "Allow LocalFlow under System Settings → General → Login Items, then retry.");
        assert_eq!(AI_ERROR_REGISTRATION, "LocalFlow could not register its background services. Move it to Applications and retry.");
        assert_eq!(AI_ERROR_TIMEOUT, "The model did not start in time. Details are in local-ai-setup.log.");
        assert_eq!(ai_state(&AiPhase::Failed(AI_ERROR_TIMEOUT.into())), RowState::Failed(AI_ERROR_TIMEOUT.into()));
    }

    // No installer reports Ready yet, so the row is not credited.
    #[test]
    fn ai_ready_points_rewriting_at_the_local_helper() {
        let mut p = Prefs::memory();
        local_ai_ready(&mut p);
        assert_eq!(p.string("rewriteEndpoint").as_deref(), Some("http://127.0.0.1:8080"));
        assert!(p.bool_or("rewriteEnabled", false));
    }

    // parity: ONB-307 ONB-308 ONB-309 ONB-310 ONB-311 ONB-312
    #[test]
    fn meeting_row_states() {
        let mut s = Snapshot::default();
        assert_eq!(meeting_state(&s), RowState::Waiting("Queued".into()));
        s.installing = true;
        assert_eq!(meeting_state(&s), RowState::Waiting("After speech recognition".into()));
        s.speaker_model_installing = true;
        assert_eq!(meeting_state(&s), RowState::Working("Speaker labels…".into()));
        s.meeting_model_installing = true;
        s.meeting_progress = (1, 4);
        assert_eq!(meeting_state(&s), RowState::Progress(1, 4));
        s.meeting_models_error = Some("Meeting models did not finish downloading. Check your connection and available storage.".into());
        assert!(matches!(meeting_state(&s), RowState::Failed(_)));
        s.meeting_model_installed = true;
        assert!(matches!(meeting_state(&s), RowState::Failed(_)), "Whisper alone isn't the pack");
        s.speaker_model_installed = true;
        assert_eq!(meeting_state(&s), RowState::Done);
    }

    // parity: ONB-284
    #[test]
    fn bar_percent_text() {
        assert_eq!(RowState::fraction(5, 0), 1.);
        assert_eq!(RowState::percent(Some(RowState::fraction(1, 4))), "25 percent");
        assert_eq!(RowState::percent(None), "In progress");
    }

    #[test]
    fn byte_and_memory_text() {
        assert_eq!(bytes(SPEECH_FALLBACK_BYTES), "632.2 MB");
        assert_eq!(bytes(MEETING_BYTES), "1.65 GB");
        assert_eq!(memory(36 << 30), "36 GB");
    }

    // parity: ONB-371
    #[test]
    fn capture_commits_after_release() {
        let mut c = ShortcutCapture::default();
        assert_eq!(c.receive(KeyEvent::KeyDown, 53, 0, None), Capture::Cancelled, "Esc cancels");
        assert_eq!(c.receive(KeyEvent::KeyDown, 0, 0, None), Capture::Pending, "a finished capture ignores the rest");
        // A chord: nothing until the key and the modifiers are both up.
        let mut c = ShortcutCapture::default();
        assert_eq!(c.receive(KeyEvent::FlagsChanged, 59, CONTROL, Some(0x01)), Capture::Pending);
        assert_eq!(c.receive(KeyEvent::KeyDown, 40, CONTROL, Some(0x01)), Capture::Pending);
        assert_eq!(c.receive(KeyEvent::KeyUp, 40, CONTROL, Some(0x01)), Capture::Pending);
        let Capture::Captured(chord) = c.receive(KeyEvent::FlagsChanged, 59, 0, None) else { panic!("chord didn't commit") };
        assert_eq!((chord.kind, chord.key_code, chord.modifiers), (ShortcutKind::KeyCombination, 40, CONTROL));
        // Modifier only, keeping its side; fn alone becomes fn / Globe.
        let mut c = ShortcutCapture::default();
        c.receive(KeyEvent::FlagsChanged, 62, CONTROL, Some(0x2000));
        let Capture::Captured(side) = c.receive(KeyEvent::FlagsChanged, 62, 0, None) else { panic!("modifier didn't commit") };
        assert_eq!(side.title(), "Right Control");
        let mut c = ShortcutCapture::default();
        c.receive(KeyEvent::FlagsChanged, 63, FN, None);
        let Capture::Captured(globe) = c.receive(KeyEvent::FlagsChanged, 63, 0, None) else { panic!("fn didn't commit") };
        assert_eq!(globe.kind, ShortcutKind::FnGlobe);
        // A bare Return with its key up is a valid chord; an out-of-range key is not, and keeps waiting.
        let mut c = ShortcutCapture::default();
        c.receive(KeyEvent::KeyDown, 200, 0, None);
        assert_eq!(c.receive(KeyEvent::KeyUp, 200, 0, None), Capture::Pending);
    }

    // parity: ONB-376 ONB-377 ONB-380 ONB-347 ONB-009
    #[test]
    fn shortcut_values_titles_and_json() {
        assert_eq!(Shortcut::right_control().title(), "Right Control");
        assert_eq!(Shortcut::right_option().title(), "Right Option");
        assert_eq!(Shortcut::fn_globe().title(), "fn / Globe");
        assert_eq!(Shortcut { enabled: false, ..Default::default() }.title(), "Disabled");
        let chord = Shortcut { kind: ShortcutKind::KeyCombination, modifiers: CONTROL | COMMAND | FN, key_code: 123, device_modifiers: None, ..Default::default() };
        assert_eq!(chord.title(), "⌃ ⌘ fn ←");
        assert_eq!(Shortcut { kind: ShortcutKind::KeyCombination, modifiers: 0, key_code: 122, ..Default::default() }.title(), "F1");

        let mut p = Prefs::memory();
        assert!(!Shortcut::is_saved(&p));
        assert_eq!(Shortcut::load(&p), Shortcut::fn_globe());
        Shortcut::right_control().save(&mut p);
        assert!(Shortcut::is_saved(&p));
        assert_eq!(Shortcut::load(&p), Shortcut::right_control());
        let v: Value = p.get("shortcut").unwrap();
        assert_eq!(v["kind"], "modifier_only");
        assert_eq!(v["deviceModifiers"], 0x2000);
        assert_eq!(v["keyCode"], 49);
        assert_eq!((Shortcut::right_control().kind, Shortcut::right_control().modifiers, Shortcut::right_control().device_modifiers), (ShortcutKind::ModifierOnly, CONTROL, Some(0x2000)));
        assert_eq!((Shortcut::right_option().kind, Shortcut::right_option().modifiers, Shortcut::right_option().device_modifiers), (ShortcutKind::ModifierOnly, OPTION, Some(0x40)));
        assert_eq!(Shortcut::fn_globe(), Shortcut::default());
    }
}
