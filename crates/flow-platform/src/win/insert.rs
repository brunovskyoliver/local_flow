//! Insertion on Windows: UI Automation says which field has focus and refuses password fields, and
//! the text arrives by clipboard and a `SendInput` Ctrl-V. A target running elevated above this
//! process can't receive input (UIPI), so it counts as no target and the session's copy path runs.
use flow_core::dictation::insert::{self, Dispatch, Issue, PendingRestore, Target};
use flow_core::dictation::session::{CapturedTarget, InsertDelivery, InsertOutcome, Inserter};
use std::collections::{HashMap, VecDeque};
use crate::win_rules;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering::*};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use windows::Win32::Foundation::{CloseHandle, FILETIME, GlobalFree, HANDLE, HGLOBAL, HWND};
use windows::Win32::Security::{GetTokenInformation, TOKEN_ELEVATION, TOKEN_QUERY, TokenElevation};
use windows::Win32::System::Com::{CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx, CoUninitialize};
use windows::Win32::System::DataExchange::{CloseClipboard, EmptyClipboard, EnumClipboardFormats, GetClipboardData, GetClipboardSequenceNumber, OpenClipboard, RegisterClipboardFormatW, SetClipboardData};
use windows::Win32::System::Memory::{GMEM_MOVEABLE, GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock};
use windows::Win32::System::Ole::CF_UNICODETEXT;
use windows::Win32::System::Threading::{GetCurrentProcess, GetCurrentProcessId, GetProcessTimes, OpenProcess, OpenProcessToken, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION, QueryFullProcessImageNameW};
use windows::Win32::UI::Accessibility::{CUIAutomation, IUIAutomation, IUIAutomationElement};
use windows::Win32::UI::Input::KeyboardAndMouse::{INPUT, INPUT_0, INPUT_KEYBOARD, KEYBD_EVENT_FLAGS, KEYBDINPUT, KEYEVENTF_KEYUP, SendInput, VIRTUAL_KEY, VK_CONTROL, VK_V};
use windows::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId};
use windows::core::w;

const RESTORE_DELAY: Duration = Duration::from_secs(1);
const CLIPBOARD_LIMIT: usize = 32 * 1024 * 1024;
const HELD_TARGETS: usize = 8;

fn with_com<T>(f: impl FnOnce() -> T) -> T {
    // SAFETY: paired below only if it succeeded; the UI thread is already in its own apartment.
    let ours = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }.is_ok();
    let out = f();
    if ours {
        // SAFETY: pairs the successful call above.
        unsafe { CoUninitialize() };
    }
    out
}

struct Process(HANDLE);
impl Drop for Process {
    fn drop(&mut self) {
        // SAFETY: this handle came from OpenProcess.
        let _ = unsafe { CloseHandle(self.0) };
    }
}

fn open(pid: u32) -> Option<Process> {
    // SAFETY: an owned handle on success. An elevated process grants this limited right too.
    unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) }.ok().map(Process)
}

fn elevated(process: HANDLE) -> Option<bool> {
    let mut token = HANDLE::default();
    // SAFETY: an out handle, closed below.
    unsafe { OpenProcessToken(process, TOKEN_QUERY, &mut token) }.ok()?;
    let mut value = TOKEN_ELEVATION::default();
    let mut size = 0;
    // SAFETY: the buffer is a TOKEN_ELEVATION of the size passed.
    let read = unsafe { GetTokenInformation(token, TokenElevation, Some((&raw mut value).cast()), size_of::<TOKEN_ELEVATION>() as u32, &mut size) };
    // SAFETY: opened above.
    let _ = unsafe { CloseHandle(token) };
    read.ok()?;
    Some(value.TokenIsElevated != 0)
}

/// UIPI's rule as far as this needs it. A token that can't be read counts as above us.
fn blocked_by_uipi(target: HANDLE) -> bool {
    // SAFETY: the pseudo handle needs no closing.
    let own = elevated(unsafe { GetCurrentProcess() }).unwrap_or(false);
    elevated(target).is_none_or(|t| t && !own)
}

