//! Read-only permission checks plus Settings links; capture, Keychain and login items are later
//! features, so they report `Unavailable`.
use crate::{InputCatalog, InputDevice, Permission, PermissionState, Services, Unavailable};
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
    fn input_catalog(&self) -> Option<InputCatalog> {
        Some(core_audio::catalog())
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

/// `InputDeviceCatalog.swift`'s plain HAL reads. Reading properties starts no capture and needs no
/// microphone permission. ponytail: the view polls this; Swift listens for changes.
mod core_audio {
    use super::{InputCatalog, InputDevice};
    use std::ffi::{c_char, c_void};

    #[repr(C)]
    struct Address {
        selector: u32,
        scope: u32,
        element: u32,
    }
    const fn code(s: &[u8; 4]) -> u32 {
        u32::from_be_bytes(*s)
    }
    const SYSTEM: u32 = 1;
    const GLOBAL: u32 = code(b"glob");
    const INPUT: u32 = code(b"inpt");
    const UTF8: u32 = 0x0800_0100;

    #[link(name = "CoreAudio", kind = "framework")]
    unsafe extern "C" {
        fn AudioObjectGetPropertyDataSize(object: u32, address: *const Address, qualifier_size: u32, qualifier: *const c_void, size: *mut u32) -> i32;
        fn AudioObjectGetPropertyData(object: u32, address: *const Address, qualifier_size: u32, qualifier: *const c_void, size: *mut u32, data: *mut c_void) -> i32;
    }
    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        static kCFAllocatorDefault: *const c_void;
        fn CFRelease(value: *const c_void);
        fn CFStringGetCString(string: *const c_void, buffer: *mut c_char, size: isize, encoding: u32) -> bool;
        fn CFStringCreateWithCString(allocator: *const c_void, text: *const c_char, encoding: u32) -> *const c_void;
        fn CFBooleanGetValue(value: *const c_void) -> bool;
    }
    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IOServiceMatching(name: *const c_char) -> *const c_void;
        fn IOServiceGetMatchingService(port: u32, matching: *const c_void) -> u32;
        fn IORegistryEntryCreateCFProperty(entry: u32, key: *const c_void, allocator: *const c_void, options: u32) -> *const c_void;
        fn IOObjectRelease(object: u32) -> i32;
    }

    fn uint32(object: u32, selector: u32) -> Option<u32> {
        let address = Address { selector, scope: GLOBAL, element: 0 };
        let (mut value, mut size) = (0u32, 4u32);
        // SAFETY: value and size describe a live u32.
        let status = unsafe { AudioObjectGetPropertyData(object, &address, 0, std::ptr::null(), &mut size, (&raw mut value).cast()) };
        (status == 0).then_some(value)
    }

    fn string(object: u32, selector: u32) -> Option<String> {
        let address = Address { selector, scope: GLOBAL, element: 0 };
        let mut value: *const c_void = std::ptr::null();
        let mut size = std::mem::size_of::<*const c_void>() as u32;
        // SAFETY: the property is a CFString we own on success; the buffer is as long as stated.
        unsafe {
            if AudioObjectGetPropertyData(object, &address, 0, std::ptr::null(), &mut size, (&raw mut value).cast()) != 0 || value.is_null() {
                return None;
            }
            let mut buffer = [0 as c_char; 1024];
            let ok = CFStringGetCString(value, buffer.as_mut_ptr(), buffer.len() as isize, UTF8);
            CFRelease(value);
            ok.then(|| std::ffi::CStr::from_ptr(buffer.as_ptr()).to_string_lossy().into_owned())
        }
    }

    fn data_size(object: u32, selector: u32, scope: u32) -> u32 {
        let address = Address { selector, scope, element: 0 };
        let mut size = 0u32;
        // SAFETY: size is a live u32.
        let status = unsafe { AudioObjectGetPropertyDataSize(object, &address, 0, std::ptr::null(), &mut size) };
        if status == 0 { size } else { 0 }
    }

    fn all_devices() -> Vec<u32> {
        let selector = code(b"dev#");
        let mut size = data_size(SYSTEM, selector, GLOBAL);
        let mut ids = vec![0u32; size as usize / 4];
        let address = Address { selector, scope: GLOBAL, element: 0 };
        // SAFETY: ids holds `size` bytes.
        let status = unsafe { AudioObjectGetPropertyData(SYSTEM, &address, 0, std::ptr::null(), &mut size, ids.as_mut_ptr().cast()) };
        if status != 0 {
            return vec![];
        }
        ids.truncate(size as usize / 4);
        ids
    }

    /// `InputDeviceKind(transportType:)`.
    pub(super) fn kind(transport: u32) -> &'static str {
        match &transport.to_be_bytes() {
            b"bltn" => "builtIn",
            b"usb " => "usb",
            b"blue" | b"blea" => "bluetooth",
            b"ccwd" | b"ccwl" => "iPhone",
            b"virt" | b"grup" => "virtual",
            _ => "other",
        }
    }

    /// `AppleClamshellState` on `IOPMrootDomain`; false when the Mac has no lid.
    fn clamshell() -> bool {
        // SAFETY: each object is checked for null and released; IOServiceGetMatchingService
        // consumes the matching dictionary.
        unsafe {
            let service = IOServiceGetMatchingService(0, IOServiceMatching(c"IOPMrootDomain".as_ptr()));
            if service == 0 {
                return false;
            }
            let key = CFStringCreateWithCString(kCFAllocatorDefault, c"AppleClamshellState".as_ptr(), UTF8);
            let value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
            let closed = !value.is_null() && CFBooleanGetValue(value);
            if !value.is_null() {
                CFRelease(value);
            }
            CFRelease(key);
            IOObjectRelease(service);
            closed
        }
    }

    pub(super) fn catalog() -> InputCatalog {
        let devices = all_devices()
            .into_iter()
            .filter(|d| data_size(*d, code(b"stm#"), INPUT) > 0)
            .filter_map(|d| {
                let uid = string(d, code(b"uid ")).filter(|u| !u.is_empty())?;
                Some(InputDevice {
                    device_id: d,
                    model_uid: string(d, code(b"muid")),
                    name: string(d, code(b"lnam")).unwrap_or_else(|| uid.clone()),
                    kind: kind(uint32(d, code(b"tran")).unwrap_or(0)),
                    alive: uint32(d, code(b"livn")).unwrap_or(0) != 0,
                    uid,
                })
            })
            .take(64)
            .collect();
        InputCatalog { devices, default_input: uint32(SYSTEM, code(b"dIn ")).filter(|d| *d != 0), clamshell: clamshell() }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        #[test]
        fn transport_maps_to_kind_and_catalog_reads() {
            assert_eq!(kind(code(b"bltn")), "builtIn");
            assert_eq!(kind(code(b"blea")), "bluetooth");
            assert_eq!(kind(code(b"ccwl")), "iPhone");
            assert_eq!(kind(code(b"grup")), "virtual");
            assert_eq!(kind(0), "other");
            let catalog = catalog();
            // Every listed device came through the HAL with a UID and at least one input stream.
            assert!(catalog.devices.iter().all(|d| !d.uid.is_empty() && data_size(d.device_id, code(b"stm#"), INPUT) > 0));
            eprintln!("{} inputs, default {:?}, clamshell {}", catalog.devices.len(), catalog.default_input, catalog.clamshell);
        }
    }
}
