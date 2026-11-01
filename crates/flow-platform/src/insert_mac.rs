//! `SystemTextAccessibilityAdapter` over ApplicationServices. The decisions are in
//! `flow_core::dictation::insert`; this file only touches AX, CGEvent and the pasteboard. Field text
//! stays in memory for the attempt and nothing here logs.
use flow_core::dictation::insert::{self, Dispatch, Issue, Span, Target};
use flow_core::dictation::session::{CapturedTarget, InsertDelivery, InsertOutcome, Inserter};
use std::collections::{HashMap, HashSet, VecDeque};
use std::ffi::{CStr, CString, c_char, c_void};
use std::sync::atomic::{AtomicU64, Ordering::*};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

type Cf = *const c_void;
type Id = *mut c_void;

const MESSAGING_TIMEOUT: f32 = 0.25;
const AX_SUCCESS: i32 = 0;
const VALUE_CF_RANGE: i32 = 4;
const UTF8: u32 = 0x0800_0100;
const NUMBER_I64: i64 = 4;
const PRIVATE_STATE: i32 = -1;
const COMMAND_FLAG: u64 = 0x10_0000;
const VK_V: u16 = 9;
const ACTIVATION_REGULAR: i64 = 0;
const SNAPSHOT_LIMIT: usize = 32 * 1024 * 1024;
const RESTORE_DELAY: Duration = Duration::from_secs(1);
const AFTER_UNITS: i64 = 300;
const HELD_TARGETS: usize = 8;

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct CfRange {
    location: i64,
    length: i64,
}

#[link(name = "ApplicationServices", kind = "framework")]
unsafe extern "C" {
    fn AXIsProcessTrusted() -> bool;
    fn AXUIElementCreateSystemWide() -> Cf;
    fn AXUIElementCreateApplication(pid: i32) -> Cf;
    fn AXUIElementCopyAttributeValue(element: Cf, attribute: Cf, value: *mut Cf) -> i32;
    fn AXUIElementCopyParameterizedAttributeValue(element: Cf, attribute: Cf, parameter: Cf, value: *mut Cf) -> i32;
    fn AXUIElementSetAttributeValue(element: Cf, attribute: Cf, value: Cf) -> i32;
    fn AXUIElementIsAttributeSettable(element: Cf, attribute: Cf, settable: *mut u8) -> i32;
    fn AXUIElementGetPid(element: Cf, pid: *mut i32) -> i32;
    fn AXUIElementSetMessagingTimeout(element: Cf, seconds: f32) -> i32;
    fn AXUIElementGetTypeID() -> usize;
    fn AXValueGetTypeID() -> usize;
    fn AXValueCreate(kind: i32, value: *const c_void) -> Cf;
    fn AXValueGetValue(value: Cf, kind: i32, out: *mut c_void) -> bool;
    fn CGEventSourceCreate(state: i32) -> Cf;
    fn CGEventCreateKeyboardEvent(source: Cf, key: u16, down: bool) -> Cf;
    fn CGEventSetFlags(event: Cf, flags: u64);
    fn CGEventKeyboardSetUnicodeString(event: Cf, length: usize, text: *const u16);
    fn CGEventPostToPid(pid: i32, event: Cf);
}
#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFBooleanTrue: Cf;
    fn CFRelease(value: Cf);
    fn CFRetain(value: Cf) -> Cf;
    fn CFEqual(a: Cf, b: Cf) -> bool;
    fn CFGetTypeID(value: Cf) -> usize;
    fn CFStringGetTypeID() -> usize;
    fn CFNumberGetTypeID() -> usize;
    fn CFStringCreateWithCString(allocator: Cf, text: *const c_char, encoding: u32) -> Cf;
    fn CFStringGetLength(text: Cf) -> i64;
    fn CFStringGetMaximumSizeForEncoding(length: i64, encoding: u32) -> i64;
    fn CFStringGetCString(text: Cf, buffer: *mut c_char, size: i64, encoding: u32) -> bool;
    fn CFNumberGetValue(number: Cf, kind: i64, out: *mut c_void) -> bool;
}
#[link(name = "Carbon", kind = "framework")]
unsafe extern "C" {
    fn IsSecureEventInputEnabled() -> bool;
}
#[link(name = "objc")]
unsafe extern "C" {
    fn objc_msgSend();
    fn objc_getClass(name: *const c_char) -> Id;
    fn sel_registerName(name: *const c_char) -> Id;
    fn objc_autoreleasePoolPush() -> *mut c_void;
    fn objc_autoreleasePoolPop(pool: *mut c_void);
}

