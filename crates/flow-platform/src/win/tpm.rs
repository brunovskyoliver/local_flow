//! A persisted P-256 key in the TPM through the Platform Crypto Provider, per user. No export policy
//! is set and there's no software fallback (spec, clarifications). The handle is the key's name.
use crate::Unavailable;
use ::windows::Win32::Security::Cryptography::{
    BCRYPT_ECCPUBLIC_BLOB, BCRYPT_SHA256_ALG_HANDLE, BCRYPT_USE_SYSTEM_PREFERRED_RNG, BCryptGenRandom, BCryptHash, CERT_KEY_SPEC, MS_PLATFORM_CRYPTO_PROVIDER, NCRYPT_ECDSA_P256_ALGORITHM, NCRYPT_FLAGS, NCRYPT_HANDLE, NCRYPT_KEY_HANDLE, NCRYPT_PROV_HANDLE,
    NCryptCreatePersistedKey, NCryptDeleteKey, NCryptExportKey, NCryptFinalizeKey, NCryptFreeObject, NCryptOpenKey, NCryptOpenStorageProvider, NCryptSignHash,
};
use ::windows::core::HSTRING;

const UNAVAILABLE: Unavailable = Unavailable("TPM");
const NAME_PREFIX: &str = "LocalFlow-Device-";

struct Provider(NCRYPT_PROV_HANDLE);
struct Key(NCRYPT_KEY_HANDLE);

impl Drop for Provider {
    fn drop(&mut self) {
        // SAFETY: opened by `provider`, freed once.
        let _ = unsafe { NCryptFreeObject(NCRYPT_HANDLE(self.0.0)) };
    }
}

impl Drop for Key {
    fn drop(&mut self) {
        // SAFETY: opened or created here, freed once; `delete` forgets the handle NCryptDeleteKey frees.
        let _ = unsafe { NCryptFreeObject(NCRYPT_HANDLE(self.0.0)) };
    }
}

fn provider() -> Result<Provider, Unavailable> {
    let mut handle = NCRYPT_PROV_HANDLE::default();
    // SAFETY: an out pointer and a constant provider name.
    unsafe { NCryptOpenStorageProvider(&mut handle, MS_PLATFORM_CRYPTO_PROVIDER, 0) }.map_err(|_| UNAVAILABLE)?;
    Ok(Provider(handle))
}

/// A name from our own `create`, so `delete` can't be pointed at another app's key.
fn name_of(handle: &[u8]) -> Option<HSTRING> {
    let name = std::str::from_utf8(handle).ok()?;
    name.starts_with(NAME_PREFIX).then(|| HSTRING::from(name))
}

fn open(handle: &[u8]) -> Result<Key, Unavailable> {
    let name = name_of(handle).ok_or(UNAVAILABLE)?;
    let provider = provider()?;
    let mut key = NCRYPT_KEY_HANDLE::default();
    // SAFETY: live provider, an out pointer, and a name that lives across the call.
    unsafe { NCryptOpenKey(provider.0, &mut key, &name, CERT_KEY_SPEC(0), NCRYPT_FLAGS(0)) }.map_err(|_| UNAVAILABLE)?;
    Ok(Key(key))
}

/// The 72-byte `BCRYPT_ECCPUBLIC_BLOB`, which `flow_core::remote::x963_public_key` converts.
fn export_public(key: &Key) -> Result<Vec<u8>, Unavailable> {
    let mut blob = vec![0u8; 72];
    let mut written = 0u32;
    // SAFETY: live key; the output slice and count are ours.
    unsafe { NCryptExportKey(key.0, None, BCRYPT_ECCPUBLIC_BLOB, None, Some(&mut blob), &mut written, NCRYPT_FLAGS(0)) }.map_err(|_| UNAVAILABLE)?;
    blob.truncate(written as usize);
    Ok(blob)
}

/// (handle, public key blob). Reports unavailable without a TPM.
pub fn create() -> Result<(Vec<u8>, Vec<u8>), Unavailable> {
    let mut id = [0u8; 16];
    // SAFETY: fills the slice from the system generator.
    unsafe { BCryptGenRandom(None, &mut id, BCRYPT_USE_SYSTEM_PREFERRED_RNG) }.ok().map_err(|_| UNAVAILABLE)?;
    let name = format!("{NAME_PREFIX}{}", id.iter().map(|b| format!("{b:02x}")).collect::<String>());
    let provider = provider()?;
    let mut key = NCRYPT_KEY_HANDLE::default();
    // SAFETY: live provider, an out pointer, and a name that lives across the call.
    unsafe { NCryptCreatePersistedKey(provider.0, &mut key, NCRYPT_ECDSA_P256_ALGORITHM, &HSTRING::from(&name), CERT_KEY_SPEC(0), NCRYPT_FLAGS(0)) }.map_err(|_| UNAVAILABLE)?;
    let key = Key(key);
    // SAFETY: the key was just created.
    let made = unsafe { NCryptFinalizeKey(key.0, NCRYPT_FLAGS(0)) }.map_err(|_| UNAVAILABLE).and_then(|_| export_public(&key));
    match made {
        Ok(public) => Ok((name.into_bytes(), public)),
        Err(e) => {
            // SAFETY: the key is live, and NCryptDeleteKey frees it, so its guard must not.
            let _ = unsafe { NCryptDeleteKey(key.0, 0) };
            std::mem::forget(key);
            Err(e)
        }
    }
}

pub fn public_key(handle: &[u8]) -> Option<Vec<u8>> {
    export_public(&open(handle).ok()?).ok()
}

/// Raw r||s over the SHA-256 of `message`.
pub fn sign(handle: &[u8], message: &[u8]) -> Result<Vec<u8>, Unavailable> {
    let key = open(handle)?;
    let mut digest = [0u8; 32];
    // SAFETY: a pseudo-handle and our own slices.
    unsafe { BCryptHash(BCRYPT_SHA256_ALG_HANDLE, None, message, &mut digest) }.ok().map_err(|_| UNAVAILABLE)?;
    let (mut raw, mut written) = (vec![0u8; 64], 0u32);
    // SAFETY: live key; no padding for ECDSA; the slices and count are ours.
    unsafe { NCryptSignHash(key.0, None, &digest, Some(&mut raw), &mut written, NCRYPT_FLAGS(0)) }.map_err(|_| UNAVAILABLE)?;
    if written != 64 {
        return Err(UNAVAILABLE);
    }
    Ok(raw)
}

/// A key that's already gone isn't an error: there's nothing left to protect.
pub fn delete(handle: &[u8]) -> Result<(), Unavailable> {
    if name_of(handle).is_none() {
        return Err(UNAVAILABLE);
    }
    let Ok(key) = open(handle) else { return Ok(()) };
    // SAFETY: the key is live, and NCryptDeleteKey frees it, so its guard must not.
    let deleted = unsafe { NCryptDeleteKey(key.0, 0) };
    std::mem::forget(key);
    deleted.map_err(|_| UNAVAILABLE)
}
