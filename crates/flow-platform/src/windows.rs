//! No Input Monitoring or Screen Recording step on Windows (plan, "Platform services").
use crate::{Permission, PermissionState, Services, Unavailable};
use std::path::PathBuf;

pub struct Win;

impl Services for Win {
    fn settings_action(&self, action: &str) -> Result<(), Unavailable> {
        match action {
            "download" => self.install_speech_model(),
            "downloadBoostModel" => self.install_term_booster(),
            "downloadMeetingModel" | "downloadSpeakerModel" => self.install_meeting_models(),
            "cancelInstall" => {
                crate::speech::cancel(crate::ModelPack::Speech);
                Ok(())
            }
            _ => Err(Unavailable("this model action")),
        }
    }
    fn install_speech_model(&self) -> Result<(), Unavailable> {
        crate::speech::install(crate::ModelPack::Speech)
    }
    fn install_term_booster(&self) -> Result<(), Unavailable> {
        crate::speech::install(crate::ModelPack::Booster)
    }
    fn install_state(&self, pack: crate::ModelPack) -> crate::InstallState {
        crate::speech::install_state(pack)
    }
    fn speech_model_verified(&self) -> bool {
        crate::speech::install_state(crate::ModelPack::Speech) == crate::InstallState::Verified
    }
    fn install_meeting_models(&self) -> Result<(), Unavailable> {
        // `flow-speech-win` refuses `--meeting`: meetings need a server or a Mac here.
        Err(Unavailable("meeting models on Windows"))
    }
    fn install_local_ai(&self, _model_id: &str) -> Result<(), Unavailable> {
        Err(Unavailable("on-device AI on Windows"))
    }
    fn name(&self) -> &'static str {
        "windows"
    }
    fn device_word(&self) -> &'static str {
        "PC"
    }
    fn app_data_dir(&self) -> PathBuf {
        std::env::var_os("LOCALAPPDATA").map(PathBuf::from).unwrap_or_default()
    }
    fn data_folder(&self) -> &'static str {
        "LocalFlow"
    }
    fn permission(&self, p: Permission) -> PermissionState {
        match p {
            Permission::Microphone if crate::win::system::microphone_consent_denied() => PermissionState::Denied,
            Permission::Microphone => PermissionState::Granted,
            _ => PermissionState::NotRequired,
        }
    }
    fn open_permission_settings(&self, p: Permission) -> Result<(), Unavailable> {
        if p != Permission::Microphone {
            return Err(Unavailable("no such setting on Windows"));
        }
        crate::win::system::shell_open("ms-settings:privacy-microphone").map_err(|_| Unavailable("Windows Settings"))
    }
    fn install_shortcut(&self, shortcut_json: &str) -> Result<(), Unavailable> {
        crate::win::hotkey::install(shortcut_json)
    }
    fn record_shortcut(&self) -> Result<(), Unavailable> {
        crate::win::hotkey::record()
    }
    fn stop_shortcut_recording(&self) {
        crate::win::hotkey::stop_recording()
    }
    fn take_recorded_shortcut(&self) -> Option<Option<String>> {
        crate::win::hotkey::take_recorded()
    }
    fn shortcut_available(&self) -> bool {
        crate::win::hotkey::available()
    }
    fn take_shortcut_events(&self) -> Vec<flow_core::dictation::hotkey::Event> {
        crate::win::hotkey::take_events()
    }
    fn set_shortcut_session_active(&self, active: bool) {
        crate::win::hotkey::set_session_active(active)
    }
    fn has_globe_key(&self) -> bool {
        false
    }
    fn speech_launcher(&self, models: &std::path::Path) -> Option<Box<dyn flow_core::dictation::lifecycle::Launcher>> {
        Some(Box::new(crate::speech::WorkerLauncher::serve(crate::speech::find_worker()?, models)))
    }
    fn open_url(&self, url: &str) -> Result<(), Unavailable> {
        crate::win::system::open_url(url)
    }
    fn google_sign_in_available(&self) -> bool {
        crate::google_client().is_some()
    }
    fn apple_sign_in_available(&self) -> bool {
        false
    }
    fn high_contrast(&self) -> bool {
        crate::win::system::high_contrast()
    }
    fn reduce_motion(&self) -> bool {
        crate::win::system::reduce_motion()
    }
    fn launch_at_login(&self) -> Result<bool, Unavailable> {
        crate::win::system::launch_at_login()
    }
    fn set_launch_at_login(&self, on: bool) -> Result<(), Unavailable> {
        crate::win::system::set_launch_at_login(on)
    }
    fn free_disk_bytes(&self) -> Option<u64> {
        crate::win::system::free_disk_bytes(&self.app_data_dir())
    }
    fn inserter(&self) -> Option<std::sync::Arc<dyn flow_core::dictation::session::Inserter>> {
        Some(crate::win::insert::shared())
    }
    fn capture_insertion_target(&self) -> Result<Option<crate::CapturedTarget>, Unavailable> {
        use flow_core::dictation::session::Inserter;
        Ok(crate::win::insert::shared().capture_target())
    }
    fn insert_once(&self, target: &crate::CapturedTarget, text: &str) -> Result<crate::InsertOutcome, Unavailable> {
        use flow_core::dictation::session::Inserter;
        Ok(crate::win::insert::shared().insert_once(target, text))
    }
    fn free_bytes_probe(&self) -> Box<dyn Fn() -> Option<u64> + Send> {
        let dir = self.app_data_dir();
        Box::new(move || crate::win::system::free_disk_bytes(&dir))
    }
    fn microphone(&self) -> Option<std::sync::Arc<dyn flow_core::dictation::session::Mic>> {
        Some(std::sync::Arc::new(crate::win::mic::WinMic))
    }
    fn input_catalog(&self) -> Option<crate::InputCatalog> {
        crate::win::system::input_catalog()
    }
    fn meeting_audio(&self) -> Option<std::sync::Arc<dyn crate::MeetingAudio>> {
        Some(std::sync::Arc::new(crate::win::wasapi::Wasapi))
    }
    fn secret(&self, name: &str) -> Result<Option<String>, Unavailable> {
        crate::win::secrets::read(name)?.map(|v| String::from_utf8(v).map_err(|_| Unavailable("Credential Manager"))).transpose()
    }
    fn set_secret(&self, name: &str, value: &str) -> Result<(), Unavailable> {
        crate::win::secrets::write(name, value.as_bytes())
    }
    fn remove_secret(&self, name: &str) -> Result<(), Unavailable> {
        crate::win::secrets::remove(name)
    }
    fn credentials(&self) -> std::sync::Arc<dyn crate::Credentials> {
        std::sync::Arc::new(WinCredentials)
    }
    fn secret_data(&self, name: &str) -> Result<Option<Vec<u8>>, Unavailable> {
        crate::win::secrets::read(name)
    }
    fn set_secret_data(&self, name: &str, value: &[u8]) -> Result<(), Unavailable> {
        crate::win::secrets::write(name, value)
    }
    fn device_key_create(&self) -> Result<(Vec<u8>, Vec<u8>), Unavailable> {
        crate::win::tpm::create()
    }
    fn device_key_public_key(&self, handle: &[u8]) -> Option<Vec<u8>> {
        crate::win::tpm::public_key(handle)
    }
    fn device_key_sign(&self, handle: &[u8], message: &[u8]) -> Result<Vec<u8>, Unavailable> {
        crate::win::tpm::sign(handle, message)
    }
    fn device_key_delete(&self, handle: &[u8]) -> Result<(), Unavailable> {
        crate::win::tpm::delete(handle)
    }
}

struct WinCredentials;
impl crate::Credentials for WinCredentials {
    fn open_url(&self, url: &str) -> Result<(), Unavailable> {
        crate::win::system::open_url(url)
    }
    fn secret_data(&self, name: &str) -> Result<Option<Vec<u8>>, Unavailable> {
        crate::win::secrets::read(name)
    }
    fn set_secret_data(&self, name: &str, value: &[u8]) -> Result<(), Unavailable> {
        crate::win::secrets::write(name, value)
    }
    fn remove_secret(&self, name: &str) -> Result<(), Unavailable> {
        crate::win::secrets::remove(name)
    }
    fn device_key_create(&self) -> Result<(Vec<u8>, Vec<u8>), Unavailable> {
        crate::win::tpm::create()
    }
    fn device_key_public_key(&self, handle: &[u8]) -> Option<Vec<u8>> {
        crate::win::tpm::public_key(handle)
    }
    fn device_key_sign(&self, handle: &[u8], message: &[u8]) -> Result<Vec<u8>, Unavailable> {
        crate::win::tpm::sign(handle, message)
    }
    fn device_key_delete(&self, handle: &[u8]) -> Result<(), Unavailable> {
        crate::win::tpm::delete(handle)
    }
}
