//! Remote client logic (Feature 025). The OS sits behind `Secrets` and `DeviceKeys`; `apps/desktop`
//! adapts the platform services to them.
use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;

/// Swift's `RemoteCredentialItem`.
pub const CREDENTIAL_ACCOUNTS: [&str; 4] = ["device-key", "server-key", "refresh-token", "access-token"];

/// The storage or key hardware refused. Names the part, never a value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Unavailable(pub &'static str);

/// `RemoteCredentialStoring`. `server-key` and `device-key` are raw bytes, tokens UTF-8.
pub trait Secrets {
    fn read(&self, account: &str) -> Result<Option<Vec<u8>>, Unavailable>;
    fn write(&self, account: &str, value: &[u8]) -> Result<(), Unavailable>;
    /// Nothing to remove isn't an error.
    fn remove(&self, account: &str) -> Result<(), Unavailable>;
    /// Tries every item, then reports the first failure.
    fn remove_all(&self) -> Result<(), Unavailable> {
        CREDENTIAL_ACCOUNTS.iter().map(|a| self.remove(a)).fold(Ok(()), Result::and)
    }
}

/// `RemoteDeviceKeys`: a non-exportable P-256 key.
pub trait DeviceKeys {
    /// A new key: its handle (stored as `device-key`) and X9.63 public key (65 bytes).
    fn create(&self) -> Result<(Vec<u8>, Vec<u8>), Unavailable>;
    /// `None` when the handle no longer loads, for example after a restore onto new hardware.
    fn public_key(&self, handle: &[u8]) -> Option<Vec<u8>>;
    /// DER ECDSA signature over the SHA-256 of `message`.
    fn sign(&self, message: &[u8], handle: &[u8]) -> Result<Vec<u8>, Unavailable>;
    fn delete(&self, handle: &[u8]) -> Result<(), Unavailable>;
}

/// In-memory `Secrets`. `failing` makes every call refuse.
#[derive(Default)]
pub struct MemorySecrets {
    pub items: RefCell<BTreeMap<String, Vec<u8>>>,
    pub failing: Cell<bool>,
}

impl MemorySecrets {
    fn check(&self) -> Result<(), Unavailable> {
        if self.failing.get() { Err(Unavailable("memory secrets")) } else { Ok(()) }
    }
}

impl Secrets for MemorySecrets {
    fn read(&self, account: &str) -> Result<Option<Vec<u8>>, Unavailable> {
        self.check()?;
        Ok(self.items.borrow().get(account).cloned())
    }
    fn write(&self, account: &str, value: &[u8]) -> Result<(), Unavailable> {
        self.check()?;
        if value.is_empty() {
            return Err(Unavailable("an empty credential"));
        }
        self.items.borrow_mut().insert(account.into(), value.to_vec());
        Ok(())
    }
    fn remove(&self, account: &str) -> Result<(), Unavailable> {
        self.check()?;
        self.items.borrow_mut().remove(account);
        Ok(())
    }
}

/// In-memory `DeviceKeys`. The signature has DER's shape but proves nothing; a test that needs flowd
/// to verify it brings a real signer.
#[derive(Default)]
pub struct MemoryDeviceKeys {
    pub keys: RefCell<Vec<u8>>,
    next: Cell<u8>,
    /// No hardware key: `create` and `sign` refuse.
    pub unavailable: Cell<bool>,
}

impl MemoryDeviceKeys {
    fn live(&self, handle: &[u8]) -> Option<u8> {
        match handle {
            [id] if self.keys.borrow().contains(id) => Some(*id),
            _ => None,
        }
    }
}

