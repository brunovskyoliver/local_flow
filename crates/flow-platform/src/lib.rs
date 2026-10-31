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

pub use raw_window_handle::HasWindowHandle;

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

/// How a captured field takes text: a direct Accessibility write or a pasted Command-V.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InsertDelivery {
    Accessibility,
    Paste,
}

/// The field the user picked for an explicit insertion (Swift's `CapturedTarget`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CapturedTarget {
    pub bundle_id: String,
    pub own_process: bool,
    pub delivery: InsertDelivery,
    pub selection_location: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InsertOutcome {
    Confirmed,
    NotInserted,
    Uncertain,
}

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
    /// The input devices, or `None` where this platform has no catalog yet.
    fn input_catalog(&self) -> Option<InputCatalog> {
        None
    }
    /// `ProcessInfo.physicalMemory`; 0 where unknown, which fits no local model.
    fn physical_memory(&self) -> u64 {
        0
    }
    /// The system prompt for a permission. Without it the view opens Settings or reports this.
    /// Recording, transcription, diarization, identification, enrollment, summary generation,
    /// playback and the save panel run in the Mac app's workers. `what` names the action.
    fn meeting_worker(&self, what: &'static str) -> Result<(), Unavailable> {
        Err(Unavailable(what))
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
    /// Installs the global shortcut tap; saved only if this succeeds (Feature 025).
    fn install_shortcut(&self, _shortcut_json: &str) -> Result<(), Unavailable> {
        Err(Unavailable("the dictation shortcut"))
    }
    /// Starts the key capture for Record shortcut (Feature 025).
    fn record_shortcut(&self) -> Result<(), Unavailable> {
        Err(Unavailable("shortcut recording"))
    }
    /// `performSetting(.load)` before the first test dictation (Feature 025).
    fn load_speech_model(&self) -> Result<(), Unavailable> {
        Err(Unavailable("speech model loading"))
    }
    /// `GET /v1/remote/identity`: the fingerprint to compare (Feature 026).
    fn fetch_server_identity(&self, _origin: &str) -> Result<String, Unavailable> {
        Err(Unavailable("server identity"))
    }
    /// Secure Enclave key, channel-bound sign-in and enrollment; returns the new `remote.state`.
    fn enroll_device(&self, _provider: &str) -> Result<String, Unavailable> {
        Err(Unavailable("server sign-in"))
    }
    /// Rewrite and analysis health. Ok is (server name, backend model, analysis status).
    fn rewrite_health(&self, _endpoint: &str) -> Result<(Option<String>, Option<String>, String), Unavailable> {
        Err(Unavailable("rewrite health"))
    }
    /// Info.plist `LocalFlowGoogleClientID` is set.
    fn google_sign_in_available(&self) -> bool {
        false
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
    /// Save panel for a kept recording; `Ok(None)` when the user cancels.
    fn choose_save_path(&self, _default_name: &str) -> Result<Option<PathBuf>, Unavailable> {
        Err(Unavailable("save panel"))
    }
}

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
mod region_mac;
#[cfg(target_os = "windows")]
mod windows;

pub fn native() -> Box<dyn Services> {
    #[cfg(target_os = "macos")]
    return Box::new(macos::Mac);
    #[cfg(target_os = "windows")]
    return Box::new(windows::Win);
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    panic!("LocalFlow supports macOS and Windows");
}

/// A scriptable double for tests and the audit's scenarios.
pub struct Fake {
    pub device: &'static str,
    /// Records `animate_panel_frame` as (width, duration, curve). None stays `Unavailable`.
    pub panel_frames: Option<std::rc::Rc<std::cell::RefCell<Vec<(f32, f32, [f32; 4])>>>>,
    pub permissions: std::cell::RefCell<Vec<(Permission, PermissionState)>>,
    pub login: std::cell::Cell<bool>,
    pub dir: PathBuf,
    pub target: std::cell::RefCell<Option<CapturedTarget>>,
    pub insert_outcome: std::cell::Cell<Option<InsertOutcome>>,
    /// `session_command` succeeds and is recorded when true; otherwise `Unavailable`.
    pub session_ok: std::cell::Cell<bool>,
    pub commands: std::rc::Rc<std::cell::RefCell<Vec<SessionCommand>>>,
    pub announced: std::rc::Rc<std::cell::RefCell<Vec<String>>>,
}

impl Default for Fake {
    fn default() -> Self {
        Fake { device: "Mac", panel_frames: None, permissions: Default::default(), login: Default::default(), dir: std::env::temp_dir(), target: Default::default(), insert_outcome: Default::default(), session_ok: Default::default(), commands: Default::default(), announced: Default::default() }
    }
}

impl Services for Fake {
    fn name(&self) -> &'static str {
        "fake"
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
    fn secret(&self, _: &str) -> Result<Option<String>, Unavailable> {
        Ok(None)
    }
    fn set_secret(&self, _: &str, _: &str) -> Result<(), Unavailable> {
        Ok(())
    }
    fn physical_memory(&self) -> u64 {
        16 << 30
    }
    fn announce(&self, message: &str) -> Result<(), Unavailable> {
        self.announced.borrow_mut().push(message.into());
        Ok(())
    }
    fn capture_insertion_target(&self) -> Result<Option<CapturedTarget>, Unavailable> {
        Ok(self.target.borrow().clone())
    }
    fn insert_once(&self, _: &CapturedTarget, _: &str) -> Result<InsertOutcome, Unavailable> {
        self.insert_outcome.get().ok_or(Unavailable("text insertion"))
    }
    fn session_command(&self, command: SessionCommand) -> Result<(), Unavailable> {
        if !self.session_ok.get() {
            return Err(Unavailable("dictation session"));
        }
        self.commands.borrow_mut().push(command);
        Ok(())
    }
}
