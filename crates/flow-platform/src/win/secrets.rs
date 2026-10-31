//! Credential Manager generic credentials, with DPAPI protection supplied by it. The target is the
//! same `<service>/<account>` name the Mac splits. `LOCAL_MACHINE` persistence keeps them on this
//! PC, like Swift's `ThisDeviceOnly`.
use crate::Unavailable;
use ::windows::Win32::Foundation::ERROR_NOT_FOUND;
use ::windows::Win32::Security::Credentials::{CRED_FLAGS, CRED_MAX_CREDENTIAL_BLOB_SIZE, CRED_PERSIST_LOCAL_MACHINE, CRED_TYPE_GENERIC, CREDENTIALW, CredDeleteW, CredFree, CredReadW, CredWriteW};
use ::windows::core::{HSTRING, PWSTR};

const UNAVAILABLE: Unavailable = Unavailable("Credential Manager");

pub fn read(name: &str) -> Result<Option<Vec<u8>>, Unavailable> {
    let mut found: *mut CREDENTIALW = std::ptr::null_mut();
    // SAFETY: the name lives across the call; `found` is owned on success and freed below.
    match unsafe { CredReadW(&HSTRING::from(name), CRED_TYPE_GENERIC, None, &mut found) } {
        Ok(()) => {
            // SAFETY: `found` is valid until CredFree, and the blob pointer and size describe its value.
            unsafe {
                let credential = &*found;
                let value = if credential.CredentialBlob.is_null() { vec![] } else { std::slice::from_raw_parts(credential.CredentialBlob, credential.CredentialBlobSize as usize).to_vec() };
                CredFree(found as *const _);
                Ok(Some(value))
            }
        }
        Err(e) if e.code() == ERROR_NOT_FOUND.to_hresult() => Ok(None),
        Err(_) => Err(UNAVAILABLE),
    }
}

pub fn write(name: &str, value: &[u8]) -> Result<(), Unavailable> {
    if value.len() > CRED_MAX_CREDENTIAL_BLOB_SIZE as usize {
        return Err(Unavailable("a credential over Credential Manager's 2,560 bytes"));
    }
    if value.is_empty() {
        return Err(UNAVAILABLE);
    }
    let mut target: Vec<u16> = name.encode_utf16().chain([0]).collect();
    let credential = CREDENTIALW {
        Flags: CRED_FLAGS(0),
        Type: CRED_TYPE_GENERIC,
        TargetName: PWSTR(target.as_mut_ptr()),
        CredentialBlobSize: value.len() as u32,
        CredentialBlob: value.as_ptr() as *mut u8,
        Persist: CRED_PERSIST_LOCAL_MACHINE,
        ..Default::default()
    };
    // SAFETY: the target and blob outlive the call, which copies them and doesn't write through them.
    unsafe { CredWriteW(&credential, 0) }.map_err(|_| UNAVAILABLE)
}

pub fn remove(name: &str) -> Result<(), Unavailable> {
    // SAFETY: the name lives across the call.
    match unsafe { CredDeleteW(&HSTRING::from(name), CRED_TYPE_GENERIC, None) } {
        Ok(()) => Ok(()),
        Err(e) if e.code() == ERROR_NOT_FOUND.to_hresult() => Ok(()),
        Err(_) => Err(UNAVAILABLE),
    }
}
