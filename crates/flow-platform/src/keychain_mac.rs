//! Keychain generic passwords through Security.framework, laid out as Swift's stores do: a name is
//! `<service>/<account>`, cut at the first slash because rewrite accounts are origins. New items are
//! `WhenUnlockedThisDeviceOnly`. Values go nowhere else; nothing here logs.
use crate::Unavailable;
use std::ffi::c_void;
use std::ptr::null;

type Cf = *const c_void;

#[link(name = "Security", kind = "framework")]
unsafe extern "C" {
    static kSecClass: Cf;
    static kSecClassGenericPassword: Cf;
    static kSecAttrService: Cf;
    static kSecAttrAccount: Cf;
    static kSecAttrAccessible: Cf;
    static kSecAttrAccessibleWhenUnlockedThisDeviceOnly: Cf;
    static kSecValueData: Cf;
    static kSecReturnData: Cf;
    static kSecMatchLimit: Cf;
    static kSecMatchLimitOne: Cf;
    static kSecMatchSearchList: Cf;
    static kSecUseKeychain: Cf;
    fn SecItemCopyMatching(query: Cf, result: *mut Cf) -> i32;
    fn SecItemAdd(attributes: Cf, result: *mut Cf) -> i32;
    fn SecItemUpdate(query: Cf, attributes: Cf) -> i32;
    fn SecItemDelete(query: Cf) -> i32;
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFBooleanTrue: Cf;
    static kCFTypeDictionaryKeyCallBacks: c_void;
    static kCFTypeDictionaryValueCallBacks: c_void;
    static kCFTypeArrayCallBacks: c_void;
    fn CFDictionaryCreate(allocator: Cf, keys: *const Cf, values: *const Cf, count: isize, key_callbacks: *const c_void, value_callbacks: *const c_void) -> Cf;
    fn CFArrayCreate(allocator: Cf, values: *const Cf, count: isize, callbacks: *const c_void) -> Cf;
    fn CFStringCreateWithBytes(allocator: Cf, bytes: *const u8, count: isize, encoding: u32, external: bool) -> Cf;
    fn CFDataCreate(allocator: Cf, bytes: *const u8, count: isize) -> Cf;
    fn CFDataGetLength(data: Cf) -> isize;
    fn CFDataGetBytePtr(data: Cf) -> *const u8;
    fn CFGetTypeID(object: Cf) -> usize;
    fn CFDataGetTypeID() -> usize;
    fn CFRelease(object: Cf);
}

const NOT_FOUND: i32 = -25300;
const UTF8: u32 = 0x0800_0100;
/// Swift's `RemoteCredentialStore` bound.
const MAX_BYTES: usize = 16_384;
const UNAVAILABLE: Unavailable = Unavailable("Keychain");

/// The Swift app's services. `flow_core::settings::KEYCHAIN_PREFIX` already keeps this build away
/// from them; this holds if a caller ever gets a name wrong. Delete it at the Mac cutover (Feature 028).
const OWNER_SERVICES: [&str; 4] = ["org.localflow.LocalFlow.remote", "org.localflow.LocalFlow.rewrite", "org.localflow.LocalFlow.dev.remote", "org.localflow.LocalFlow.dev.rewrite"];

fn split(name: &str) -> Result<(&str, &str), Unavailable> {
    match name.split_once('/') {
        Some((service, account)) if !OWNER_SERVICES.contains(&service) => Ok((service, account)),
        _ => Err(UNAVAILABLE),
    }
}

struct Owned(Cf);

impl Drop for Owned {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: held from a Create or Copy call, released once.
            unsafe { CFRelease(self.0) }
        }
    }
}

fn string(s: &str) -> Owned {
    // SAFETY: the pointer and count describe `s`.
    Owned(unsafe { CFStringCreateWithBytes(null(), s.as_ptr(), s.len() as isize, UTF8, false) })
}

fn data(bytes: &[u8]) -> Owned {
    // SAFETY: the pointer and count describe `bytes`, which CoreFoundation copies.
    Owned(unsafe { CFDataCreate(null(), bytes.as_ptr(), bytes.len() as isize) })
}

