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

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFLocaleDecimalSeparator: *const std::ffi::c_void;
    fn CFLocaleCopyCurrent() -> *const std::ffi::c_void;
    fn CFLocaleGetValue(locale: *const std::ffi::c_void, key: *const std::ffi::c_void) -> *const std::ffi::c_void;
    fn CFStringGetLength(s: *const std::ffi::c_void) -> isize;
    fn CFStringGetCharacterAtIndex(s: *const std::ffi::c_void, index: isize) -> u16;
    fn CFRelease(o: *const std::ffi::c_void);
}

#[repr(C)]
#[derive(Clone, Copy)]
struct Rect {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
}

type Id = *mut std::ffi::c_void;

#[link(name = "objc")]
unsafe extern "C" {
    fn objc_msgSend();
    #[cfg(target_arch = "x86_64")]
    fn objc_msgSend_stret();
    fn objc_getClass(name: *const std::ffi::c_char) -> Id;
    fn sel_registerName(name: *const std::ffi::c_char) -> Id;
}
#[link(name = "AppKit", kind = "framework")]
unsafe extern "C" {
    static NSAccessibilityAnnouncementKey: Id;
    static NSAccessibilityPriorityKey: Id;
    static NSAccessibilityAnnouncementRequestedNotification: Id;
    fn NSAccessibilityPostNotificationWithUserInfo(element: Id, notification: Id, info: Id);
}
#[link(name = "QuartzCore", kind = "framework")]
unsafe extern "C" {}

/// `[receiver selector]` with no arguments, returning an object.
unsafe fn send(receiver: Id, selector: &std::ffi::CStr) -> Id {
    // SAFETY: the caller names a selector taking no arguments and returning an object or void.
    unsafe {
        let f: unsafe extern "C" fn(Id, Id) -> Id = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        f(receiver, sel_registerName(selector.as_ptr()))
    }
}

