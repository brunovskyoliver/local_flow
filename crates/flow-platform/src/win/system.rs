//! Windows system services for `Win`.
use crate::Unavailable;
use windows::Win32::UI::Shell::ShellExecuteW;
use windows::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;
use windows::core::{HSTRING, w};

/// Hands `target` to the shell, with no console window. ShellExecute reports success above 32.
pub fn shell_open(target: &str) -> Result<(), Unavailable> {
    let result = unsafe { ShellExecuteW(None, w!("open"), &HSTRING::from(target), None, None, SW_SHOWNORMAL) };
    if result.0 as isize > 32 { Ok(()) } else { Err(Unavailable("opening a link")) }
}

/// A link from the app: web addresses only, so a stored URL can't launch a program.
pub fn open_url(url: &str) -> Result<(), Unavailable> {
    if url.starts_with("https://") || url.starts_with("http://") { shell_open(url) } else { Err(Unavailable("opening a link")) }
}