fn dictionary(pairs: &[(Cf, Cf)]) -> Owned {
    let (keys, values): (Vec<Cf>, Vec<Cf>) = pairs.iter().copied().unzip();
    // SAFETY: both arrays hold `count` live objects, retained by the dictionary's standard callbacks.
    Owned(unsafe { CFDictionaryCreate(null(), keys.as_ptr(), values.as_ptr(), pairs.len() as isize, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) })
}

/// Which keychain to use: `None` is the user's default, as Swift has it. Only the test passes one.
struct Item {
    service: Owned,
    account: Owned,
    keychain: Option<Cf>,
    search: Option<Owned>,
}

impl Item {
    fn new(name: &str, keychain: Option<Cf>) -> Result<Item, Unavailable> {
        let (service, account) = split(name)?;
        // SAFETY: the array holds one live keychain, retained by the standard callbacks.
        let search = keychain.map(|k| Owned(unsafe { CFArrayCreate(null(), &k, 1, &kCFTypeArrayCallBacks) }));
        Ok(Item { service: string(service), account: string(account), keychain, search })
    }
    /// The query Swift's `query(_:)` builds.
    fn query(&self) -> Vec<(Cf, Cf)> {
        // SAFETY: Security's constants live for the process.
        unsafe {
            let mut pairs = vec![(kSecClass, kSecClassGenericPassword), (kSecAttrService, self.service.0), (kSecAttrAccount, self.account.0)];
            if let Some(search) = &self.search {
                pairs.push((kSecMatchSearchList, search.0));
            }
            pairs
        }
    }
}

pub fn read(name: &str) -> Result<Option<Vec<u8>>, Unavailable> {
    read_in(name, None)
}
pub fn write(name: &str, value: &[u8]) -> Result<(), Unavailable> {
    write_in(name, value, None)
}
pub fn remove(name: &str) -> Result<(), Unavailable> {
    remove_in(name, None)
}

fn read_in(name: &str, keychain: Option<Cf>) -> Result<Option<Vec<u8>>, Unavailable> {
    let item = Item::new(name, keychain)?;
    let mut result: Cf = null();
    // SAFETY: the dictionary lives across the call; a returned object is owned and released below.
    let status = unsafe {
        let mut query = item.query();
        query.extend([(kSecReturnData, kCFBooleanTrue), (kSecMatchLimit, kSecMatchLimitOne)]);
        SecItemCopyMatching(dictionary(&query).0, &mut result)
    };
    let result = Owned(result);
    match status {
        0 => {
            // SAFETY: `result` is live, checked to be CFData, and copied before it's released.
            unsafe {
                if result.0.is_null() || CFGetTypeID(result.0) != CFDataGetTypeID() {
                    return Err(UNAVAILABLE);
                }
                let count = CFDataGetLength(result.0) as usize;
                if count > MAX_BYTES {
                    return Err(UNAVAILABLE);
                }
                Ok(Some(std::slice::from_raw_parts(CFDataGetBytePtr(result.0), count).to_vec()))
            }
        }
        NOT_FOUND => Ok(None),
        _ => Err(UNAVAILABLE),
    }
}

fn write_in(name: &str, value: &[u8], keychain: Option<Cf>) -> Result<(), Unavailable> {
    if value.is_empty() || value.len() > MAX_BYTES {
        return Err(UNAVAILABLE);
    }
    let item = Item::new(name, keychain)?;
    let value = data(value);
    // SAFETY: every dictionary and value lives across its call.
    unsafe {
        let updated = SecItemUpdate(dictionary(&item.query()).0, dictionary(&[(kSecValueData, value.0)]).0);
        if updated == 0 {
            return Ok(());
        }
        if updated != NOT_FOUND {
            return Err(UNAVAILABLE);
        }
        let mut add = vec![(kSecClass, kSecClassGenericPassword), (kSecAttrService, item.service.0), (kSecAttrAccount, item.account.0), (kSecValueData, value.0), (kSecAttrAccessible, kSecAttrAccessibleWhenUnlockedThisDeviceOnly)];
        if let Some(keychain) = item.keychain {
            add.push((kSecUseKeychain, keychain));
        }
        if SecItemAdd(dictionary(&add).0, std::ptr::null_mut()) == 0 { Ok(()) } else { Err(UNAVAILABLE) }
    }
}