fn image_name(process: HANDLE) -> Option<String> {
    let mut buffer = [0u16; 1024];
    let mut size = buffer.len() as u32;
    // SAFETY: the buffer and its length.
    unsafe { QueryFullProcessImageNameW(process, PROCESS_NAME_WIN32, windows::core::PWSTR(buffer.as_mut_ptr()), &mut size) }.ok()?;
    let path = String::from_utf16_lossy(&buffer[..size as usize]);
    Some(Path::new(&path).file_name()?.to_string_lossy().to_ascii_lowercase())
}

fn created(process: HANDLE) -> Option<u64> {
    let (mut c, mut e, mut k, mut u) = (FILETIME::default(), FILETIME::default(), FILETIME::default(), FILETIME::default());
    // SAFETY: four out values.
    unsafe { GetProcessTimes(process, &mut c, &mut e, &mut k, &mut u) }.ok()?;
    Some(((c.dwHighDateTime as u64) << 32) | c.dwLowDateTime as u64)
}

fn automation() -> Option<IUIAutomation> {
    // SAFETY: an ordinary in-process COM creation.
    unsafe { CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER) }.ok()
}

fn focused(automation: &IUIAutomation) -> Option<IUIAutomationElement> {
    // SAFETY: a live interface.
    unsafe { automation.GetFocusedElement() }.ok()
}

/// A `RuntimeId` identifies the element across apartments, as a COM pointer can't.
fn runtime_id(element: &IUIAutomationElement) -> Option<Vec<i32>> {
    use windows::Win32::System::Ole::{SafeArrayDestroy, SafeArrayGetLBound, SafeArrayGetUBound, SafeArrayAccessData, SafeArrayUnaccessData};
    // SAFETY: a one-dimension SAFEARRAY of i32 that we own and destroy; the access is paired.
    unsafe {
        let array = element.GetRuntimeId().ok()?;
        let (low, high) = (SafeArrayGetLBound(array, 1).ok()?, SafeArrayGetUBound(array, 1).ok()?);
        let mut data = std::ptr::null_mut();
        SafeArrayAccessData(array, &mut data).ok()?;
        let id = std::slice::from_raw_parts(data as *const i32, (high - low + 1) as usize).to_vec();
        let _ = SafeArrayUnaccessData(array);
        let _ = SafeArrayDestroy(array);
        Some(id)
    }
}

fn secure_or_disabled(element: &IUIAutomationElement) -> bool {
    // SAFETY: a live interface; a failed read counts as refused.
    unsafe { element.CurrentIsPassword().map_or(true, |p| p.as_bool()) || element.CurrentIsEnabled().map_or(true, |e| !e.as_bool()) }
}

/// One captured field.
#[derive(Clone)]
struct Held {
    pid: u32,
    window: isize,
    created: u64,
    bundle: String,
    element: Vec<i32>,
}

fn foreground() -> Option<(HWND, u32)> {
    // SAFETY: no arguments; the out pid is a live u32.
    unsafe {
        let window = GetForegroundWindow();
        let mut pid = 0;
        GetWindowThreadProcessId(window, Some(&mut pid));
        (!window.is_invalid() && pid != 0).then_some((window, pid))
    }
}

fn capture() -> Option<Held> {
    let (window, pid) = foreground()?;
    let process = open(pid)?;
    if blocked_by_uipi(process.0) {
        return None;
    }
    let automation = automation()?;
    let element = focused(&automation)?;
    // SAFETY: a live interface.
    if unsafe { element.CurrentProcessId() }.ok()? as u32 != pid || secure_or_disabled(&element) {
        return None;
    }
    Some(Held { pid, window: window.0 as isize, created: created(process.0)?, bundle: image_name(process.0)?, element: runtime_id(&element)? })
}

/// The clipboard's formats, as (format, bytes). Formats held as GDI or private handles aren't kept:
/// a bitmap comes back through its `CF_DIB`.
// ponytail: an enhanced metafile with no other format doesn't come back. A GDI copy if that's seen.
type Saved = Vec<(u32, Vec<u8>)>;

/// The clipboard waiting to go back.
static PENDING: PendingRestore<Saved> = PendingRestore::new();

fn sequence() -> i64 {
    // SAFETY: no arguments.
    unsafe { GetClipboardSequenceNumber() as i64 }
}

