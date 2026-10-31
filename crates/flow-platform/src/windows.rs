//! No Input Monitoring or Screen Recording step on Windows (plan, "Platform services").
use crate::{Permission, PermissionState, Services, Unavailable};
use std::path::PathBuf;

pub struct Win;

impl Services for Win {
    fn name(&self) -> &'static str {
        "windows"
    }
    fn device_word(&self) -> &'static str {
        "PC"
    }
    fn app_data_dir(&self) -> PathBuf {
        std::env::var_os("LOCALAPPDATA").map(PathBuf::from).unwrap_or_default()
    }
    fn permission(&self, p: Permission) -> PermissionState {
        match p {
            // ponytail: reading the microphone consent store comes with WASAPI capture in Feature 025.
            Permission::Microphone => PermissionState::NotAsked,
            _ => PermissionState::NotRequired,
        }
    }
    fn open_permission_settings(&self, p: Permission) -> Result<(), Unavailable> {
        if p != Permission::Microphone {
            return Err(Unavailable("no such setting on Windows"));
        }
        std::process::Command::new("cmd")
            .args(["/C", "start", "ms-settings:privacy-microphone"])
            .spawn()
            .map(|_| ())
            .map_err(|_| Unavailable("Windows Settings"))
    }
    fn high_contrast(&self) -> bool {
        false
    }
    fn reduce_motion(&self) -> bool {
        false
    }
    fn launch_at_login(&self) -> Result<bool, Unavailable> {
        Err(Unavailable("Run registry key"))
    }
    fn set_launch_at_login(&self, _: bool) -> Result<(), Unavailable> {
        Err(Unavailable("Run registry key"))
    }
    fn free_disk_bytes(&self) -> Option<u64> {
        None
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
