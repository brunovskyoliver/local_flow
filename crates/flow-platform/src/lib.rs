//! What macOS and Windows differ on. Anything not built yet returns `Unavailable`, which views
//! must show as such, never as success (FR-007).
use std::path::PathBuf;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Permission {
    Microphone,
    SystemAudio,
    Accessibility,
    InputMonitoring,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PermissionState {
    NotAsked,
    Granted,
    Denied,
    /// This platform has no such permission.
    NotRequired,
}

#[derive(Debug, PartialEq, Eq, Clone)]
pub struct Unavailable(pub &'static str);

pub const INPUT_MONITORING_REQUIRED: Unavailable = Unavailable("Input Monitoring for the shortcut");
pub const ACCESSIBILITY_REQUIRED: Unavailable = Unavailable("Accessibility for the shortcut");
pub const INVALID_SHORTCUT: Unavailable = Unavailable("that shortcut");
pub const SHORTCUT_NOT_STARTED: Unavailable = Unavailable("the shortcut tap");

/// `DictationErrorMessage` for `ShortcutController.Failure`. `None` for anything else.
pub fn shortcut_failure(e: &Unavailable) -> Option<&'static str> {
    Some(match e {
        e if *e == INPUT_MONITORING_REQUIRED => "Allow Input Monitoring to use the dictation shortcut.",
        e if *e == ACCESSIBILITY_REQUIRED => "Allow Accessibility to record and prioritize shortcuts.",
        e if *e == INVALID_SHORTCUT => "That shortcut is unavailable. Try another key combination.",
        e if *e == SHORTCUT_NOT_STARTED => "The keyboard shortcut could not start. Check permissions and try again.",
        _ => return None,
    })
}

pub use raw_window_handle::HasWindowHandle;

/// A schema `failure_reason`.
pub type AudioFailure = &'static str;

/// One capture packet: 48 kHz, 16-bit, interleaved stereo.
pub struct AudioPacket<'a> {
    pub stereo: &'a [i16],
    /// When the first sample was captured, on the host clock.
    pub qpc_ns: Option<u64>,
    pub silent: bool,
    /// The device says it lost audio before this packet.
    pub discontinuity: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AudioEvent {
    Failed(AudioFailure),
    DeviceChanged,
}

pub trait AudioStream: Send {
    fn device_name(&self) -> Option<String>;
    /// Returns once no callback can run.
    fn stop(self: Box<Self>);
}

/// Raw AAC-LC out. Not `Send`: it stays on the thread that asked for it.
pub trait AudioEncoder {
    fn encode(&mut self, pcm: &[i16], out: &mut dyn FnMut(&[u8]) -> Result<(), AudioFailure>) -> Result<(), AudioFailure>;
    fn drain(&mut self, out: &mut dyn FnMut(&[u8]) -> Result<(), AudioFailure>) -> Result<(), AudioFailure>;
}

/// Meeting capture and encoding on platforms that have the Rust recorder.
pub trait MeetingAudio: Send + Sync {
    /// Why recording can't start on this machine.
    fn unavailable(&self) -> Option<&'static str>;
    /// `system` picks what the computer plays; otherwise the default microphone.
    fn start(&self, system: bool, on_packet: Box<dyn FnMut(AudioPacket) + Send>, on_event: Box<dyn Fn(AudioEvent) + Send>) -> Result<Box<dyn AudioStream>, AudioFailure>;
    fn encoder(&self, channels: usize, bitrate: i64) -> Result<Box<dyn AudioEncoder>, AudioFailure>;
    fn bitrate(&self, system: bool) -> i64;
}

/// A connected audio input (Swift's `ConnectedInput`). Read-only: nothing here opens the device.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InputDevice {
    pub device_id: u32,
    pub uid: String,
    pub model_uid: Option<String>,
    pub name: String,
    /// `builtIn`, `usb`, `bluetooth`, `iPhone`, `virtual` or `other`.
    pub kind: &'static str,
    pub alive: bool,
}

/// Swift's `InputDeviceSnapshot`, first 64 inputs.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct InputCatalog {
    pub devices: Vec<InputDevice>,
    pub default_input: Option<u32>,
    pub clamshell: bool,
}

pub use flow_core::dictation::session::{CapturedTarget, InsertDelivery, InsertOutcome};