fn remove_in(name: &str, keychain: Option<Cf>) -> Result<(), Unavailable> {
    let item = Item::new(name, keychain)?;
    // SAFETY: the dictionary lives across the call.
    match unsafe { SecItemDelete(dictionary(&item.query()).0) } {
        0 | NOT_FOUND => Ok(()),
        _ => Err(UNAVAILABLE),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;

    #[link(name = "Security", kind = "framework")]
    unsafe extern "C" {
        fn SecKeychainCreate(path: *const std::ffi::c_char, password_length: u32, password: *const u8, prompt_user: bool, initial_access: Cf, keychain: *mut Cf) -> i32;
        fn SecKeychainDelete(keychain: Cf) -> i32;
    }

    /// A keychain file in a temporary folder, never on the user's search list. Deleted on drop.
    struct Temp(Cf, std::path::PathBuf);

    impl Temp {
        fn new(label: &str) -> Temp {
            let dir = std::env::temp_dir().join(format!("flow-keychain-test-{}-{label}", std::process::id()));
            std::fs::create_dir_all(&dir).unwrap();
            let path = CString::new(dir.join("test.keychain-db").as_os_str().as_bytes()).unwrap();
            let password = b"throwaway";
            let mut keychain: Cf = null();
            // SAFETY: the path and password outlive the call; no prompt is requested.
            let status = unsafe { SecKeychainCreate(path.as_ptr(), password.len() as u32, password.as_ptr(), false, null(), &mut keychain) };
            assert_eq!(status, 0, "SecKeychainCreate");
            Temp(keychain, dir)
        }
    }

    impl Drop for Temp {
        fn drop(&mut self) {
            // SAFETY: the keychain from `new`, deleted and released once.
            unsafe {
                SecKeychainDelete(self.0);
                CFRelease(self.0);
            }
            let _ = std::fs::remove_dir_all(&self.1);
        }
    }

    #[test]
    fn temporary_keychain_round_trip() {
        let (first, second) = (Temp::new("a"), Temp::new("b"));
        let (a, b) = (Some(first.0), Some(second.0));
        // Unique, so even a broken scope couldn't match a real item. Not an owner service.
        let name = format!("org.localflow.LocalFlowTests.{}.remote/server-key", std::process::id());
        let binary = [0xffu8, 0xfe, 0, 1, 2];

        assert_eq!(read_in(&name, a), Ok(None));
        write_in(&name, &binary, a).unwrap();
        assert_eq!(read_in(&name, a).unwrap().unwrap(), binary, "bytes that aren't UTF-8 survive");

        // The scope holds: another keychain neither sees nor removes the item.
        assert_eq!(read_in(&name, b), Ok(None));
        remove_in(&name, b).unwrap();
        assert_eq!(read_in(&name, a).unwrap().unwrap(), binary);

        write_in(&name, b"second", a).unwrap();
        assert_eq!(read_in(&name, a).unwrap().unwrap(), b"second", "update, not a duplicate");

        // A rewrite account is an origin, with slashes of its own.
        let origin = format!("org.localflow.LocalFlowTests.{}.rewrite/http://a:80/x", std::process::id());
        write_in(&origin, b"s3cret", a).unwrap();
        assert_eq!(read_in(&origin, a).unwrap().unwrap(), b"s3cret");

        assert!(write_in(&name, b"", a).is_err(), "empty is refused");
        assert!(write_in(&name, &vec![1; MAX_BYTES + 1], a).is_err(), "over the bound is refused");
        assert_eq!(read_in(&name, a).unwrap().unwrap(), b"second", "a refused write changes nothing");

        remove_in(&name, a).unwrap();
        assert_eq!(read_in(&name, a), Ok(None));
        remove_in(&name, a).unwrap();
    }

    /// Refused before any Security call, so this touches no keychain.
    #[test]
    fn owner_items_and_bad_names_are_refused() {
        for service in OWNER_SERVICES {
            let name = format!("{service}/device-key");
            assert_eq!(read(&name), Err(UNAVAILABLE));
            assert_eq!(write(&name, b"x"), Err(UNAVAILABLE));
            assert_eq!(remove(&name), Err(UNAVAILABLE));
        }
        assert_eq!(read("no-slash"), Err(UNAVAILABLE));
        assert_eq!(split("a.b/http://h:1/p"), Ok(("a.b", "http://h:1/p")));
    }
}
