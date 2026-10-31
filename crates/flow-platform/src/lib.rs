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

/// The Desktop-type Google client from the build: its ID and non-confidential secret. Empty is unset.
pub fn google_client() -> Option<(&'static str, Option<&'static str>)> {
    let id = option_env!("LOCALFLOW_GOOGLE_CLIENT_ID").filter(|v| !v.trim().is_empty())?;
    Some((id, option_env!("LOCALFLOW_GOOGLE_CLIENT_SECRET").filter(|v| !v.trim().is_empty())))
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
    /// The speech model install in progress as (completed, total, verifying), once the model
    /// provisioner has one. `settings_action("download")` returns at once and this takes over.
    fn speech_install(&self) -> Option<(u64, u64, bool)> {
        None
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
    /// `performSetting(.load)` before the first test dictation (Feature 025).
    fn load_speech_model(&self) -> Result<(), Unavailable> {
        Err(Unavailable("speech model loading"))
    }
    /// Rewrite and analysis health. Ok is (server name, backend model, analysis status).
    fn rewrite_health(&self, _endpoint: &str) -> Result<(Option<String>, Option<String>, String), Unavailable> {
        Err(Unavailable("rewrite health"))
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
    /// A Desktop-type Google client is built in; loopback sign-in works from it on both platforms.
    /// The Swift Mac app keeps its own iOS-type client and path until the cutover.
    fn google_sign_in_available(&self) -> bool {
        false
    }
    /// Sign in with Apple needs Apple's frameworks; not on Windows (ADR 0036).
    fn apple_sign_in_available(&self) -> bool {
        true
    }
    /// The launch model check. No model code until Feature 025, so nothing is verified yet.
    fn speech_model_verified(&self) -> bool {
        false
    }
    /// `NSWindow.identifier`.
    fn set_window_identifier(&self, _window: &dyn HasWindowHandle, _identifier: &str) -> Result<(), Unavailable> {
        Err(Unavailable("window identifiers"))
    }
    /// A panel that floats and never becomes key or main, Swift's `level = .floating` and `canBecomeKey` false.
    fn pin_panel(&self, _window: &dyn HasWindowHandle) -> Result<(), Unavailable> {
        Err(Unavailable("panel window traits"))
    }
    /// `NSEvent.mouseLocation` in global coordinates from the primary display's top left, as GPUI's displays are.
    fn pointer_location(&self) -> Option<(f32, f32)> {
        None
    }
    /// `lifecycle.shutdownIfIdle`: false refuses the quit.
    fn shutdown_models_if_idle(&self) -> bool {
        true
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
    /// Save panel for a kept recording; `Ok(None)` when the user cancels.
    fn choose_save_path(&self, _default_name: &str) -> Result<Option<PathBuf>, Unavailable> {
        Err(Unavailable("save panel"))
    }
}

#[cfg(target_os = "macos")]
mod keychain_mac;
#[cfg(target_os = "macos")]
mod keys_mac;
#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
mod region_mac;
#[cfg(target_os = "windows")]
mod win {
    pub mod secrets;
    pub mod system;
    pub mod tpm;
}
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
    /// An ID token from Apple, carrying `nonce`. It needs a signed app. Google's goes through `open_url`.
    fn sign_in(&self, _provider: &str, _nonce: &str) -> Result<String, Unavailable> {
        Err(Unavailable("server sign-in"))
    }
    /// `Services::open_url`, for background threads.
    fn open_url(&self, _url: &str) -> Result<(), Unavailable> {
        Err(Unavailable("opening a link"))
    }
    /// What the server's admin list shows for this device.
    fn device_name(&self) -> String {
        std::env::var("COMPUTERNAME").or_else(|_| std::env::var("HOSTNAME")).unwrap_or_else(|_| "LocalFlow".into())
    }
}

struct NoCredentials;
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
    pub model_verified: std::cell::Cell<bool>,
    pub models_busy: std::cell::Cell<bool>,
    pub export_incomplete: std::cell::Cell<bool>,
    pub identifiers: std::rc::Rc<std::cell::RefCell<Vec<String>>>,
    pub appearances: std::rc::Rc<std::cell::RefCell<Vec<Option<bool>>>>,
    pub save_prompts: std::rc::Rc<std::cell::RefCell<Vec<String>>>,
}

impl Default for Fake {
    fn default() -> Self {
        Fake { secrets: Default::default(), secrets_fail: Default::default(), device_keys: Default::default(), live_device_keys: Default::default(), device: "Mac", panel_frames: None, pinned_panels: Default::default(), pointer: Default::default(), permissions: Default::default(), login: Default::default(), dir: std::env::temp_dir(), target: Default::default(), insert_outcome: Default::default(), session_ok: Default::default(), commands: Default::default(), announced: Default::default(), model_verified: Default::default(), models_busy: Default::default(), export_incomplete: Default::default(), identifiers: Default::default(), appearances: Default::default(), save_prompts: Default::default() }
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
    fn shutdown_models_if_idle(&self) -> bool {
        !self.models_busy.get()
    }
    fn close_recorder(&self) -> bool {
        !self.export_incomplete.get()
    }
    fn set_app_appearance(&self, dark: Option<bool>) -> Result<(), Unavailable> {
        self.appearances.borrow_mut().push(dark);
        Ok(())
    }
    fn choose_save_path(&self, default_name: &str) -> Result<Option<PathBuf>, Unavailable> {
        self.save_prompts.borrow_mut().push(default_name.into());
        Ok(None)
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