/// A new autoreleased NSString.
unsafe fn ns_string(text: &std::ffi::CStr) -> Id {
    // SAFETY: `stringWithUTF8String:` copies a valid C string.
    unsafe {
        let f: unsafe extern "C" fn(Id, Id, *const std::ffi::c_char) -> Id = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        f(objc_getClass(c"NSString".as_ptr()), sel_registerName(c"stringWithUTF8String:".as_ptr()), text.as_ptr())
    }
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
    fn set_app_appearance(&self, dark: Option<bool>) -> Result<(), Unavailable> {
        // SAFETY: NSApplication and NSAppearance exist with AppKit linked; a nil appearance means follow the system.
        unsafe {
            let app = send(objc_getClass(c"NSApplication".as_ptr()), c"sharedApplication");
            let appearance = match dark {
                None => std::ptr::null_mut(),
                Some(dark) => {
                    let name = send(objc_getClass(c"NSString".as_ptr()), c"alloc");
                    let init: unsafe extern "C" fn(Id, Id, *const std::ffi::c_char) -> Id = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
                    let text = if dark { c"NSAppearanceNameDarkAqua" } else { c"NSAppearanceNameAqua" };
                    let name = init(name, sel_registerName(c"initWithUTF8String:".as_ptr()), text.as_ptr());
                    let named: unsafe extern "C" fn(Id, Id, Id) -> Id = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
                    named(objc_getClass(c"NSAppearance".as_ptr()), sel_registerName(c"appearanceNamed:".as_ptr()), name)
                }
            };
            let set: unsafe extern "C" fn(Id, Id, Id) = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
            set(app, sel_registerName(c"setAppearance:".as_ptr()), appearance);
        }
        Ok(())
    }
    fn set_window_identifier(&self, window: &dyn raw_window_handle::HasWindowHandle, identifier: &str) -> Result<(), Unavailable> {
        let unavailable = || Unavailable("window identifiers");
        let raw_window_handle::RawWindowHandle::AppKit(handle) = window.window_handle().map_err(|_| unavailable())?.as_raw() else { return Err(unavailable()) };
        let text = std::ffi::CString::new(identifier).map_err(|_| unavailable())?;
        // SAFETY: the handle's NSView is alive on the main thread; `window` and `setIdentifier:` exist on it.
        unsafe {
            let ns_window = send(handle.ns_view.as_ptr(), c"window");
            let set: unsafe extern "C" fn(Id, Id, Id) = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
            set(ns_window, sel_registerName(c"setIdentifier:".as_ptr()), ns_string(&text));
        }
        Ok(())
    }
    fn announce(&self, message: &str) -> Result<(), Unavailable> {
        let text = std::ffi::CString::new(message).map_err(|_| Unavailable("accessibility announcements"))?;
        // SAFETY: AppKit is linked; the keys and values are live NSStrings and a NSNumber on the main thread.
        unsafe {
            let app = send(objc_getClass(c"NSApplication".as_ptr()), c"sharedApplication");
            let number: unsafe extern "C" fn(Id, Id, isize) -> Id = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
            let medium = number(objc_getClass(c"NSNumber".as_ptr()), sel_registerName(c"numberWithInteger:".as_ptr()), 50);
            let keys = [NSAccessibilityAnnouncementKey, NSAccessibilityPriorityKey];
            let values = [ns_string(&text), medium];
            let dict: unsafe extern "C" fn(Id, Id, *const Id, *const Id, usize) -> Id = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
            let info = dict(objc_getClass(c"NSDictionary".as_ptr()), sel_registerName(c"dictionaryWithObjects:forKeys:count:".as_ptr()), values.as_ptr(), keys.as_ptr(), 2);
            NSAccessibilityPostNotificationWithUserInfo(app, NSAccessibilityAnnouncementRequestedNotification, info);
        }
        Ok(())
    }
    fn reveal_app(&self) -> Result<(), Unavailable> {
        let exe = std::env::current_exe().map_err(|_| Unavailable("revealing the app"))?;
        // The enclosing `.app`, or the bare binary in a development build.
        let target = exe.ancestors().find(|a| a.extension().is_some_and(|e| e == "app")).unwrap_or(&exe).to_path_buf();
        std::process::Command::new("open").arg("-R").arg(target).spawn().map(|_| ()).map_err(|_| Unavailable("revealing the app"))
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
    fn animate_panel_frame(&self, window: &dyn raw_window_handle::HasWindowHandle, x: f32, width: f32, duration: f32, curve: [f32; 4]) -> Result<(), Unavailable> {
        let unavailable = Unavailable("animated window frames");
        let raw_window_handle::RawWindowHandle::AppKit(handle) = window.window_handle().map_err(|_| unavailable.clone())?.as_raw() else { return Err(unavailable) };
        // SAFETY: called on the main thread with GPUI's live NSView; each cast matches the selector's AppKit signature.
        // NSRect is returned through a hidden pointer on x86_64 and in registers on arm64.
        unsafe {
            let window = send(handle.ns_view.as_ptr(), c"window");
            if window.is_null() {
                return Err(unavailable);
            }
            let frame_sel = sel_registerName(c"frame".as_ptr());
            #[cfg(target_arch = "x86_64")]
            let frame = {
                let f: unsafe extern "C" fn(*mut Rect, Id, Id) = std::mem::transmute(objc_msgSend_stret as unsafe extern "C" fn());
                let mut r = Rect { x: 0., y: 0., w: 0., h: 0. };
                f(&raw mut r, window, frame_sel);
                r
            };
            #[cfg(not(target_arch = "x86_64"))]
            let frame = {
                let f: unsafe extern "C" fn(Id, Id) -> Rect = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
                f(window, frame_sel)
            };
            let context_class = objc_getClass(c"NSAnimationContext".as_ptr());
            send(context_class, c"beginGrouping");
            let context = send(context_class, c"currentContext");
            let set_duration: unsafe extern "C" fn(Id, Id, f64) = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
            set_duration(context, sel_registerName(c"setDuration:".as_ptr()), duration as f64);
            let make_curve: unsafe extern "C" fn(Id, Id, f32, f32, f32, f32) -> Id = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
            let timing = make_curve(objc_getClass(c"CAMediaTimingFunction".as_ptr()), sel_registerName(c"functionWithControlPoints::::".as_ptr()), curve[0], curve[1], curve[2], curve[3]);
            let set_timing: unsafe extern "C" fn(Id, Id, Id) = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
            set_timing(context, sel_registerName(c"setTimingFunction:".as_ptr()), timing);
            let set_frame: unsafe extern "C" fn(Id, Id, Rect, bool) = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
            set_frame(send(window, c"animator"), sel_registerName(c"setFrame:display:".as_ptr()), Rect { x: x as f64, y: frame.y, w: width as f64, h: frame.h }, true);
            send(context_class, c"endGrouping");
        }
        Ok(())
    }
    fn decimal_separator(&self) -> char {
        // SAFETY: CFLocaleCopyCurrent returns an owned locale, released below; the value is borrowed from it and read first.
        unsafe {
            let locale = CFLocaleCopyCurrent();
            let value = CFLocaleGetValue(locale, kCFLocaleDecimalSeparator);
            let c = if !value.is_null() && CFStringGetLength(value) > 0 { char::from_u32(CFStringGetCharacterAtIndex(value, 0) as u32) } else { None };
            CFRelease(locale);
            c.unwrap_or('.')
        }
    }
    fn formats(&self) -> Option<crate::Formats> {
        Some(crate::region_mac::formats())
    }
    fn voice_over_on(&self) -> bool {
        read_universal_access("voiceOverOnOffKey")
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
