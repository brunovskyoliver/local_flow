//! Secure Enclave P-256 through `enclave.swift`. The handle is CryptoKit's `dataRepresentation`, the
//! same bytes Swift keeps as `device-key`.
use crate::Unavailable;

unsafe extern "C" {
    fn lf_enclave_create(handle: *mut u8, handle_count: *mut isize, public_key: *mut u8) -> bool;
    fn lf_enclave_public_key(handle: *const u8, handle_count: isize, out: *mut u8) -> bool;
    fn lf_enclave_sign(handle: *const u8, handle_count: isize, message: *const u8, message_count: isize, out: *mut u8) -> bool;
}

const UNAVAILABLE: Unavailable = Unavailable("Secure Enclave");

/// (handle, X9.63 public key).
pub fn create() -> Result<(Vec<u8>, Vec<u8>), Unavailable> {
    let (mut handle, mut count, mut public) = (vec![0u8; 4096], 4096isize, vec![0u8; 65]);
    // SAFETY: `handle` holds `count` bytes and `public` the 65 the shim writes.
    if !unsafe { lf_enclave_create(handle.as_mut_ptr(), &mut count, public.as_mut_ptr()) } {
        return Err(UNAVAILABLE);
    }
    handle.truncate(count as usize);
    Ok((handle, public))
}

pub fn public_key(handle: &[u8]) -> Option<Vec<u8>> {
    let mut public = vec![0u8; 65];
    // SAFETY: the pointer and count describe `handle`; `public` holds the 65 the shim writes.
    unsafe { lf_enclave_public_key(handle.as_ptr(), handle.len() as isize, public.as_mut_ptr()) }.then_some(public)
}

/// Raw r||s.
pub fn sign(handle: &[u8], message: &[u8]) -> Result<Vec<u8>, Unavailable> {
    let mut raw = vec![0u8; 64];
    // SAFETY: each pointer and count describes its slice; `raw` holds the 64 the shim writes.
    let ok = unsafe { lf_enclave_sign(handle.as_ptr(), handle.len() as isize, message.as_ptr(), message.len() as isize, raw.as_mut_ptr()) };
    if ok { Ok(raw) } else { Err(UNAVAILABLE) }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Neither call creates a key or reaches the Keychain. The live path is in acceptance/hardware.md.
    #[test]
    fn a_handle_that_does_not_load_is_refused() {
        for handle in [&b""[..], b"not a key"] {
            assert_eq!(public_key(handle), None);
            assert_eq!(sign(handle, b"message"), Err(UNAVAILABLE));
        }
    }
}