/// An owned CF object. AX elements are safe to read from any thread; Swift sends them too.
struct Owned(Cf);
unsafe impl Send for Owned {}
unsafe impl Sync for Owned {}
impl Owned {
    fn new(value: Cf) -> Option<Owned> {
        (!value.is_null()).then_some(Owned(value))
    }
    fn same(&self, other: &Owned) -> bool {
        // SAFETY: both are live CF objects.
        unsafe { CFEqual(self.0, other.0) }
    }
    fn has_type(&self, id: usize) -> bool {
        // SAFETY: live CF object.
        unsafe { CFGetTypeID(self.0) == id }
    }
}
impl Clone for Owned {
    fn clone(&self) -> Owned {
        // SAFETY: live CF object; the clone owns one more reference.
        Owned(unsafe { CFRetain(self.0) })
    }
}
impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: this reference came from a Create or Copy call or CFRetain.
        unsafe { CFRelease(self.0) }
    }
}

fn cf_string(text: &CStr) -> Owned {
    // SAFETY: a valid C string; the attribute names here are ASCII, so creation can't fail.
    Owned(unsafe { CFStringCreateWithCString(std::ptr::null(), text.as_ptr(), UTF8) })
}

fn bounded(element: Owned) -> Owned {
    // SAFETY: a live AX element.
    unsafe { AXUIElementSetMessagingTimeout(element.0, MESSAGING_TIMEOUT) };
    element
}

fn attribute(element: &Owned, name: &CStr) -> Result<Owned, i32> {
    let mut raw = std::ptr::null();
    // SAFETY: a live element and attribute name; a success gives a reference we own.
    let status = unsafe { AXUIElementCopyAttributeValue(element.0, cf_string(name).0, &mut raw) };
    if status != AX_SUCCESS {
        return Err(status);
    }
    Owned::new(raw).ok_or(status)
}

fn ax_element(element: &Owned, name: &CStr) -> Option<Owned> {
    // SAFETY: only reads a type ID.
    attribute(element, name).ok().filter(|v| v.has_type(unsafe { AXUIElementGetTypeID() })).map(bounded)
}

fn to_string(value: &Owned) -> Option<String> {
    // SAFETY: only reads a type ID.
    if !value.has_type(unsafe { CFStringGetTypeID() }) {
        return None;
    }
    // SAFETY: the buffer has the size CoreFoundation asks for, and it's nul-terminated on success.
    unsafe {
        let size = CFStringGetMaximumSizeForEncoding(CFStringGetLength(value.0), UTF8) + 1;
        let mut buffer = vec![0u8; size as usize];
        CFStringGetCString(value.0, buffer.as_mut_ptr().cast(), size, UTF8).then(|| CStr::from_ptr(buffer.as_ptr().cast()).to_string_lossy().into_owned())
    }
}

fn subrole_is_secure(element: &Owned) -> bool {
    attribute(element, c"AXSubrole").ok().and_then(|v| to_string(&v)).as_deref() == Some("AXSecureTextField")
}

