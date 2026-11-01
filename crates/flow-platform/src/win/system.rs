//! Windows system services for `Win`.
use crate::win_rules::{input_kind, microphone_denied, process_loopback_supported, run_value};
use crate::{InputCatalog, InputDevice, Unavailable};
use ::windows::Win32::Devices::FunctionDiscovery::{PKEY_Device_EnumeratorName, PKEY_Device_FriendlyName};
use ::windows::Win32::Foundation::{ERROR_FILE_NOT_FOUND, ERROR_SUCCESS};
use ::windows::Win32::Media::Audio::{DEVICE_STATE_ACTIVE, IMMDeviceEnumerator, MMDeviceEnumerator, eCapture, eConsole};
use ::windows::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;
use ::windows::Win32::System::Com::{CLSCTX_ALL, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx, CoUninitialize, STGM_READ};
use ::windows::Win32::System::Registry::{HKEY, HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, REG_SZ, RRF_RT_REG_SZ, RegDeleteKeyValueW, RegGetValueW, RegSetKeyValueW};
use ::windows::Win32::UI::Accessibility::{HCF_HIGHCONTRASTON, HIGHCONTRASTW};
use ::windows::Win32::UI::Shell::ShellExecuteW;
use ::windows::Win32::UI::WindowsAndMessaging::{SPI_GETCLIENTAREAANIMATION, SPI_GETHIGHCONTRAST, SW_SHOWNORMAL, SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS, SystemParametersInfoW};
use ::windows::core::{BOOL, HSTRING, PCWSTR, w};
use std::path::Path;

const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
const RUN_VALUE: &str = "LocalFlow";
const CONSENT: &str = r"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";

/// Hands `target` to the shell, with no console window. ShellExecute reports success above 32.
pub fn shell_open(target: &str) -> Result<(), Unavailable> {
    let result = unsafe { ShellExecuteW(None, w!("open"), &HSTRING::from(target), None, None, SW_SHOWNORMAL) };
    if result.0 as isize > 32 { Ok(()) } else { Err(Unavailable("opening a link")) }
}

/// A link from the app: web addresses only, so a stored URL can't launch a program.
pub fn open_url(url: &str) -> Result<(), Unavailable> {
    if url.starts_with("https://") || url.starts_with("http://") { shell_open(url) } else { Err(Unavailable("opening a link")) }
}

/// A `REG_SZ`. `None` when absent or unreadable.
pub fn registry_string(root: HKEY, key: &str, value: &str) -> Option<String> {
    let (key, value) = (HSTRING::from(key), HSTRING::from(value));
    let mut size = 0u32;
    let first = unsafe { RegGetValueW(root, &key, &value, RRF_RT_REG_SZ, None, None, Some(&mut size)) };
    if first != ERROR_SUCCESS {
        return None;
    }
    let mut text = vec![0u16; (size as usize).div_ceil(2)];
    let second = unsafe { RegGetValueW(root, &key, &value, RRF_RT_REG_SZ, None, Some(text.as_mut_ptr().cast()), Some(&mut size)) };
    if second != ERROR_SUCCESS {
        return None;
    }
    let length = text.iter().position(|c| *c == 0).unwrap_or(text.len());
    Some(String::from_utf16_lossy(&text[..length]))
}

pub fn launch_at_login() -> Result<bool, Unavailable> {
    Ok(registry_string(HKEY_CURRENT_USER, RUN_KEY, RUN_VALUE).is_some())
}

pub fn set_launch_at_login(on: bool) -> Result<(), Unavailable> {
    const UNAVAILABLE: Unavailable = Unavailable("Run registry key");
    let (key, name) = (HSTRING::from(RUN_KEY), HSTRING::from(RUN_VALUE));
    if !on {
        let result = unsafe { RegDeleteKeyValueW(HKEY_CURRENT_USER, &key, &name) };
        return if result == ERROR_SUCCESS || result == ERROR_FILE_NOT_FOUND { Ok(()) } else { Err(UNAVAILABLE) };
    }
    let exe = std::env::current_exe().map_err(|_| UNAVAILABLE)?;
    let value: Vec<u16> = run_value(&exe.to_string_lossy()).encode_utf16().chain([0]).collect();
    let result = unsafe { RegSetKeyValueW(HKEY_CURRENT_USER, &key, &name, REG_SZ.0, Some(value.as_ptr().cast()), (value.len() * 2) as u32) };
    if result == ERROR_SUCCESS { Ok(()) } else { Err(UNAVAILABLE) }
}

