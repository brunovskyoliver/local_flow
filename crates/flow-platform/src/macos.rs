//! Read-only permission checks plus Settings links; capture and login items are later features, so
//! they report `Unavailable`.
use crate::{InputCatalog, InputDevice, Permission, PermissionState, Services, Unavailable};
use std::path::PathBuf;

#[link(name = "ApplicationServices", kind = "framework")]
unsafe extern "C" {
    static kAXTrustedCheckOptionPrompt: Id;
    static kCFBooleanTrue: Id;
    fn AXIsProcessTrusted() -> bool;
    fn AXIsProcessTrustedWithOptions(options: Id) -> bool;
    fn CGPreflightScreenCaptureAccess() -> bool;
    fn CGRequestListenEventAccess() -> bool;
}
#[link(name = "AVFoundation", kind = "framework")]
unsafe extern "C" {
    static AVMediaTypeAudio: Id;
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
    fn class_replaceMethod(class: Id, selector: Id, imp: extern "C" fn(Id, Id) -> bool, types: *const std::ffi::c_char) -> *const std::ffi::c_void;
}
#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGEventCreate(source: Id) -> Id;
    fn CGEventGetLocation(event: Id) -> CgPoint;
}
#[repr(C)]
struct CgPoint {
    x: f64,
    y: f64,
}

extern "C" fn answers_no(_: Id, _: Id) -> bool {
    false
}

/// GPUI's panel class accepts key and main; every panel this app opens must refuse them. Changes the
/// class rather than the live panel: `object_setClass` on a panel loses its key-value observers, and
/// `NSWindow dealloc` then throws when it removes them, which aborts the app when a panel closes.
unsafe fn refuse_key_and_main(class: Id) {
    // SAFETY: called on the main thread with a live class; both selectors take no arguments and return BOOL.
    unsafe {
        class_replaceMethod(class, sel_registerName(c"canBecomeKeyWindow".as_ptr()), answers_no, c"c@:".as_ptr());
        class_replaceMethod(class, sel_registerName(c"canBecomeMainWindow".as_ptr()), answers_no, c"c@:".as_ptr());
    }
}