fn selected_range(element: &Owned) -> Option<Span> {
    let value = attribute(element, c"AXSelectedTextRange").ok()?;
    // SAFETY: only reads a type ID.
    if !value.has_type(unsafe { AXValueGetTypeID() }) {
        return None;
    }
    let mut range = CfRange::default();
    // SAFETY: `value` is an AXValue and `range` is the CFRange that kind fills.
    unsafe { AXValueGetValue(value.0, VALUE_CF_RANGE, (&raw mut range).cast()) }.then_some(Span { location: range.location, length: range.length })
}

fn number_of_characters(element: &Owned) -> Option<i64> {
    let value = attribute(element, c"AXNumberOfCharacters").ok()?;
    // SAFETY: only reads a type ID.
    if !value.has_type(unsafe { CFNumberGetTypeID() }) {
        return None;
    }
    let mut count = 0i64;
    // SAFETY: `value` is a CFNumber and `count` is the i64 asked for.
    unsafe { CFNumberGetValue(value.0, NUMBER_I64, (&raw mut count).cast()) }.then_some(count)
}

fn string_for_range(element: &Owned, span: Span) -> Option<String> {
    let range = CfRange { location: span.location, length: span.length };
    // SAFETY: `range` is the CFRange that kind copies.
    let parameter = Owned::new(unsafe { AXValueCreate(VALUE_CF_RANGE, (&raw const range).cast()) })?;
    let mut raw = std::ptr::null();
    // SAFETY: live element, name and parameter; a success gives a reference we own.
    let status = unsafe { AXUIElementCopyParameterizedAttributeValue(element.0, cf_string(c"AXStringForRange").0, parameter.0, &mut raw) };
    if status != AX_SUCCESS {
        return None;
    }
    to_string(&Owned::new(raw)?)
}

/// The app side, through `NSWorkspace` and `NSRunningApplication`.
#[derive(Clone, PartialEq)]
struct App {
    pid: i32,
    launch: Option<u64>,
    bundle: Option<String>,
}

unsafe fn send(receiver: Id, selector: &CStr) -> Id {
    // SAFETY: the caller names a selector taking no arguments and returning an object.
    unsafe {
        let f: unsafe extern "C" fn(Id, Id) -> Id = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        f(receiver, sel_registerName(selector.as_ptr()))
    }
}
unsafe fn send1(receiver: Id, selector: &CStr, argument: Id) -> Id {
    // SAFETY: the caller names a selector taking one object and returning an object or BOOL-sized value.
    unsafe {
        let f: unsafe extern "C" fn(Id, Id, Id) -> Id = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        f(receiver, sel_registerName(selector.as_ptr()), argument)
    }
}
unsafe fn class(name: &CStr) -> Id {
    // SAFETY: a valid C string.
    unsafe { objc_getClass(name.as_ptr()) }
}
unsafe fn ns_text(value: &str) -> Id {
    let text = CString::new(value.replace('\0', "")).unwrap_or_default();
    // SAFETY: `stringWithUTF8String:` copies a valid C string.
    unsafe {
        let f: unsafe extern "C" fn(Id, Id, *const c_char) -> Id = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        f(class(c"NSString"), sel_registerName(c"stringWithUTF8String:".as_ptr()), text.as_ptr())
    }
}
unsafe fn rust_text(value: Id) -> Option<String> {
    if value.is_null() {
        return None;
    }
    // SAFETY: `value` is an NSString; UTF8String lives as long as the autorelease pool.
    let utf8 = unsafe { send(value, c"UTF8String") } as *const c_char;
    // SAFETY: a nul-terminated C string, checked for null.
    (!utf8.is_null()).then(|| unsafe { CStr::from_ptr(utf8) }.to_string_lossy().into_owned())
}
unsafe fn count(array: Id) -> usize {
    // SAFETY: `count` returns NSUInteger in the object register.
    if array.is_null() { 0 } else { unsafe { send(array, c"count") as usize } }
}
unsafe fn at(array: Id, index: usize) -> Id {
    // SAFETY: the index was bounded by `count`.
    unsafe { send1(array, c"objectAtIndex:", index as Id) }
}

