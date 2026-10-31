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
    fn secret(&self, _: &str) -> Result<Option<String>, Unavailable> {
        Err(Unavailable("Credential Manager"))
    }
    fn set_secret(&self, _: &str, _: &str) -> Result<(), Unavailable> {
        Err(Unavailable("Credential Manager"))
    }
}