#[cfg(test)]
mod panel_tests {
    use super::*;
    #[test]
    fn pinned_panels_refuse_key_and_main() {
        unsafe extern "C" {
            fn class_getMethodImplementation(class: Id, selector: Id) -> *const std::ffi::c_void;
            fn objc_allocateClassPair(superclass: Id, name: *const std::ffi::c_char, extra: usize) -> Id;
            fn objc_registerClassPair(class: Id);
        }
        // SAFETY: NSPanel is linked through AppKit; nothing is instantiated, so no main thread is needed.
        unsafe {
            let class = objc_allocateClassPair(objc_getClass(c"NSPanel".as_ptr()), c"LocalFlowPanelTest".as_ptr(), 0);
            objc_registerClassPair(class);
            refuse_key_and_main(class);
            for name in [c"canBecomeKeyWindow", c"canBecomeMainWindow"] {
                let imp = class_getMethodImplementation(class, sel_registerName(name.as_ptr()));
                assert_eq!(imp, answers_no as *const std::ffi::c_void);
            }
        }
    }
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

/// `NSApp.isActive`. Read off the main thread by the recorder's tap, for a getter with no side effect.
pub(crate) fn app_is_active() -> bool {
    // SAFETY: `isActive` takes no arguments and returns a BOOL.
    unsafe {
        let is_active: unsafe extern "C" fn(Id, Id) -> bool = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        is_active(send(objc_getClass(c"NSApplication".as_ptr()), c"sharedApplication"), sel_registerName(c"isActive".as_ptr()))
    }
}

/// What `Services` doesn't reach off the main thread.
pub(crate) fn mic_granted() -> bool {
    microphone_state() == PermissionState::Granted
}
pub(crate) fn catalog() -> InputCatalog {
    core_audio::catalog()
}
pub(crate) fn input_device_name(device: u32) -> Option<String> {
    core_audio::catalog().devices.into_iter().find(|d| d.device_id == device).map(|d| d.name)
}

#[repr(C)]
#[derive(Default)]
struct StatVfs {
    bsize: std::ffi::c_ulong,
    frsize: std::ffi::c_ulong,
    blocks: u32,
    bfree: u32,
    bavail: u32,
    files: u32,
    ffree: u32,
    favail: u32,
    fsid: std::ffi::c_ulong,
    flag: std::ffi::c_ulong,
    namemax: std::ffi::c_ulong,
}
unsafe extern "C" {
    fn statvfs(path: *const std::ffi::c_char, out: *mut StatVfs) -> i32;
}

/// Bytes an unprivileged process may use on the volume of `path`.
fn free_bytes(path: &std::path::Path) -> Option<u64> {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut out = StatVfs::default();
    // SAFETY: `c` is a live C string and `out` is the Darwin struct this function fills.
    (unsafe { statvfs(c.as_ptr(), &mut out) } == 0).then(|| out.frsize as u64 * out.bavail as u64)
}

fn microphone_state() -> PermissionState {
    // SAFETY: `authorizationStatusForMediaType:` only reads the status; it never prompts.
    let status = unsafe {
        let status: unsafe extern "C" fn(Id, Id, Id) -> isize = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        status(objc_getClass(c"AVCaptureDevice".as_ptr()), sel_registerName(c"authorizationStatusForMediaType:".as_ptr()), AVMediaTypeAudio)
    };
    match status {
        0 => PermissionState::NotAsked,
        3 => PermissionState::Granted,
        _ => PermissionState::Denied,
    }
}

/// TCC kills a process that asks for the microphone with no usage string, so an unbundled binary
/// has to refuse first.
fn microphone_usage_declared() -> bool {
    // SAFETY: `objectForInfoDictionaryKey:` reads the main bundle's Info.plist.
    unsafe {
        let object: unsafe extern "C" fn(Id, Id, Id) -> Id = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        !object(send(objc_getClass(c"NSBundle".as_ptr()), c"mainBundle"), sel_registerName(c"objectForInfoDictionaryKey:".as_ptr()), ns_string(c"NSMicrophoneUsageDescription")).is_null()
    }
}

static MICROPHONE_ANSWER: std::sync::Mutex<Option<std::sync::mpsc::SyncSender<bool>>> = std::sync::Mutex::new(None);

/// A global block, as the compiler lays it out for a capture-free `^(BOOL granted)`.
#[repr(C)]
struct Block {
    isa: *const std::ffi::c_void,
    flags: i32,
    reserved: i32,
    invoke: unsafe extern "C" fn(*const Block, bool),
    descriptor: *const BlockDescriptor,
}
#[repr(C)]
struct BlockDescriptor {
    reserved: usize,
    size: usize,
}
struct SharedBlock(Block);
// SAFETY: the block holds only constants and is never written to.
unsafe impl Sync for SharedBlock {}
const BLOCK_IS_GLOBAL: i32 = 1 << 28;
static BLOCK_DESCRIPTOR: SyncDescriptor = SyncDescriptor(BlockDescriptor { reserved: 0, size: std::mem::size_of::<Block>() });
struct SyncDescriptor(BlockDescriptor);
// SAFETY: constants only.
unsafe impl Sync for SyncDescriptor {}
unsafe extern "C" {
    static _NSConcreteGlobalBlock: [*const std::ffi::c_void; 32];
}

unsafe extern "C" fn microphone_answered(_block: *const Block, granted: bool) {
    if let Some(answer) = MICROPHONE_ANSWER.lock().unwrap_or_else(|e| e.into_inner()).take() {
        let _ = answer.try_send(granted);
    }
}

/// `requestMicrophone`. ponytail: waits for the answer on the caller's (UI) thread, up to a minute.
/// The prompt belongs to another process, so it stays usable; a page that must not stall can make this async.
fn request_microphone() -> Result<PermissionState, Unavailable> {
    let state = microphone_state();
    if state != PermissionState::NotAsked {
        return Ok(state);
    }
    if !microphone_usage_declared() {
        return Err(Unavailable("the microphone prompt outside the app bundle"));
    }
    let (answer, answered) = std::sync::mpsc::sync_channel(1);
    *MICROPHONE_ANSWER.lock().unwrap_or_else(|e| e.into_inner()) = Some(answer);
    // SAFETY: the block is immortal and matches `void (^)(BOOL)`.
    unsafe {
        let block = SharedBlock(Block { isa: (&raw const _NSConcreteGlobalBlock).cast(), flags: BLOCK_IS_GLOBAL, reserved: 0, invoke: microphone_answered, descriptor: &BLOCK_DESCRIPTOR.0 });
        let block: &'static SharedBlock = Box::leak(Box::new(block));
        let request: unsafe extern "C" fn(Id, Id, Id, *const Block) = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        request(objc_getClass(c"AVCaptureDevice".as_ptr()), sel_registerName(c"requestAccessForMediaType:completionHandler:".as_ptr()), AVMediaTypeAudio, &block.0);
    }
    let _ = answered.recv_timeout(std::time::Duration::from_secs(60));
    Ok(microphone_state())
}

pub struct Mac;

impl Services for Mac {
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
        crate::speech::install(crate::ModelPack::Meeting)
    }
    /// The installer's first check, `LocalAIRuntime.install`: this app's bundle carries no MTPLX
    /// requirements or service plists until packaging adds them, so setup ends there, as Swift does.
    /// Nothing is downloaded and no service is registered. Left: tasks.md T019.
    fn install_local_ai(&self, _model_id: &str) -> Result<(), Unavailable> {
        Ok(())
    }
    fn local_ai_phase(&self) -> Option<flow_core::onboarding::AiPhase> {
        Some(flow_core::onboarding::AiPhase::Failed(flow_core::onboarding::AI_ERROR_MISSING.into()))
    }
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
    fn swift_data_folder(&self) -> Option<&'static str> {
        Some("LocalFlow")
    }
    fn swift_prefs(&self) -> Option<serde_json::Map<String, serde_json::Value>> {
        let out = std::process::Command::new("/usr/bin/defaults").args(["export", "org.localflow.LocalFlow", "-"]).output().ok().filter(|o| o.status.success())?;
        crate::swift_prefs::from_plist(&out.stdout)
    }
    fn permission(&self, p: Permission) -> PermissionState {
        let granted = match p {
            Permission::Accessibility => unsafe { AXIsProcessTrusted() },
            Permission::SystemAudio => unsafe { CGPreflightScreenCaptureAccess() },
            Permission::InputMonitoring => match unsafe { IOHIDCheckAccess(1) } {
                0 => true,
                1 => return PermissionState::Denied,
                _ => return PermissionState::NotAsked,
            },
            Permission::Microphone => return microphone_state(),
        };
        if granted { PermissionState::Granted } else { PermissionState::NotAsked }
    }
    fn install_shortcut(&self, shortcut_json: &str) -> Result<(), Unavailable> {
        crate::hotkey_mac::install(shortcut_json)
    }
    fn record_shortcut(&self) -> Result<(), Unavailable> {
        crate::hotkey_mac::record()
    }
    fn stop_shortcut_recording(&self) {
        crate::hotkey_mac::stop_recording()
    }
    fn take_recorded_shortcut(&self) -> Option<Option<String>> {
        crate::hotkey_mac::take_recorded()
    }
    fn shortcut_available(&self) -> bool {
        crate::hotkey_mac::available()
    }
    fn take_shortcut_events(&self) -> Vec<flow_core::dictation::hotkey::Event> {
        crate::hotkey_mac::take_events()
    }
    fn set_shortcut_session_active(&self, active: bool) {
        crate::hotkey_mac::set_session_active(active)
    }
    /// Each of these brings up a system dialog at most once. Called only from a button press.
    fn request_permission(&self, p: Permission) -> Result<PermissionState, Unavailable> {
        match p {
            Permission::InputMonitoring => unsafe {
                CGRequestListenEventAccess();
            },
            Permission::Accessibility => unsafe {
                let prompt: unsafe extern "C" fn(Id, Id, Id, Id) -> Id = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
                let options = prompt(objc_getClass(c"NSDictionary".as_ptr()), sel_registerName(c"dictionaryWithObject:forKey:".as_ptr()), kCFBooleanTrue, kAXTrustedCheckOptionPrompt);
                AXIsProcessTrustedWithOptions(options);
            },
            Permission::Microphone => return request_microphone(),
            Permission::SystemAudio => return Err(Unavailable("the permission prompt")),
        }
        Ok(self.permission(p))
    }
    fn speech_launcher(&self, models: &std::path::Path) -> Option<Box<dyn flow_core::dictation::lifecycle::Launcher>> {
        Some(Box::new(crate::speech::WorkerLauncher::serve(crate::speech::find_worker()?, models)))
    }
    fn open_url(&self, url: &str) -> Result<(), Unavailable> {
        open_with_system(url)
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
    fn mark_alert_button_destructive(&self, title: &str) -> bool {
        let Ok(title) = std::ffi::CString::new(title) else { return true };
        // SAFETY: on the main thread with AppKit linked; every selector exists on the receiver's class,
        // checked with `isKindOfClass:` for the views of the sheet walked here.
        unsafe {
            let count: unsafe extern "C" fn(Id, Id) -> usize = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
            let at: unsafe extern "C" fn(Id, Id, usize) -> Id = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
            let is_a: unsafe extern "C" fn(Id, Id, Id) -> bool = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
            let equal: unsafe extern "C" fn(Id, Id, Id) -> bool = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
            let set: unsafe extern "C" fn(Id, Id, bool) = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
            let (count_sel, at_sel) = (sel_registerName(c"count".as_ptr()), sel_registerName(c"objectAtIndex:".as_ptr()));
            let button_class = objc_getClass(c"NSButton".as_ptr());
            let wanted = ns_string(&title);
            let windows = send(send(objc_getClass(c"NSApplication".as_ptr()), c"sharedApplication"), c"windows");
            for i in 0..count(windows, count_sel) {
                let sheet = send(at(windows, at_sel, i), c"attachedSheet");
                if sheet.is_null() {
                    continue;
                }
                let mut views = vec![send(sheet, c"contentView")];
                while let Some(view) = views.pop() {
                    if view.is_null() {
                        continue;
                    }
                    if is_a(view, sel_registerName(c"isKindOfClass:".as_ptr()), button_class) && equal(send(view, c"title"), sel_registerName(c"isEqualToString:".as_ptr()), wanted) {
                        set(view, sel_registerName(c"setHasDestructiveAction:".as_ptr()), true);
                        return true;
                    }
                    let subviews = send(view, c"subviews");
                    for j in 0..count(subviews, count_sel) {
                        views.push(at(subviews, at_sel, j));
                    }
                }
            }
        }
        false
    }
    fn pin_panel(&self, window: &dyn raw_window_handle::HasWindowHandle) -> Result<(), Unavailable> {
        let unavailable = || Unavailable("panel window traits");
        let raw_window_handle::RawWindowHandle::AppKit(handle) = window.window_handle().map_err(|_| unavailable())?.as_raw() else {
            return Err(unavailable());
        };
        // SAFETY: the handle's NSView is alive on the main thread.
        unsafe {
            let panel = send(handle.ns_view.as_ptr(), c"window");
            if panel.is_null() {
                return Err(unavailable());
            }
            // `class` sees through the subclass key-value observing installs.
            refuse_key_and_main(send(panel, c"class"));
            let set: unsafe extern "C" fn(Id, Id, isize) = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
            // NSFloatingWindowLevel; GPUI's popup kind sets NSPopUpWindowLevel.
            set(panel, sel_registerName(c"setLevel:".as_ptr()), 3);
            // AppKit computes a transparent window's shadow from its first frame and GPUI never asks
            // again, so once the pill grows the old outline stays around it as a pale bubble.
            let set_flag: unsafe extern "C" fn(Id, Id, bool) = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
            set_flag(panel, sel_registerName(c"setHasShadow:".as_ptr()), false);
        }
        Ok(())
    }
    fn pointer_location(&self) -> Option<(f32, f32)> {
        // SAFETY: a null source is allowed, and the event is released once.
        unsafe {
            let event = CGEventCreate(std::ptr::null_mut());
            if event.is_null() {
                return None;
            }
            let p = CGEventGetLocation(event);
            CFRelease(event);
            Some((p.x as f32, p.y as f32))
        }
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
    fn app_name(&self, bundle_id: &str) -> Option<String> {
        let path = app_path(bundle_id)?;
        // SAFETY: AppKit is linked and `path` is a live NSString on the main thread.
        let name = unsafe {
            let manager = send(objc_getClass(c"NSFileManager".as_ptr()), c"defaultManager");
            let display: unsafe extern "C" fn(Id, Id, Id) -> Id = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
            let name = display(manager, sel_registerName(c"displayNameAtPath:".as_ptr()), path);
            std::ffi::CStr::from_ptr(send(name, c"UTF8String") as *const std::ffi::c_char).to_string_lossy().into_owned()
        };
        Some(name.replace(".app", ""))
    }
    fn app_icon_png(&self, bundle_id: &str) -> Option<Vec<u8>> {
        let path = app_path(bundle_id)?;
        // SAFETY: AppKit is linked; each cast matches the selector's signature, and the rep and data are read before they drain.
        unsafe {
            let workspace = send(objc_getClass(c"NSWorkspace".as_ptr()), c"sharedWorkspace");
            let by_path: unsafe extern "C" fn(Id, Id, Id) -> Id = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
            let image = by_path(workspace, sel_registerName(c"iconForFile:".as_ptr()), path);
            // 24 points at 2x, so the file stays small.
            let mut rect = Rect { x: 0., y: 0., w: 48., h: 48. };
            let cg: unsafe extern "C" fn(Id, Id, *mut Rect, Id, Id) -> Id = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
            let cg_image = cg(image, sel_registerName(c"CGImageForProposedRect:context:hints:".as_ptr()), &raw mut rect, std::ptr::null_mut(), std::ptr::null_mut());
            if cg_image.is_null() {
                return None;
            }
            let rep = send(objc_getClass(c"NSBitmapImageRep".as_ptr()), c"alloc");
            let rep = by_path(rep, sel_registerName(c"initWithCGImage:".as_ptr()), cg_image);
            let png: unsafe extern "C" fn(Id, Id, usize, Id) -> Id = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
            let data = png(rep, sel_registerName(c"representationUsingType:properties:".as_ptr()), 4, send(objc_getClass(c"NSDictionary".as_ptr()), c"dictionary"));
            let bytes = if data.is_null() {
                None
            } else {
                let len: unsafe extern "C" fn(Id, Id) -> usize = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
                Some(std::slice::from_raw_parts(send(data, c"bytes") as *const u8, len(data, sel_registerName(c"length".as_ptr()))).to_vec())
            };
            send(rep, c"release");
            bytes
        }
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
        free_bytes(&self.app_data_dir())
    }
    fn inserter(&self) -> Option<std::sync::Arc<dyn flow_core::dictation::session::Inserter>> {
        Some(crate::insert_mac::shared())
    }
    fn capture_insertion_target(&self) -> Result<Option<crate::CapturedTarget>, Unavailable> {
        use flow_core::dictation::session::Inserter;
        Ok(crate::insert_mac::shared().capture_target())
    }
    fn insert_once(&self, target: &crate::CapturedTarget, text: &str) -> Result<crate::InsertOutcome, Unavailable> {
        use flow_core::dictation::session::Inserter;
        Ok(crate::insert_mac::shared().insert_once(target, text))
    }
    fn running_apps(&self) -> Vec<(String, String)> {
        crate::insert_mac::running_apps()
    }
    fn free_bytes_probe(&self) -> Box<dyn Fn() -> Option<u64> + Send> {
        let dir = self.app_data_dir();
        Box::new(move || free_bytes(&dir))
    }
    fn microphone(&self) -> Option<std::sync::Arc<dyn flow_core::dictation::session::Mic>> {
        Some(std::sync::Arc::new(crate::mic_mac::MacMic))
    }
    fn secret(&self, name: &str) -> Result<Option<String>, Unavailable> {
        crate::keychain_mac::read(name)?.map(|v| String::from_utf8(v).map_err(|_| Unavailable("Keychain"))).transpose()
    }
    fn set_secret(&self, name: &str, value: &str) -> Result<(), Unavailable> {
        crate::keychain_mac::write(name, value.as_bytes())
    }
    fn remove_secret(&self, name: &str) -> Result<(), Unavailable> {
        crate::keychain_mac::remove(name)
    }
    fn secret_exists(&self, name: &str) -> Result<bool, Unavailable> {
        crate::keychain_mac::exists(name)
    }
    fn credentials(&self) -> std::sync::Arc<dyn crate::Credentials> {
        std::sync::Arc::new(MacCredentials)
    }
    fn secret_data(&self, name: &str) -> Result<Option<Vec<u8>>, Unavailable> {
        crate::keychain_mac::read(name)
    }
    fn set_secret_data(&self, name: &str, value: &[u8]) -> Result<(), Unavailable> {
        crate::keychain_mac::write(name, value)
    }
    fn device_key_create(&self) -> Result<(Vec<u8>, Vec<u8>), Unavailable> {
        crate::keys_mac::create()
    }
    fn device_key_public_key(&self, handle: &[u8]) -> Option<Vec<u8>> {
        crate::keys_mac::public_key(handle)
    }
    fn device_key_sign(&self, handle: &[u8], message: &[u8]) -> Result<Vec<u8>, Unavailable> {
        crate::keys_mac::sign(handle, message)
    }
    /// The enclave keeps nothing per key: dropping the handle from Keychain is what destroys it.
    fn device_key_delete(&self, _: &[u8]) -> Result<(), Unavailable> {
        Ok(())
    }
}

/// `NSWorkspace.urlForApplication(withBundleIdentifier:)`'s path; autoreleased.
fn app_path(bundle_id: &str) -> Option<Id> {
    let text = std::ffi::CString::new(bundle_id).ok()?;
    // SAFETY: AppKit is linked; the argument is a live NSString, and a nil URL is checked.
    unsafe {
        let workspace = send(objc_getClass(c"NSWorkspace".as_ptr()), c"sharedWorkspace");
        let lookup: unsafe extern "C" fn(Id, Id, Id) -> Id = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        let url = lookup(workspace, sel_registerName(c"URLForApplicationWithBundleIdentifier:".as_ptr()), ns_string(&text));
        if url.is_null() { None } else { Some(send(url, c"path")) }
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
        use super::super::microphone_usage_declared;

        /// An unbundled binary has no usage string, so the prompt path refuses instead of being killed.
        #[test]
        fn free_space_reads_the_volume() {
            let free = super::super::free_bytes(&std::env::temp_dir()).unwrap();
            assert!(free > 0);
            assert_eq!(super::super::free_bytes(std::path::Path::new("/no/such/place")), None);
        }

        #[test]
        fn a_test_binary_declares_no_microphone_use() {
            assert!(!microphone_usage_declared());
        }

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

struct MacCredentials;
fn open_with_system(url: &str) -> Result<(), Unavailable> {
    std::process::Command::new("/usr/bin/open").arg(url).spawn().map(|_| ()).map_err(|_| Unavailable("opening a link"))
}

impl crate::Credentials for MacCredentials {
    fn open_url(&self, url: &str) -> Result<(), Unavailable> {
        open_with_system(url)
    }
    fn secret_data(&self, name: &str) -> Result<Option<Vec<u8>>, Unavailable> {
        crate::keychain_mac::read(name)
    }
    fn set_secret_data(&self, name: &str, value: &[u8]) -> Result<(), Unavailable> {
        crate::keychain_mac::write(name, value)
    }
    fn remove_secret(&self, name: &str) -> Result<(), Unavailable> {
        crate::keychain_mac::remove(name)
    }
    fn device_key_create(&self) -> Result<(Vec<u8>, Vec<u8>), Unavailable> {
        crate::keys_mac::create()
    }
    fn device_key_public_key(&self, handle: &[u8]) -> Option<Vec<u8>> {
        crate::keys_mac::public_key(handle)
    }
    fn device_key_sign(&self, handle: &[u8], message: &[u8]) -> Result<Vec<u8>, Unavailable> {
        crate::keys_mac::sign(handle, message)
    }
    /// See `Services::device_key_delete`: nothing to do beyond dropping the handle.
    fn device_key_delete(&self, _: &[u8]) -> Result<(), Unavailable> {
        Ok(())
    }
    fn device_name(&self) -> String {
        unsafe extern "C" {
            fn gethostname(name: *mut std::ffi::c_char, length: usize) -> i32;
        }
        let mut buffer = [0u8; 256];
        // SAFETY: the pointer and length describe `buffer`.
        let status = unsafe { gethostname(buffer.as_mut_ptr().cast(), buffer.len()) };
        let end = buffer.iter().position(|b| *b == 0).unwrap_or(buffer.len());
        // ponytail: the host name, where Swift shows the Mac's localized name; SCDynamicStore if the owner minds in the admin list.
        let name = String::from_utf8_lossy(&buffer[..end]);
        if status == 0 && !name.is_empty() { name.trim_end_matches(".local").to_string() } else { "Mac".into() }
    }
}
