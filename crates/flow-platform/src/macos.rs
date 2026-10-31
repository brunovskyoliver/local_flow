//! Read-only permission checks plus Settings links; capture, Keychain and login items are later
//! features, so they report `Unavailable`.
use crate::{Permission, PermissionState, Services, Unavailable};
use std::path::PathBuf;

#[link(name = "ApplicationServices", kind = "framework")]
unsafe extern "C" {
    fn AXIsProcessTrusted() -> bool;
    fn CGPreflightScreenCaptureAccess() -> bool;
}
#[link(name = "IOKit", kind = "framework")]
unsafe extern "C" {
    fn IOHIDCheckAccess(request: u32) -> u32;
}

unsafe extern "C" {
    fn sysctlbyname(name: *const std::ffi::c_char, old: *mut std::ffi::c_void, oldlen: *mut usize, new: *mut std::ffi::c_void, newlen: usize) -> i32;
}

pub struct Mac;

impl Services for Mac {
    fn name(&self) -> &'static str {
        "macos"
    }
    fn device_word(&self) -> &'static str {
        "Mac"
    }
    fn app_data_dir(&self) -> PathBuf {
        let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
        home.join("Library/Application Support")
    }
    fn permission(&self, p: Permission) -> PermissionState {
        // ponytail: microphone status needs AVFoundation, added with capture in Feature 025.
        let granted = match p {
            Permission::Accessibility => unsafe { AXIsProcessTrusted() },
            Permission::SystemAudio => unsafe { CGPreflightScreenCaptureAccess() },
            Permission::InputMonitoring => match unsafe { IOHIDCheckAccess(1) } {
                0 => true,
                1 => return PermissionState::Denied,
                _ => return PermissionState::NotAsked,
            },
            Permission::Microphone => return PermissionState::NotAsked,
        };
        if granted { PermissionState::Granted } else { PermissionState::NotAsked }
    }
    fn open_url(&self, url: &str) -> Result<(), Unavailable> {
        std::process::Command::new("/usr/bin/open").arg(url).spawn().map(|_| ()).map_err(|_| Unavailable("opening a link"))
    }
    fn open_permission_settings(&self, p: Permission) -> Result<(), Unavailable> {
        let pane = match p {
            Permission::Microphone => "Privacy_Microphone",
            Permission::SystemAudio => "Privacy_ScreenCapture",
            Permission::Accessibility => "Privacy_Accessibility",
            Permission::InputMonitoring => "Privacy_ListenEvent",
        };
        std::process::Command::new("open")
            .arg(format!("x-apple.systempreferences:com.apple.preference.security?{pane}"))
            .spawn()
            .map(|_| ())
            .map_err(|_| Unavailable("System Settings"))
    }
    fn physical_memory(&self) -> u64 {
        let mut value = 0u64;
        let mut size = std::mem::size_of::<u64>();
        // SAFETY: the name is NUL-terminated and value and size describe a live u64.
        let ok = unsafe { sysctlbyname(c"hw.memsize".as_ptr(), (&raw mut value).cast(), &raw mut size, std::ptr::null_mut(), 0) };
        if ok == 0 { value } else { 0 }
    }
    fn high_contrast(&self) -> bool {
        read_universal_access("increaseContrast")
    }
    fn reduce_motion(&self) -> bool {
        read_universal_access("reduceMotion")
    }
    fn launch_at_login(&self) -> Result<bool, Unavailable> {
        Err(Unavailable("SMAppService"))
    }
    fn set_launch_at_login(&self, _: bool) -> Result<(), Unavailable> {
        Err(Unavailable("SMAppService"))
    }
    fn free_disk_bytes(&self) -> Option<u64> {
        None
    }
    fn secret(&self, _: &str) -> Result<Option<String>, Unavailable> {
        Err(Unavailable("Keychain"))
    }
    fn set_secret(&self, _: &str, _: &str) -> Result<(), Unavailable> {
        Err(Unavailable("Keychain"))
    }
}

fn read_universal_access(key: &str) -> bool {
    std::process::Command::new("defaults")
        .args(["read", "com.apple.universalaccess", key])
        .output()
        .is_ok_and(|o| String::from_utf8_lossy(&o.stdout).trim() == "1")
}