/// Background threads have no pool of their own.
fn pooled<T>(f: impl FnOnce() -> T) -> T {
    // SAFETY: push and pop are paired on this thread.
    unsafe {
        let pool = objc_autoreleasePoolPush();
        let out = f();
        objc_autoreleasePoolPop(pool);
        out
    }
}

unsafe fn app_of(application: Id) -> Option<App> {
    if application.is_null() {
        return None;
    }
    // SAFETY: an NSRunningApplication; `processIdentifier` returns pid_t and `launchDate` an NSDate or nil.
    unsafe {
        let pid: unsafe extern "C" fn(Id, Id) -> i32 = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        let date = send(application, c"launchDate");
        let since: unsafe extern "C" fn(Id, Id) -> f64 = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        let launch = (!date.is_null()).then(|| since(date, sel_registerName(c"timeIntervalSince1970".as_ptr())).to_bits());
        Some(App { pid: pid(application, sel_registerName(c"processIdentifier".as_ptr())), launch, bundle: rust_text(send(application, c"bundleIdentifier")) })
    }
}

fn frontmost() -> Option<App> {
    // SAFETY: `frontmostApplication` is a getter Swift also reads off the main thread.
    unsafe { app_of(send(send(class(c"NSWorkspace"), c"sharedWorkspace"), c"frontmostApplication")) }
}

fn app_by_pid(pid: i32) -> Option<App> {
    // SAFETY: the selector takes a pid_t and returns an object or nil.
    unsafe {
        let f: unsafe extern "C" fn(Id, Id, i32) -> Id = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        app_of(f(class(c"NSRunningApplication"), sel_registerName(c"runningApplicationWithProcessIdentifier:".as_ptr()), pid))
    }
}

/// `runningApps`: regular apps with a bundle ID, as (name, id).
pub(crate) fn running_apps() -> Vec<(String, String)> {
    pooled(|| {
        // SAFETY: `runningApplications` returns an NSArray of NSRunningApplication; `activationPolicy` an NSInteger.
        unsafe {
            let apps = send(send(class(c"NSWorkspace"), c"sharedWorkspace"), c"runningApplications");
            (0..count(apps))
                .filter_map(|i| {
                    let app = at(apps, i);
                    if send(app, c"activationPolicy") as i64 != ACTIVATION_REGULAR {
                        return None;
                    }
                    let id = rust_text(send(app, c"bundleIdentifier"))?;
                    let name = rust_text(send(app, c"localizedName")).unwrap_or_else(|| id.clone());
                    Some((name, id))
                })
                .collect()
        }
    })
}

fn pasteboard() -> Id {
    // SAFETY: a class method returning the shared pasteboard.
    unsafe { send(class(c"NSPasteboard"), c"generalPasteboard") }
}

fn change_count() -> i64 {
    // SAFETY: `changeCount` returns NSInteger.
    unsafe { send(pasteboard(), c"changeCount") as i64 }
}

/// `PasteboardSnapshot`.
struct Snapshot(Vec<Vec<(String, Vec<u8>)>>);

impl Snapshot {
    /// None past the limit; the paste is then skipped.
    fn take() -> Option<Snapshot> {
        let mut total = 0;
        let mut items = vec![];
        // SAFETY: the arrays and data objects stay alive in the enclosing autorelease pool.
        unsafe {
            let all = send(pasteboard(), c"pasteboardItems");
            for i in 0..count(all) {
                let item = at(all, i);
                let types = send(item, c"types");
                let mut entries = vec![];
                for t in 0..count(types) {
                    let kind = at(types, t);
                    let data = send1(item, c"dataForType:", kind);
                    if data.is_null() {
                        continue;
                    }
                    let length = send(data, c"length") as usize;
                    total += length;
                    if total > SNAPSHOT_LIMIT {
                        return None;
                    }
                    let bytes = send(data, c"bytes") as *const u8;
                    entries.push((rust_text(kind)?, if length == 0 { vec![] } else { std::slice::from_raw_parts(bytes, length).to_vec() }));
                }
                items.push(entries);
            }
        }
        Some(Snapshot(items))
    }