/// Commands to the dictation session and meeting coordinator, built with capture in a later feature.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionCommand {
    RetryStorage,
    RetrySave,
    CancelDictation,
    CancelRewrite,
    PauseMeeting,
    ResumeMeeting,
    StopMeeting,
    StartMeeting,
    RetryRewrite,
    UndoLearned,
    RestoreLearned,
}

/// OS services a view calls. Tests use `Fake`.
/// Region formats as plain functions, so `flow-core` can call them without knowing `Services`.
#[derive(Clone, Copy)]
pub struct Formats {
    /// (milliseconds, template such as "dMMM" or "short-time", read the fields as UTC).
    pub date: fn(i64, &str, bool) -> Option<String>,
    /// (value, exact fraction digits).
    pub number: fn(f64, u8) -> Option<String>,
    /// 1 is Sunday, as in `Calendar.firstWeekday`.
    pub first_weekday: i64,
}

pub trait Services: 'static {
    fn name(&self) -> &'static str;
    /// "Mac" or "PC" in copy that says "this Mac".
    fn device_word(&self) -> &'static str;
    fn app_data_dir(&self) -> PathBuf;
    /// This client's folder there. On the Mac, not the Swift app's until the cutover (Feature 028).
    fn data_folder(&self) -> &'static str {
        "LocalFlow GPUI Dev"
    }
    /// The Swift app's folder there, on the one platform that has it.
    fn swift_data_folder(&self) -> Option<&'static str> {
        None
    }
    /// The Swift app's settings, as JSON values.
    fn swift_prefs(&self) -> Option<serde_json::Map<String, serde_json::Value>> {
        None
    }
    fn permission(&self, p: Permission) -> PermissionState;
    fn open_permission_settings(&self, p: Permission) -> Result<(), Unavailable>;
    fn high_contrast(&self) -> bool;
    fn reduce_motion(&self) -> bool;
    fn launch_at_login(&self) -> Result<bool, Unavailable>;
    fn set_launch_at_login(&self, on: bool) -> Result<(), Unavailable>;
    fn free_disk_bytes(&self) -> Option<u64>;
    fn secret(&self, name: &str) -> Result<Option<String>, Unavailable>;
    fn set_secret(&self, name: &str, value: &str) -> Result<(), Unavailable>;
    fn remove_secret(&self, _name: &str) -> Result<(), Unavailable> {
        Err(Unavailable("Keychain"))
    }
    /// The item's bytes: `server-key` and `device-key` aren't text. `secret` is for those that are.
    fn secret_data(&self, name: &str) -> Result<Option<Vec<u8>>, Unavailable> {
        Ok(self.secret(name)?.map(String::into_bytes))
    }
    fn set_secret_data(&self, name: &str, value: &[u8]) -> Result<(), Unavailable> {
        self.set_secret(name, std::str::from_utf8(value).map_err(|_| Unavailable("binary secrets"))?)
    }
    /// A new non-exportable P-256 key as (handle, public key). The key is X9.63 or a
    /// `BCRYPT_ECCPUBLIC_BLOB`; `flow_core::remote::x963_public_key` takes either. No software fallback.
    fn device_key_create(&self) -> Result<(Vec<u8>, Vec<u8>), Unavailable> {
        Err(Unavailable("device key"))
    }
    /// `None` when the handle no longer loads. Same forms as `device_key_create`.
    fn device_key_public_key(&self, _handle: &[u8]) -> Option<Vec<u8>> {
        None
    }
    /// Raw r||s over the SHA-256 of `message`; `flow_core::remote::raw_signature_to_der` converts it.
    fn device_key_sign(&self, _handle: &[u8], _message: &[u8]) -> Result<Vec<u8>, Unavailable> {
        Err(Unavailable("device key"))
    }
    fn device_key_delete(&self, _handle: &[u8]) -> Result<(), Unavailable> {
        Err(Unavailable("device key"))
    }
    /// Whether an item exists, without reading its value. The Keychain then can't prompt for it, so
    /// this is what polling uses.
    fn secret_exists(&self, name: &str) -> Result<bool, Unavailable> {
        Ok(self.secret_data(name)?.is_some())
    }
    /// The same store and keys for background threads. None here unless a platform has them.
    fn credentials(&self) -> std::sync::Arc<dyn Credentials> {
        std::sync::Arc::new(NoCredentials)
    }
    /// Opens a web address in the browser.
    fn open_url(&self, _url: &str) -> Result<(), Unavailable> {
        Err(Unavailable("opening a link"))
    }
    /// A Settings model or updater action (`SettingsViewModel.Action`), Features 025 and 026.
    fn settings_action(&self, action: &str) -> Result<(), Unavailable> {
        let _ = action;
        Err(Unavailable("model services"))
    }
    /// Regular running apps as (name, bundle ID), for the context sheets.
    fn running_apps(&self) -> Vec<(String, String)> {
        vec![]
    }
    /// An installed app's display name without ".app", from its bundle ID. `None` when it isn't installed.
    fn app_name(&self, _bundle_id: &str) -> Option<String> {
        None
    }
    /// An installed app's icon as PNG bytes, from its bundle ID.
    fn app_icon_png(&self, _bundle_id: &str) -> Option<Vec<u8>> {
        None
    }
    /// What starts the speech worker for `flow_core::dictation::lifecycle`; `None` when it isn't installed.
    fn speech_launcher(&self, _models: &std::path::Path) -> Option<Box<dyn flow_core::dictation::lifecycle::Launcher>> {
        None
    }
    /// The speech model install in progress as (completed, total, verifying), once the model
    /// provisioner has one. `settings_action("download")` returns at once and this takes over.
    fn speech_install(&self) -> Option<(u64, u64, bool)> {
        match self.install_state(ModelPack::Speech) {
            InstallState::Running(completed, total, verifying) => Some((completed, total, verifying)),
            _ => None,
        }
    }
    /// A pack's install: running, finished, or what stopped it.
    fn install_state(&self, _pack: ModelPack) -> InstallState {
        InstallState::Idle
    }
    /// What the on-device AI installer reports after `install_local_ai` said `Ok`.
    fn local_ai_phase(&self) -> Option<flow_core::onboarding::AiPhase> {
        None
    }
    /// The dictation microphone. None here means no dictation; a test double never opens one.
    fn microphone(&self) -> Option<std::sync::Arc<dyn flow_core::dictation::session::Mic>> {
        None
    }
    /// The field and clipboard side of a dictation, for the session's thread.
    fn inserter(&self) -> Option<std::sync::Arc<dyn flow_core::dictation::session::Inserter>> {
        None
    }
    /// `free_disk_bytes` for the session's thread.
    fn free_bytes_probe(&self) -> Box<dyn Fn() -> Option<u64> + Send> {
        Box::new(|| None)
    }
    /// The input devices, or `None` where this platform has no catalog yet.
    fn input_catalog(&self) -> Option<InputCatalog> {
        None
    }
    /// Gives a button of the alert now on screen `role: .destructive`. False while it isn't up yet.
    fn mark_alert_button_destructive(&self, title: &str) -> bool {
        let _ = title;
        true
    }
    /// `ProcessInfo.physicalMemory`; 0 where unknown, which fits no local model.
    fn physical_memory(&self) -> u64 {
        0
    }
    /// The system prompt for a permission. Without it the view opens Settings or reports this.
    /// Recording, transcription, diarization, identification, enrollment,
    /// playback and the save panel run in the Mac app's workers. `what` names the action.
    fn meeting_worker(&self, what: &'static str) -> Result<(), Unavailable> {
        Err(Unavailable(what))
    }
    /// The Rust recorder's sources. None means the page keeps using `meeting_worker`, as on the Mac,
    /// where the Swift app records until the cutover.
    fn meeting_audio(&self) -> Option<std::sync::Arc<dyn MeetingAudio>> {
        None
    }
    fn request_permission(&self, _p: Permission) -> Result<PermissionState, Unavailable> {
        Err(Unavailable("the permission prompt"))
    }
    /// Starts the first-run speech model install (Feature 025).
    fn install_speech_model(&self) -> Result<(), Unavailable> {
        Err(Unavailable("speech model install"))
    }
    /// Starts Whisper, speaker labels and the term booster (Feature 025).
    fn install_meeting_models(&self) -> Result<(), Unavailable> {
        Err(Unavailable("meeting model install"))
    }
    /// Starts MTPLX and the chosen model pack (Feature 026).
    fn install_local_ai(&self, _model_id: &str) -> Result<(), Unavailable> {
        Err(Unavailable("on-device AI install"))
    }
    fn background_services_enabled(&self) -> bool {
        false
    }
    /// What the recorder started by `record_shortcut` finished with: `None` while it runs,
    /// `Some(None)` when it ended with nothing, otherwise the shortcut as JSON.
    fn take_recorded_shortcut(&self) -> Option<Option<String>> {
        None
    }
    /// Installs the global shortcut tap; saved only if this succeeds (Feature 025).
    fn install_shortcut(&self, _shortcut_json: &str) -> Result<(), Unavailable> {
        Err(Unavailable("the dictation shortcut"))
    }
    /// Starts the key capture for Record shortcut (Feature 025).
    fn record_shortcut(&self) -> Result<(), Unavailable> {
        Err(Unavailable("shortcut recording"))
    }
    /// The record button's second press, or the page going away: drops the recorder, nothing is reported.
    fn stop_shortcut_recording(&self) {}
    /// Whether the installed shortcut can fire now (`ShortcutController.isAvailable`).
    fn shortcut_available(&self) -> bool {
        false
    }
    /// Presses, releases and cancels since the last call. Bounded when nobody reads them.
    fn take_shortcut_events(&self) -> Vec<flow_core::dictation::hotkey::Event> {
        Vec::new()
    }
    /// Escape stays armed from a press until the dictation session ends.
    fn set_shortcut_session_active(&self, _active: bool) {}
    /// False on a device with no Globe key: no preset, and Right Control is the default.
    fn has_globe_key(&self) -> bool {
        true
    }
    /// `performSetting(.load)` before the first test dictation (Feature 025).
    fn load_speech_model(&self) -> Result<(), Unavailable> {
        Err(Unavailable("speech model loading"))
    }
    /// `NSApp.appearance`: `None` follows the system. Native sheets and alerts read it.
    fn set_app_appearance(&self, _dark: Option<bool>) -> Result<(), Unavailable> {
        Ok(())
    }
    /// Shows the app in the file manager, for adding it to a permission list by hand.
    fn reveal_app(&self) -> Result<(), Unavailable> {
        Err(Unavailable("revealing the app"))
    }
    /// The term booster, installed silently after the speech model (`installBoostModel`).
    fn install_term_booster(&self) -> Result<(), Unavailable> {
        Err(Unavailable("term booster install"))
    }
    /// The launch model check: a verified install's marker.
    fn speech_model_verified(&self) -> bool {
        false
    }
    /// `NSWindow.identifier`.
    fn set_window_identifier(&self, _window: &dyn HasWindowHandle, _identifier: &str) -> Result<(), Unavailable> {
        Err(Unavailable("window identifiers"))
    }
    /// Starts or stops the Swift app's local rewrite model service, if setup registered it there.
    fn set_local_model_running(&self, _running: bool) {}
    /// The frontmost app's process, when the app declares a games category.
    fn frontmost_game(&self) -> Option<i32> {
        None
    }
    /// Memory pressure since the last call.
    fn take_memory_pressure(&self) -> bool {
        false
    }
    fn process_running(&self, _pid: i32) -> bool {
        false
    }
    /// A panel that floats and never becomes key or main, Swift's `level = .floating` and `canBecomeKey` false.
    fn pin_panel(&self, _window: &dyn HasWindowHandle) -> Result<(), Unavailable> {
        Err(Unavailable("panel window traits"))
    }
    /// `NSEvent.mouseLocation` in global coordinates from the primary display's top left, as GPUI's displays are.
    fn pointer_location(&self) -> Option<(f32, f32)> {
        None
    }
    /// `recorder.close`: false means the measurement export lost data.
    fn close_recorder(&self) -> bool {
        true
    }
    /// VoiceOver announcement that survives the pill hiding (Swift's `announcementRequested`).
    fn announce(&self, _message: &str) -> Result<(), Unavailable> {
        Err(Unavailable("accessibility announcements"))
    }
    /// The focused editable field in the frontmost app; `None` when there's no supported field.
    fn capture_insertion_target(&self) -> Result<Option<CapturedTarget>, Unavailable> {
        Err(Unavailable("focused-field capture"))
    }
    fn insert_once(&self, _target: &CapturedTarget, _text: &str) -> Result<InsertOutcome, Unavailable> {
        Err(Unavailable("text insertion"))
    }
    fn session_command(&self, _command: SessionCommand) -> Result<(), Unavailable> {
        Err(Unavailable("dictation session"))
    }
    fn can_check_for_updates(&self) -> bool {
        false
    }
    fn check_for_updates(&self) -> Result<(), Unavailable> {
        Err(Unavailable("Sparkle"))
    }
    /// Animates a window to `x` and `width`, keeping its y and height, over `duration` seconds on the
    /// cubic Bezier `curve` (Swift's `animator().setFrame`). Main thread only.
    fn animate_panel_frame(&self, _window: &dyn raw_window_handle::HasWindowHandle, _x: f32, _width: f32, _duration: f32, _curve: [f32; 4]) -> Result<(), Unavailable> {
        Err(Unavailable("animated window frames"))
    }
    /// The current locale's decimal separator, which `.formatted()` and `ByteCountFormatter` use.
    fn decimal_separator(&self) -> char {
        '.'
    }
    /// The system locale's formats; `None` where they aren't read yet.
    fn formats(&self) -> Option<Formats> {
        None
    }
    /// `NSWorkspace.isVoiceOverEnabled`: rows keep their actions in the accessibility tree.
    fn voice_over_on(&self) -> bool {
        false
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum ModelPack {
    Speech,
    Meeting,
    Booster,
}

#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub enum InstallState {
    #[default]
    Idle,
    /// completed, total, verifying.
    Running(u64, u64, bool),
    Verified,
    /// The worker's reason.
    Failed(String),
}

