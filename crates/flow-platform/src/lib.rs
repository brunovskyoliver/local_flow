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

/// OS services a view calls. Tests use `Fake`.
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
}

#[cfg(target_os = "macos")]
mod macos;
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
    pub permissions: std::cell::RefCell<Vec<(Permission, PermissionState)>>,
    pub login: std::cell::Cell<bool>,
    pub dir: PathBuf,
}

impl Default for Fake {
    fn default() -> Self {
        Fake { device: "Mac", permissions: Default::default(), login: Default::default(), dir: std::env::temp_dir() }
    }
}

impl Services for Fake {
    fn name(&self) -> &'static str {
        "fake"
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
}