    fn restore(&self) {
        // SAFETY: new objects are retained by the array and the pasteboard; each selector matches its arguments.
        unsafe {
            send(pasteboard(), c"clearContents");
            if self.0.is_empty() {
                return;
            }
            let list = send(class(c"NSMutableArray"), c"array");
            for entries in &self.0 {
                let item = new_item();
                for (kind, data) in entries {
                    set_data(item, kind, data);
                }
                send1(list, c"addObject:", item);
            }
            send1(pasteboard(), c"writeObjects:", list);
        }
    }
}

unsafe fn new_item() -> Id {
    // SAFETY: alloc, init, autorelease is the ordinary new object.
    unsafe { send(send(send(class(c"NSPasteboardItem"), c"alloc"), c"init"), c"autorelease") }
}

unsafe fn set_data(item: Id, kind: &str, data: &[u8]) {
    // SAFETY: `dataWithBytes:length:` copies the slice; `setData:forType:` takes two objects.
    unsafe {
        let make: unsafe extern "C" fn(Id, Id, *const u8, usize) -> Id = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        let set: unsafe extern "C" fn(Id, Id, Id, Id) -> bool = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        let bytes = make(class(c"NSData"), sel_registerName(c"dataWithBytes:length:".as_ptr()), data.as_ptr(), data.len());
        set(item, sel_registerName(c"setData:forType:".as_ptr()), bytes, ns_text(kind));
    }
}

/// Writes `text` as the only item. `transient` asks clipboard managers to skip it (nspasteboard.org).
fn write_text(text: &str, transient: bool) -> bool {
    // SAFETY: as `restore`; `setString:forType:` takes two objects.
    unsafe {
        send(pasteboard(), c"clearContents");
        let item = new_item();
        let set: unsafe extern "C" fn(Id, Id, Id, Id) -> bool = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        set(item, sel_registerName(c"setString:forType:".as_ptr()), ns_text(text), ns_text("public.utf8-plain-text"));
        if transient {
            set_data(item, "org.nspasteboard.TransientType", &[]);
        }
        let list = send1(class(c"NSArray"), c"arrayWithObject:", item);
        // `writeObjects:` returns BOOL in the low byte.
        let write: unsafe extern "C" fn(Id, Id, Id) -> bool = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        write(pasteboard(), sel_registerName(c"writeObjects:".as_ptr()), list)
    }
}

fn key_pair(key: u16) -> Option<(Owned, Owned)> {
    // SAFETY: the source is private state, as Swift's; a failure is a null we check.
    unsafe {
        let source = Owned::new(CGEventSourceCreate(PRIVATE_STATE))?;
        Some((Owned::new(CGEventCreateKeyboardEvent(source.0, key, true))?, Owned::new(CGEventCreateKeyboardEvent(source.0, key, false))?))
    }
}

static ASKED: Mutex<Option<HashSet<i32>>> = Mutex::new(None);

/// `ChromiumAccessibility.enable`: Electron builds its tree only when asked. Others reject it, harmlessly.
// ponytail: asked at the press, not at each activation, so the first press in a new Electron app can
// find no field; an NSWorkspace observer needs a run-loop home. A reused pid isn't asked again.
fn enable_chromium(pid: i32) {
    let mut guard = ASKED.lock().unwrap();
    if pid <= 0 || !guard.get_or_insert_default().insert(pid) {
        return;
    }
    drop(guard);
    // SAFETY: a new application element, and the CF boolean constant.
    unsafe {
        let Some(application) = Owned::new(AXUIElementCreateApplication(pid)) else { return };
        AXUIElementSetMessagingTimeout(application.0, 0.1);
        AXUIElementSetAttributeValue(application.0, cf_string(c"AXManualAccessibility").0, kCFBooleanTrue);
    }
}