pub mod speech;
#[cfg(target_os = "macos")]
mod local_ai;
#[cfg(target_os = "macos")]
mod swift_prefs;
#[cfg(target_os = "macos")]
mod hotkey_mac;
#[cfg(target_os = "macos")]
mod keychain_mac;
#[cfg(target_os = "macos")]
mod keys_mac;
#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
mod insert_mac;
#[cfg(target_os = "macos")]
mod mic_mac;
#[cfg(target_os = "macos")]
mod region_mac;
#[cfg(target_os = "windows")]
mod win {
    pub mod aac;
    pub mod hotkey;
    pub mod insert;
    pub mod mic;
    pub mod secrets;
    pub mod system;
    pub mod tpm;
    pub mod wasapi;
}
#[cfg(target_os = "windows")]
mod windows;
#[cfg(any(target_os = "windows", test))]
mod win_rules;

/// `InputDeviceResolver.candidates` against a catalog read at this key-down.
pub fn ranked_candidates(entries: &[flow_core::settings::InputEntry], catalog: &InputCatalog) -> Vec<flow_core::dictation::session::Candidate> {
    let inputs: Vec<flow_core::settings::ConnectedInput> = catalog.devices.iter().map(|d| flow_core::settings::ConnectedInput { device_id: d.device_id, uid: d.uid.clone(), model_uid: d.model_uid.clone(), name: d.name.clone(), kind: d.kind.into(), alive: d.alive }).collect();
    flow_core::settings::input_candidates(entries, &inputs, catalog.default_input, catalog.clamshell)
}