/// One format, copied into a block the system owns on success.
fn put(format: u32, bytes: &[u8]) -> bool {
    // SAFETY: the block is at least as large as the copy; a block the system didn't take is freed.
    unsafe {
        let Ok(global) = GlobalAlloc(GMEM_MOVEABLE, bytes.len().max(1)) else { return false };
        let data = GlobalLock(global) as *mut u8;
        if data.is_null() {
            let _ = GlobalFree(Some(global));
            return false;
        }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), data, bytes.len());
        let _ = GlobalUnlock(global);
        if SetClipboardData(format, Some(HANDLE(global.0))).is_err() {
            let _ = GlobalFree(Some(global));
            return false;
        }
    }
    true
}

/// Keeps what's on the clipboard out of Win+V history, cloud sync and clipboard managers, as the Mac's
/// transient type does. A DWORD of 0 is what the two `Can…` formats read as no.
fn exclude_from_history() {
    for name in [w!("ExcludeClipboardContentFromMonitorProcessing"), w!("CanIncludeInClipboardHistory"), w!("CanUploadToCloudClipboard")] {
        // SAFETY: a valid wide string.
        put(unsafe { RegisterClipboardFormatW(name) }, &0u32.to_ne_bytes());
    }
}

struct Clipboard;
impl Clipboard {
    fn open() -> Option<Clipboard> {
        // Other apps hold it briefly, so a few short tries.
        for _ in 0..10 {
            // SAFETY: closed by Drop on success.
            if unsafe { OpenClipboard(None) }.is_ok() {
                return Some(Clipboard);
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        None
    }
    /// Everything it can copy, empty for an empty clipboard. None past the limit; the paste is then skipped.
    fn snapshot(&self) -> Option<Saved> {
        let (mut saved, mut total, mut format) = (vec![], 0, 0);
        // SAFETY: the clipboard is open; the lock is paired and the size is the block's own.
        unsafe {
            loop {
                format = EnumClipboardFormats(format);
                if format == 0 {
                    return Some(saved);
                }
                if !win_rules::clipboard_format_copyable(format) {
                    continue;
                }
                let Ok(handle) = GetClipboardData(format) else { continue };
                let global = HGLOBAL(handle.0);
                let size = GlobalSize(global);
                total += size;
                if total > CLIPBOARD_LIMIT {
                    return None;
                }
                if size == 0 {
                    continue;
                }
                let data = GlobalLock(global) as *const u8;
                if data.is_null() {
                    continue;
                }
                saved.push((format, std::slice::from_raw_parts(data, size).to_vec()));
                let _ = GlobalUnlock(global);
            }
        }
    }
    /// Empties it even when nothing was saved, so a transcript never stays behind.
    fn restore(&self, saved: &Saved) {
        // SAFETY: the clipboard is open.
        let _ = unsafe { EmptyClipboard() };
        for (format, bytes) in saved {
            put(*format, bytes);
        }
        exclude_from_history();
    }
    fn set(&self, text: &str, exclude: bool) -> bool {
        let bytes: Vec<u8> = text.encode_utf16().chain([0]).flat_map(u16::to_ne_bytes).collect();
        // SAFETY: the clipboard is open.
        let _ = unsafe { EmptyClipboard() };
        let written = put(CF_UNICODETEXT.0 as u32, &bytes);
        if written && exclude {
            exclude_from_history();
        }
        written
    }
}
impl Drop for Clipboard {
    fn drop(&mut self) {
        // SAFETY: only an open clipboard makes this value.
        let _ = unsafe { CloseClipboard() };
    }
}

fn key(key: VIRTUAL_KEY, up: bool) -> INPUT {
    let flags = if up { KEYEVENTF_KEYUP } else { KEYBD_EVENT_FLAGS(0) };
    INPUT { r#type: INPUT_KEYBOARD, Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: key, wScan: 0, dwFlags: flags, time: 0, dwExtraInfo: 0 } } }
}

fn put_back(saved: Saved) {
    if let Some(clipboard) = Clipboard::open() {
        clipboard.restore(&saved);
    }
}

struct Attempt<'a>(&'a Held);

impl Target for Attempt<'_> {
    fn rejected(&self) -> Option<Issue> {
        let target = self.0;
        let Some((window, pid)) = foreground() else { return Some(Issue::FocusChanged) };
        if pid != target.pid {
            return Some(Issue::FocusChanged);
        }
        let Some(process) = open(pid) else { return Some(Issue::StaleProcess) };
        if created(process.0) != Some(target.created) {
            return Some(Issue::StaleProcess);
        }
        if blocked_by_uipi(process.0) {
            return Some(Issue::Unsupported);
        }
        if window.0 as isize != target.window {
            return Some(Issue::FocusChanged);
        }
        let Some(element) = automation().and_then(|a| focused(&a)) else { return Some(Issue::FocusChanged) };
        if secure_or_disabled(&element) {
            return Some(Issue::SecureField);
        }
        (runtime_id(&element).as_ref() != Some(&target.element)).then_some(Issue::FocusChanged)
    }
    fn is_paste(&self) -> bool {
        true
    }
    fn paste(&self, text: &str) -> Dispatch {
        {
            let Some(clipboard) = Clipboard::open() else { return Dispatch::NoMutation };
            if !PENDING.prepare(sequence(), || clipboard.snapshot()) {
                return Dispatch::NoMutation;
            }
            if !clipboard.set(text, true) {
                PENDING.undo(|saved| clipboard.restore(&saved));
                return Dispatch::NoMutation;
            }
        }
        let generation = PENDING.written(sequence());
        // No wait between validation and the keys.
        let inputs = [key(VK_CONTROL, false), key(VK_V, false), key(VK_V, true), key(VK_CONTROL, true)];
        // SAFETY: the inputs are valid for the length and size passed. UIPI makes this return 0.
        let sent = if self.rejected().is_none() { unsafe { SendInput(&inputs, size_of::<INPUT>() as i32) } } else { 0 };
        if sent != inputs.len() as u32 {
            PENDING.undo(put_back);
            return Dispatch::NoMutation;
        }
        std::thread::spawn(move || {
            std::thread::sleep(RESTORE_DELAY);
            PENDING.settle(generation, sequence(), put_back);
        });
        Dispatch::Pasted
    }
    fn same_field(&self) -> bool {
        self.rejected().is_none()
    }
    fn post(&self, _: &str) -> bool {
        false
    }
    fn read_back(&self, _: i64) -> Result<String, Issue> {
        Err(Issue::Unsupported)
    }
}

#[derive(Default)]
pub struct WinInserter {
    next: AtomicU64,
    held: Mutex<(HashMap<u64, Held>, VecDeque<u64>)>,
    attempt: Mutex<()>,
}

pub(crate) fn shared() -> Arc<WinInserter> {
    static SHARED: OnceLock<Arc<WinInserter>> = OnceLock::new();
    SHARED.get_or_init(Default::default).clone()
}

impl Inserter for WinInserter {
    fn capture_target(&self) -> Option<CapturedTarget> {
        let target = with_com(capture)?;
        let token = self.next.fetch_add(1, SeqCst) + 1;
        // SAFETY: no arguments.
        let own_process = target.pid == unsafe { GetCurrentProcessId() };
        let captured = CapturedTarget { bundle_id: target.bundle.clone(), own_process, delivery: InsertDelivery::Paste, selection_location: 0, token };
        let mut held = self.held.lock().unwrap();
        held.0.insert(token, target);
        held.1.push_back(token);
        if held.1.len() > HELD_TARGETS {
            let oldest = held.1.pop_front().unwrap();
            held.0.remove(&oldest);
        }
        Some(captured)
    }
    fn insert_once(&self, target: &CapturedTarget, text: &str) -> InsertOutcome {
        let Some(held) = self.held.lock().unwrap().0.get(&target.token).cloned() else { return InsertOutcome::NotInserted };
        let Ok(_attempt) = self.attempt.try_lock() else { return InsertOutcome::Uncertain };
        with_com(|| insert::insert_once(&Attempt(&held), text))
    }
    fn copy(&self, text: &str) {
        if let Some(clipboard) = Clipboard::open() {
            clipboard.set(text, false);
        }
    }
    fn flush(&self) {
        PENDING.flush(sequence(), put_back);
    }
}