fn focused_element() -> Option<Owned> {
    // SAFETY: only reads the trust state.
    if !unsafe { AXIsProcessTrusted() } {
        return None;
    }
    let front = frontmost()?;
    enable_chromium(front.pid);
    // SAFETY: creating the system-wide element has no preconditions.
    let system = bounded(Owned::new(unsafe { AXUIElementCreateSystemWide() })?);
    let element = attribute(&system, c"AXFocusedUIElement").ok().or_else(|| {
        // Some apps expose focus only through their application AX object.
        // SAFETY: a pid from NSWorkspace.
        let application = bounded(Owned::new(unsafe { AXUIElementCreateApplication(front.pid) })?);
        attribute(&application, c"AXFocusedUIElement").ok()
    })?;
    // SAFETY: only reads a type ID.
    if !element.has_type(unsafe { AXUIElementGetTypeID() }) {
        return None;
    }
    let element = bounded(element);
    let mut pid = 0;
    // SAFETY: a live AX element.
    let status = unsafe { AXUIElementGetPid(element.0, &mut pid) };
    (status == AX_SUCCESS && pid == front.pid && frontmost().is_some_and(|f| f.pid == pid)).then_some(element)
}

fn focused_window(pid: i32) -> Option<Owned> {
    // SAFETY: creating an element for a pid only allocates.
    let application = bounded(Owned::new(unsafe { AXUIElementCreateApplication(pid) })?);
    ax_element(&application, c"AXFocusedWindow")
}

/// One captured field.
#[derive(Clone)]
struct Held {
    pid: i32,
    launch: u64,
    bundle: String,
    element: Owned,
    window: Owned,
    range: Span,
    context: String,
    after: Option<String>,
    paste: bool,
}

/// `pasteTarget`: the frontmost terminal's focused window. Its text is never read.
fn paste_target() -> Option<Held> {
    // SAFETY: only reads the trust state.
    if !unsafe { AXIsProcessTrusted() } {
        return None;
    }
    let front = frontmost()?;
    let bundle = front.bundle?;
    if !flow_core::settings::is_terminal(&bundle) {
        return None;
    }
    let window = focused_window(front.pid)?;
    Some(Held { pid: front.pid, launch: front.launch?, bundle, element: focused_element().unwrap_or_else(|| window.clone()), window, range: Span { location: 0, length: 0 }, context: String::new(), after: None, paste: true })
}

/// `makeTarget`.
fn make_target(element: Owned) -> Option<Held> {
    let mut pid = 0;
    // SAFETY: a live AX element.
    if unsafe { AXUIElementGetPid(element.0, &mut pid) } != AX_SUCCESS {
        return None;
    }
    let application = app_by_pid(pid)?;
    let bundle = application.bundle.filter(|b| b.len() <= 255)?;
    let launch = application.launch?;
    let range = selected_range(&element)?;
    if range.location < 0 || range.length < 0 || range.length > insert::CONTEXT_UNITS || subrole_is_secure(&element) {
        return None;
    }
    let window = ax_element(&element, c"AXWindow")?;
    let mut settable = 0u8;
    // SAFETY: a live element and name, and a Boolean out value.
    if unsafe { AXUIElementIsAttributeSettable(element.0, cf_string(c"AXSelectedText").0, &mut settable) } != AX_SUCCESS || settable == 0 {
        return None;
    }
    let context = string_for_range(&element, insert::comparison_range(range)?).filter(|c| c.encode_utf16().count() as i64 <= insert::CONTEXT_UNITS)?;
    let after = number_of_characters(&element).and_then(|count| insert::after_range(range, count, AFTER_UNITS)).and_then(|span| if span.length == 0 { Some(String::new()) } else { string_for_range(&element, span) });
    Some(Held { pid, launch, bundle, element, window, range, context, after, paste: false })
}