pub fn native() -> Box<dyn Services> {
    #[cfg(target_os = "macos")]
    return Box::new(macos::Mac);
    #[cfg(target_os = "windows")]
    return Box::new(windows::Win);
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    panic!("LocalFlow supports macOS and Windows");
}

/// The key a `Fake` hands out. Its signature is whatever the test scripts.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FakeDeviceKey {
    pub handle: Vec<u8>,
    pub public_key: Vec<u8>,
    pub raw_signature: Vec<u8>,
}

/// Secrets and device keys for remote enrollment, which runs off the UI thread. Same contracts as the
/// `Services` methods of the same names.
pub trait Credentials: Send + Sync {
    fn secret_data(&self, name: &str) -> Result<Option<Vec<u8>>, Unavailable>;
    fn set_secret_data(&self, name: &str, value: &[u8]) -> Result<(), Unavailable>;
    fn remove_secret(&self, name: &str) -> Result<(), Unavailable>;
    fn device_key_create(&self) -> Result<(Vec<u8>, Vec<u8>), Unavailable>;
    fn device_key_public_key(&self, handle: &[u8]) -> Option<Vec<u8>>;
    fn device_key_sign(&self, handle: &[u8], message: &[u8]) -> Result<Vec<u8>, Unavailable>;
    fn device_key_delete(&self, handle: &[u8]) -> Result<(), Unavailable>;
    /// `Services::open_url`, for background threads.
    fn open_url(&self, _url: &str) -> Result<(), Unavailable> {
        Err(Unavailable("opening a link"))
    }
    /// What the server's admin list shows for this device.
    fn device_name(&self) -> String {
        std::env::var("COMPUTERNAME").or_else(|_| std::env::var("HOSTNAME")).unwrap_or_else(|_| "LocalFlow".into())
    }
}