pub fn free_disk_bytes(path: &Path) -> Option<u64> {
    let mut free = 0u64;
    unsafe { GetDiskFreeSpaceExW(&HSTRING::from(path), Some(&mut free), None, None) }.ok()?;
    Some(free)
}

pub fn high_contrast() -> bool {
    let mut contrast = HIGHCONTRASTW { cbSize: size_of::<HIGHCONTRASTW>() as u32, ..Default::default() };
    let ok = unsafe { SystemParametersInfoW(SPI_GETHIGHCONTRAST, contrast.cbSize, Some((&mut contrast as *mut HIGHCONTRASTW).cast()), SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0)) };
    ok.is_ok() && contrast.dwFlags.contains(HCF_HIGHCONTRASTON)
}

/// Settings > Accessibility > Animation effects.
pub fn reduce_motion() -> bool {
    let mut animate = BOOL(1);
    let ok = unsafe { SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, Some((&mut animate as *mut BOOL).cast()), SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0)) };
    ok.is_ok() && !animate.as_bool()
}

pub fn microphone_consent_denied() -> bool {
    let nonpackaged = format!(r"{CONSENT}\NonPackaged");
    microphone_denied(&[registry_string(HKEY_LOCAL_MACHINE, CONSENT, "Value"), registry_string(HKEY_CURRENT_USER, CONSENT, "Value"), registry_string(HKEY_CURRENT_USER, &nonpackaged, "Value")])
}

pub fn process_loopback_available() -> bool {
    process_loopback_supported(registry_string(HKEY_LOCAL_MACHINE, r"SOFTWARE\Microsoft\Windows NT\CurrentVersion", "CurrentBuildNumber").as_deref())
}

/// Active capture endpoints. COM runs on a short-lived thread, because the caller is the UI thread,
/// which has its own apartment.
pub fn input_catalog() -> Option<InputCatalog> {
    std::thread::spawn(|| unsafe {
        CoInitializeEx(None, COINIT_MULTITHREADED).ok().ok()?;
        let catalog = read_catalog().ok();
        CoUninitialize();
        catalog
    })
    .join()
    .ok()
    .flatten()
}

unsafe fn read_catalog() -> ::windows::core::Result<InputCatalog> {
    unsafe {
        let enumerator: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)?;
        let default = enumerator.GetDefaultAudioEndpoint(eCapture, eConsole).and_then(|d| d.GetId()).map(|id| { let text = id.to_string().unwrap_or_default(); ::windows::Win32::System::Com::CoTaskMemFree(Some(id.0 as _)); text }).ok();
        let endpoints = enumerator.EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE)?;
        let mut catalog = InputCatalog::default();
        for index in 0..endpoints.GetCount()? {
            let device = endpoints.Item(index)?;
            let id = device.GetId()?;
            let uid = id.to_string().unwrap_or_default();
            ::windows::Win32::System::Com::CoTaskMemFree(Some(id.0 as _));
            let store = device.OpenPropertyStore(STGM_READ)?;
            let name = store.GetValue(&PKEY_Device_FriendlyName).map(|v| v.to_string()).unwrap_or_default();
            let enumerator_name = store.GetValue(&PKEY_Device_EnumeratorName).map(|v| v.to_string()).unwrap_or_default();
            let device_id = index + 1;
            if default.as_deref() == Some(uid.as_str()) {
                catalog.default_input = Some(device_id);
            }
            catalog.devices.push(InputDevice { device_id, uid, model_uid: None, name, kind: input_kind(&enumerator_name), alive: true });
        }
        Ok(catalog)
    }
}

// The name is only used for a parameter default in Win32 metadata.
#[allow(dead_code)]
const _: PCWSTR = PCWSTR::null();