fn capture() -> Option<Held> {
    if let Some(target) = paste_target() {
        return Some(target);
    }
    let target = make_target(focused_element()?)?;
    Attempt(&target).same_field().then_some(target)
}

/// Implements the pure insertion's target for one attempt.
struct Attempt<'a>(&'a Held);

impl Attempt<'_> {
    fn rejected_paste(&self) -> Option<Issue> {
        let target = self.0;
        let Some(front) = frontmost() else { return Some(Issue::FocusChanged) };
        if front.bundle.as_deref() != Some(&target.bundle) {
            return Some(Issue::FocusChanged);
        }
        if front.pid != target.pid || front.launch != Some(target.launch) {
            return Some(Issue::StaleProcess);
        }
        if !focused_window(target.pid).is_some_and(|w| w.same(&target.window)) {
            return Some(Issue::FocusChanged);
        }
        // SAFETY: no arguments, no preconditions. Secure input means a password prompt.
        unsafe { IsSecureEventInputEnabled() }.then_some(Issue::SecureField)
    }
}

impl Target for Attempt<'_> {
    fn rejected(&self) -> Option<Issue> {
        // SAFETY: only reads the trust state.
        if !unsafe { AXIsProcessTrusted() } {
            return Some(Issue::AccessibilityDenied);
        }
        let target = self.0;
        if target.paste {
            return self.rejected_paste();
        }
        let Some(current) = capture() else { return Some(Issue::FocusChanged) };
        if current.pid != target.pid || current.launch != target.launch || current.bundle != target.bundle {
            return Some(Issue::StaleProcess);
        }
        if !current.element.same(&target.element) || !current.window.same(&target.window) || current.context != target.context || current.after != target.after {
            return Some(Issue::FocusChanged);
        }
        (current.range != target.range).then_some(Issue::SelectionChanged)
    }
    fn is_paste(&self) -> bool {
        self.0.paste
    }
    fn paste(&self, text: &str) -> Dispatch {
        let Some(saved) = Snapshot::take() else { return Dispatch::NoMutation };
        if !write_text(text, true) {
            saved.restore();
            return Dispatch::NoMutation;
        }
        let written = change_count();
        // No wait between validation and the process-targeted events.
        let keys = if self.rejected().is_none() { key_pair(VK_V) } else { None };
        let Some((down, up)) = keys else {
            saved.restore();
            return Dispatch::NoMutation;
        };
        // Only the flag: Terminal beeps at a Command-V that also carries a Unicode string.
        // SAFETY: live events and a validated pid.
        unsafe {
            CGEventSetFlags(down.0, COMMAND_FLAG);
            CGEventSetFlags(up.0, COMMAND_FLAG);
            CGEventPostToPid(self.0.pid, down.0);
            CGEventPostToPid(self.0.pid, up.0);
        }
        std::thread::spawn(move || {
            std::thread::sleep(RESTORE_DELAY);
            pooled(|| {
                if change_count() == written {
                    saved.restore();
                }
            });
        });
        Dispatch::Pasted
    }
    fn same_field(&self) -> bool {
        let target = self.0;
        let Some(element) = focused_element() else { return false };
        element.same(&target.element) && app_by_pid(target.pid).is_some_and(|a| a.launch == Some(target.launch) && a.bundle.as_deref() == Some(&target.bundle)) && ax_element(&element, c"AXWindow").is_some_and(|w| w.same(&target.window)) && !subrole_is_secure(&element)
    }
    fn post(&self, chunk: &str) -> bool {
        let Some((down, up)) = key_pair(0) else { return false };
        let units: Vec<u16> = chunk.encode_utf16().collect();
        // SAFETY: live events; `units` outlives the call, which copies it.
        unsafe {
            for event in [&down, &up] {
                CGEventSetFlags(event.0, 0);
                CGEventKeyboardSetUnicodeString(event.0, units.len(), units.as_ptr());
            }
            CGEventPostToPid(self.0.pid, down.0);
            CGEventPostToPid(self.0.pid, up.0);
        }
        true
    }
    fn read_back(&self, units: i64) -> Result<String, Issue> {
        let element = &self.0.element;
        let selection = selected_range(element).ok_or(Issue::Unsupported)?;
        let range = insert::confirmation_range(units, selection).ok_or(Issue::SelectionChanged)?;
        let value = string_for_range(element, range).filter(|v| v.len() <= insert::MAX_TEXT_BYTES).ok_or(Issue::Unsupported)?;
        if !self.same_field() {
            return Err(Issue::FocusChanged);
        }
        Ok(value)
    }
}