pub struct NoCredentials;
impl Credentials for NoCredentials {
    fn secret_data(&self, _: &str) -> Result<Option<Vec<u8>>, Unavailable> {
        Err(Unavailable("Keychain"))
    }
    fn set_secret_data(&self, _: &str, _: &[u8]) -> Result<(), Unavailable> {
        Err(Unavailable("Keychain"))
    }
    fn remove_secret(&self, _: &str) -> Result<(), Unavailable> {
        Err(Unavailable("Keychain"))
    }
    fn device_key_create(&self) -> Result<(Vec<u8>, Vec<u8>), Unavailable> {
        Err(Unavailable("device key"))
    }
    fn device_key_public_key(&self, _: &[u8]) -> Option<Vec<u8>> {
        None
    }
    fn device_key_sign(&self, _: &[u8], _: &[u8]) -> Result<Vec<u8>, Unavailable> {
        Err(Unavailable("device key"))
    }
    fn device_key_delete(&self, _: &[u8]) -> Result<(), Unavailable> {
        Err(Unavailable("device key"))
    }
}

/// A scriptable double for tests and the audit's scenarios.
pub struct Fake {
    /// What `meeting_audio` hands out.
    pub audio: Option<std::sync::Arc<dyn MeetingAudio>>,
    /// Secrets by full name. Any call fails while `secrets_fail` is true.
    pub secrets: std::rc::Rc<std::cell::RefCell<std::collections::BTreeMap<String, Vec<u8>>>>,
    pub secrets_fail: std::cell::Cell<bool>,
    /// `device_key_create` hands out the next one; none left is `Unavailable`, like a missing TPM.
    pub device_keys: std::rc::Rc<std::cell::RefCell<std::collections::VecDeque<FakeDeviceKey>>>,
    pub live_device_keys: std::cell::RefCell<Vec<FakeDeviceKey>>,
    pub device: &'static str,
    /// Records `animate_panel_frame` as (width, duration, curve). None stays `Unavailable`.
    pub panel_frames: Option<std::rc::Rc<std::cell::RefCell<Vec<(f32, f32, [f32; 4])>>>>,
    /// Counts `pin_panel` calls.
    pub pinned_panels: std::rc::Rc<std::cell::Cell<usize>>,
    pub pointer: std::cell::Cell<Option<(f32, f32)>>,
    pub permissions: std::cell::RefCell<Vec<(Permission, PermissionState)>>,
    pub login: std::cell::Cell<bool>,
    pub dir: PathBuf,
    pub target: std::cell::RefCell<Option<CapturedTarget>>,
    pub insert_outcome: std::cell::Cell<Option<InsertOutcome>>,
    /// `session_command` succeeds and is recorded when true; otherwise `Unavailable`.
    pub session_ok: std::cell::Cell<bool>,
    pub commands: std::rc::Rc<std::cell::RefCell<Vec<SessionCommand>>>,
    pub announced: std::rc::Rc<std::cell::RefCell<Vec<String>>>,
    pub app_names: std::cell::RefCell<std::collections::BTreeMap<String, String>>,
    pub model_verified: std::cell::Cell<bool>,
    pub install_states: std::cell::RefCell<std::collections::BTreeMap<ModelPack, InstallState>>,
    pub ai_phase: std::cell::RefCell<Option<flow_core::onboarding::AiPhase>>,
    pub export_incomplete: std::cell::Cell<bool>,
    pub identifiers: std::rc::Rc<std::cell::RefCell<Vec<String>>>,
    pub appearances: std::rc::Rc<std::cell::RefCell<Vec<Option<bool>>>>,
    pub inserter: Option<std::sync::Arc<dyn flow_core::dictation::session::Inserter>>,
}