impl DeviceKeys for MemoryDeviceKeys {
    fn create(&self) -> Result<(Vec<u8>, Vec<u8>), Unavailable> {
        if self.unavailable.get() {
            return Err(Unavailable("device key"));
        }
        let id = self.next.get().wrapping_add(1);
        self.next.set(id);
        self.keys.borrow_mut().push(id);
        let mut public = vec![4];
        public.resize(65, id);
        Ok((vec![id], public))
    }
    fn public_key(&self, handle: &[u8]) -> Option<Vec<u8>> {
        let id = self.live(handle)?;
        let mut public = vec![4];
        public.resize(65, id);
        Some(public)
    }
    fn sign(&self, _message: &[u8], handle: &[u8]) -> Result<Vec<u8>, Unavailable> {
        if self.unavailable.get() {
            return Err(Unavailable("device key"));
        }
        let id = self.live(handle).ok_or(Unavailable("device key"))?;
        raw_signature_to_der(&[id; 64]).ok_or(Unavailable("device key"))
    }
    fn delete(&self, handle: &[u8]) -> Result<(), Unavailable> {
        if let Some(id) = self.live(handle) {
            self.keys.borrow_mut().retain(|k| *k != id);
        }
        Ok(())
    }
}

fn der_integer(out: &mut Vec<u8>, value: &[u8]) {
    let start = value.iter().position(|b| *b != 0).unwrap_or(value.len() - 1);
    let value = &value[start..];
    let pad = value[0] & 0x80 != 0;
    out.extend([0x02, value.len() as u8 + pad as u8]);
    if pad {
        out.push(0);
    }
    out.extend_from_slice(value);
}

/// The 64-byte r||s both key stores produce, as the ASN.1 DER flowd verifies. At most 72 bytes, so
/// every length fits the short form.
pub fn raw_signature_to_der(raw: &[u8]) -> Option<Vec<u8>> {
    if raw.len() != 64 {
        return None;
    }
    let mut body = Vec::with_capacity(70);
    der_integer(&mut body, &raw[..32]);
    der_integer(&mut body, &raw[32..]);
    let mut der = vec![0x30, body.len() as u8];
    der.append(&mut body);
    Some(der)
}

/// `BCRYPT_ECDSA_PUBLIC_P256_MAGIC`, "ECS1" little-endian.
const ECS1: [u8; 4] = [0x45, 0x43, 0x53, 0x31];