/// The captured fields, by the token the portable target carries. AX references can't leave the
/// platform, and the oldest goes first so a long session can't grow it.
#[derive(Default)]
struct Registry {
    next: AtomicU64,
    held: Mutex<(HashMap<u64, Held>, VecDeque<u64>)>,
    /// `activeAttempt`: one attempt at a time.
    attempt: Mutex<()>,
}

pub struct MacInserter(Registry);

pub(crate) fn shared() -> Arc<MacInserter> {
    static SHARED: OnceLock<Arc<MacInserter>> = OnceLock::new();
    SHARED.get_or_init(|| Arc::new(MacInserter(Registry::default()))).clone()
}

impl Inserter for MacInserter {
    fn capture_target(&self) -> Option<CapturedTarget> {
        pooled(|| {
            let target = capture()?;
            let token = self.0.next.fetch_add(1, SeqCst) + 1;
            let captured = CapturedTarget { bundle_id: target.bundle.clone(), own_process: target.pid == std::process::id() as i32, delivery: if target.paste { InsertDelivery::Paste } else { InsertDelivery::Accessibility }, selection_location: target.range.location as _, token };
            let mut held = self.0.held.lock().unwrap();
            held.0.insert(token, target);
            held.1.push_back(token);
            if held.1.len() > HELD_TARGETS {
                let oldest = held.1.pop_front().unwrap();
                held.0.remove(&oldest);
            }
            Some(captured)
        })
    }
    fn insert_once(&self, target: &CapturedTarget, text: &str) -> InsertOutcome {
        let Some(held) = self.0.held.lock().unwrap().0.get(&target.token).cloned() else { return InsertOutcome::NotInserted };
        let Ok(_attempt) = self.0.attempt.try_lock() else { return InsertOutcome::Uncertain };
        pooled(|| insert::insert_once(&Attempt(&held), text))
    }
    /// `CapturedTarget.readText`: only while that app is still in front. Selection changes recreate
    /// the focused element in web views, so a stale one is read through the focus again.
    fn read_text(&self, target: &CapturedTarget, location: usize, length: usize) -> Result<String, ()> {
        let held = self.0.held.lock().unwrap().0.get(&target.token).cloned().ok_or(())?;
        if held.paste || length == 0 || length > 8_192 {
            return Err(());
        }
        pooled(|| {
            let front = frontmost().ok_or(())?;
            if front.pid != held.pid || front.launch != Some(held.launch) {
                return Err(());
            }
            let read = |element: &Owned| {
                let total = number_of_characters(element);
                if total.is_some_and(|t| t <= location as i64) {
                    return None;
                }
                let clamped = total.map_or(length as i64, |t| (length as i64).min(t - location as i64));
                string_for_range(element, Span { location: location as i64, length: clamped }).filter(|v| v.len() <= 64 * 1024)
            };
            read(&held.element).or_else(|| focused_element().as_ref().and_then(read)).ok_or(())
        })
    }
    fn copy(&self, text: &str) {
        pooled(|| {
            write_text(text, false);
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_range_layout_matches_cfrange() {
        assert_eq!(size_of::<CfRange>(), 16);
    }
}