impl Default for Fake {
    fn default() -> Self {
        Fake {
            audio: None, app_names: Default::default(), secrets: Default::default(), secrets_fail: Default::default(), device_keys: Default::default(), live_device_keys: Default::default(), device: "Mac", panel_frames: None, pinned_panels: Default::default(), pointer: Default::default(), permissions: Default::default(), login: Default::default(), dir: std::env::temp_dir(), target: Default::default(), insert_outcome: Default::default(), session_ok: Default::default(), commands: Default::default(), announced: Default::default(), model_verified: Default::default(), install_states: Default::default(), ai_phase: Default::default(), export_incomplete: Default::default(), identifiers: Default::default(), appearances: Default::default(), inserter: None }
    }
}

impl Fake {
    fn fake_secrets(&self) -> Result<std::cell::RefMut<'_, std::collections::BTreeMap<String, Vec<u8>>>, Unavailable> {
        if self.secrets_fail.get() { Err(Unavailable("Keychain")) } else { Ok(self.secrets.borrow_mut()) }
    }
}

impl Services for Fake {
    fn name(&self) -> &'static str {
        "fake"
    }
    fn speech_model_verified(&self) -> bool {
        self.model_verified.get()
    }
    fn install_state(&self, pack: ModelPack) -> InstallState {
        self.install_states.borrow().get(&pack).cloned().unwrap_or_default()
    }
    fn local_ai_phase(&self) -> Option<flow_core::onboarding::AiPhase> {
        self.ai_phase.borrow().clone()
    }
    fn pin_panel(&self, _: &dyn HasWindowHandle) -> Result<(), Unavailable> {
        self.pinned_panels.set(self.pinned_panels.get() + 1);
        Ok(())
    }
    fn pointer_location(&self) -> Option<(f32, f32)> {
        self.pointer.get()
    }
    fn set_window_identifier(&self, _: &dyn HasWindowHandle, identifier: &str) -> Result<(), Unavailable> {
        self.identifiers.borrow_mut().push(identifier.into());
        Ok(())
    }
    fn close_recorder(&self) -> bool {
        !self.export_incomplete.get()
    }
    fn set_app_appearance(&self, dark: Option<bool>) -> Result<(), Unavailable> {
        self.appearances.borrow_mut().push(dark);
        Ok(())
    }
    fn animate_panel_frame(&self, _: &dyn HasWindowHandle, _: f32, width: f32, duration: f32, curve: [f32; 4]) -> Result<(), Unavailable> {
        let frames = self.panel_frames.as_ref().ok_or(Unavailable("animated window frames"))?;
        frames.borrow_mut().push((width, duration, curve));
        Ok(())
    }
    fn device_word(&self) -> &'static str {
        self.device
    }
    fn app_data_dir(&self) -> PathBuf {
        self.dir.clone()
    }
    fn permission(&self, p: Permission) -> PermissionState {
        self.permissions.borrow().iter().find(|(k, _)| *k == p).map(|(_, v)| *v).unwrap_or(PermissionState::NotAsked)
    }
    fn open_permission_settings(&self, _: Permission) -> Result<(), Unavailable> {
        Ok(())
    }
    fn high_contrast(&self) -> bool {
        false
    }
    fn reduce_motion(&self) -> bool {
        false
    }
    fn launch_at_login(&self) -> Result<bool, Unavailable> {
        Ok(self.login.get())
    }
    fn set_launch_at_login(&self, on: bool) -> Result<(), Unavailable> {
        self.login.set(on);
        Ok(())
    }
    fn free_disk_bytes(&self) -> Option<u64> {
        Some(100 << 30)
    }
    fn secret(&self, name: &str) -> Result<Option<String>, Unavailable> {
        self.secret_data(name)?.map(|v| String::from_utf8(v).map_err(|_| Unavailable("Keychain"))).transpose()
    }
    fn set_secret(&self, name: &str, value: &str) -> Result<(), Unavailable> {
        self.set_secret_data(name, value.as_bytes())
    }
    fn remove_secret(&self, name: &str) -> Result<(), Unavailable> {
        self.fake_secrets()?.remove(name);
        Ok(())
    }
    fn secret_data(&self, name: &str) -> Result<Option<Vec<u8>>, Unavailable> {
        Ok(self.fake_secrets()?.get(name).cloned())
    }
    fn set_secret_data(&self, name: &str, value: &[u8]) -> Result<(), Unavailable> {
        self.fake_secrets()?.insert(name.into(), value.to_vec());
        Ok(())
    }
    fn device_key_create(&self) -> Result<(Vec<u8>, Vec<u8>), Unavailable> {
        let key = self.device_keys.borrow_mut().pop_front().ok_or(Unavailable("device key"))?;
        let made = (key.handle.clone(), key.public_key.clone());
        self.live_device_keys.borrow_mut().push(key);
        Ok(made)
    }
    fn device_key_public_key(&self, handle: &[u8]) -> Option<Vec<u8>> {
        self.live_device_keys.borrow().iter().find(|k| k.handle == handle).map(|k| k.public_key.clone())
    }
    fn device_key_sign(&self, handle: &[u8], _: &[u8]) -> Result<Vec<u8>, Unavailable> {
        self.live_device_keys.borrow().iter().find(|k| k.handle == handle).map(|k| k.raw_signature.clone()).ok_or(Unavailable("device key"))
    }
    fn device_key_delete(&self, handle: &[u8]) -> Result<(), Unavailable> {
        self.live_device_keys.borrow_mut().retain(|k| k.handle != handle);
        Ok(())
    }
    fn physical_memory(&self) -> u64 {
        16 << 30
    }
    fn app_name(&self, bundle_id: &str) -> Option<String> {
        self.app_names.borrow().get(bundle_id).cloned()
    }
    fn announce(&self, message: &str) -> Result<(), Unavailable> {
        self.announced.borrow_mut().push(message.into());
        Ok(())
    }
    fn capture_insertion_target(&self) -> Result<Option<CapturedTarget>, Unavailable> {
        Ok(self.target.borrow().clone())
    }
    fn inserter(&self) -> Option<std::sync::Arc<dyn flow_core::dictation::session::Inserter>> {
        self.inserter.clone()
    }
    fn insert_once(&self, _: &CapturedTarget, _: &str) -> Result<InsertOutcome, Unavailable> {
        self.insert_outcome.get().ok_or(Unavailable("text insertion"))
    }
    fn meeting_audio(&self) -> Option<std::sync::Arc<dyn MeetingAudio>> {
        self.audio.clone()
    }
    fn session_command(&self, command: SessionCommand) -> Result<(), Unavailable> {
        if !self.session_ok.get() {
            return Err(Unavailable("dictation session"));
        }
        self.commands.borrow_mut().push(command);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fake_scripts_secrets_and_keys() {
        let fake = Fake::default();
        assert_eq!(fake.secret("a/b"), Ok(None));
        fake.set_secret_data("a/b", &[0xff, 0]).unwrap();
        assert_eq!(fake.secret_data("a/b").unwrap().unwrap(), [0xff, 0]);
        assert!(fake.secret("a/b").is_err(), "binary isn't text");
        fake.set_secret("a/c", "text").unwrap();
        assert_eq!(fake.secret("a/c").unwrap().as_deref(), Some("text"));
        fake.remove_secret("a/b").unwrap();
        assert_eq!(fake.secret_data("a/b"), Ok(None));
        fake.secrets_fail.set(true);
        assert!(fake.secret("a/c").is_err());
        assert!(fake.set_secret("a/c", "x").is_err());

        assert!(fake.device_key_create().is_err(), "nothing scripted is a missing TPM");
        let key = FakeDeviceKey { handle: vec![1], public_key: vec![4; 65], raw_signature: vec![7; 64] };
        fake.device_keys.borrow_mut().push_back(key.clone());
        assert_eq!(fake.device_key_public_key(&key.handle), None, "not created yet");
        assert_eq!(fake.device_key_create(), Ok((key.handle.clone(), key.public_key.clone())));
        assert_eq!(fake.device_key_public_key(&key.handle), Some(key.public_key.clone()));
        assert_eq!(fake.device_key_sign(&key.handle, b"m"), Ok(key.raw_signature.clone()));
        fake.device_key_delete(&key.handle).unwrap();
        assert_eq!(fake.device_key_public_key(&key.handle), None);
        assert!(fake.device_key_sign(&key.handle, b"m").is_err());
    }
}