/// A device public key as the platform gives it, in the 65-byte X9.63 form enrollment sends: X9.63
/// already, or a 72-byte `BCRYPT_ECCPUBLIC_BLOB` (magic, key length, X, Y).
pub fn x963_public_key(key: &[u8]) -> Option<Vec<u8>> {
    match key.len() {
        65 if key[0] == 4 => Some(key.to_vec()),
        72 if key[..4] == ECS1 && key[4..8] == 32u32.to_le_bytes() => {
            let mut out = vec![4];
            out.extend_from_slice(&key[8..]);
            Some(out)
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(s: &str) -> Vec<u8> {
        (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
    }

    #[test]
    fn der_of_the_rfc6979_p256_sample() {
        // RFC 6979 A.2.5, SHA-256, "sample": both values have the top bit set, so both get a zero.
        let r = "EFD48B2AACB6A8FD1140DD9CD45E81D69D2C877B56AAF991C34D0EA84EAF3716";
        let s = "F7CB1C942D657C41D436C7A1B6E29F65F3E900DBB9AFF4064DC4AB2F843ACDA8";
        let der = raw_signature_to_der(&hex(&format!("{r}{s}"))).unwrap();
        assert_eq!(der, hex(&format!("3046022100{r}022100{s}")));
    }

    #[test]
    fn der_integers_stay_minimal() {
        let mut raw = [0u8; 64];
        // r loses its leading zeros but keeps a zero before a set top bit.
        raw[30] = 0x80;
        raw[31] = 0x01;
        // s is small with a clear top bit.
        raw[63] = 0x7f;
        assert_eq!(raw_signature_to_der(&raw).unwrap(), [0x30, 0x08, 0x02, 0x03, 0x00, 0x80, 0x01, 0x02, 0x01, 0x7f]);
        assert_eq!(raw_signature_to_der(&[0; 64]).unwrap(), [0x30, 0x06, 0x02, 0x01, 0x00, 0x02, 0x01, 0x00], "zero is one byte");
        assert_eq!(raw_signature_to_der(&[0xff; 64]).unwrap().len(), 72, "the longest form");
        assert_eq!(raw_signature_to_der(&[0; 63]), None);
        assert_eq!(raw_signature_to_der(&[0; 65]), None);
    }

    #[test]
    fn public_key_forms() {
        let mut blob = b"ECS1".to_vec();
        blob.extend(32u32.to_le_bytes());
        blob.extend((0..64).map(|i| i as u8));
        let x963 = x963_public_key(&blob).unwrap();
        assert_eq!(x963.len(), 65);
        assert_eq!(x963[0], 4);
        assert_eq!(x963[1..], blob[8..]);
        assert_eq!(x963_public_key(&x963).as_ref(), Some(&x963), "the Secure Enclave's form passes through");
        let mut private = blob.clone();
        private[3] = b'2';
        assert_eq!(x963_public_key(&private), None, "a private-key blob's magic");
        let mut other_curve = blob.clone();
        other_curve[4] = 48;
        assert_eq!(x963_public_key(&other_curve), None);
        assert_eq!(x963_public_key(&blob[..71]), None);
        let mut compressed = x963.clone();
        compressed[0] = 2;
        assert_eq!(x963_public_key(&compressed), None);
    }

    #[test]
    fn secrets_round_trip_overwrite_and_remove_all() {
        let store = MemorySecrets::default();
        assert_eq!(store.read("access-token"), Ok(None));
        store.write("server-key", &[0xff, 0, 1]).unwrap();
        assert_eq!(store.read("server-key").unwrap().unwrap(), [0xff, 0, 1], "raw bytes survive");
        store.write("refresh-token", b"lfr_one").unwrap();
        store.write("refresh-token", b"lfr_two").unwrap();
        assert_eq!(store.read("refresh-token").unwrap().unwrap(), b"lfr_two");
        assert!(store.write("refresh-token", b"").is_err(), "empty values are refused");
        store.remove_all().unwrap();
        assert!(store.items.borrow().is_empty());
        store.remove_all().unwrap();
        store.failing.set(true);
        assert!(store.read("server-key").is_err());
        assert!(store.remove_all().is_err());
    }

    /// One failure still lets the other items go, as Swift's `removeAll` does.
    #[test]
    fn remove_all_tries_every_item() {
        struct Refuses(RefCell<Vec<String>>);
        impl Secrets for Refuses {
            fn read(&self, _: &str) -> Result<Option<Vec<u8>>, Unavailable> {
                Ok(None)
            }
            fn write(&self, _: &str, _: &[u8]) -> Result<(), Unavailable> {
                Ok(())
            }
            fn remove(&self, account: &str) -> Result<(), Unavailable> {
                self.0.borrow_mut().push(account.into());
                if account == "device-key" { Err(Unavailable("first")) } else { Ok(()) }
            }
        }
        let store = Refuses(RefCell::default());
        assert_eq!(store.remove_all(), Err(Unavailable("first")));
        assert_eq!(*store.0.borrow(), CREDENTIAL_ACCOUNTS);
    }

    #[test]
    fn device_keys_lifecycle() {
        let keys = MemoryDeviceKeys::default();
        let (handle, public) = keys.create().unwrap();
        assert_eq!(x963_public_key(&public), Some(public.clone()));
        assert_eq!(keys.public_key(&handle), Some(public));
        assert_eq!(keys.sign(b"m", &handle).unwrap()[0], 0x30);
        let (other, _) = keys.create().unwrap();
        assert_ne!(handle, other);
        keys.delete(&handle).unwrap();
        assert_eq!(keys.public_key(&handle), None, "a lost key no longer loads");
        assert!(keys.sign(b"m", &handle).is_err());
        assert!(keys.public_key(&other).is_some());
        keys.unavailable.set(true);
        assert!(keys.create().is_err(), "no software fallback");
    }
}
