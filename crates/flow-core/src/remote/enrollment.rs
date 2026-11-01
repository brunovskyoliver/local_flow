//! `RemoteEnrollment`: identity and pin, enrollment, pairing, tokens, server answers and turning off.
//! Blocking, for background threads. The display state lives here while an operation runs: load it
//! from `Prefs` first and store it back afterwards unless the feature was turned off meanwhile.
use super::channel::*;
use super::pairing::PairingToken;
use super::pool::{Opener, Pool};
use super::{DeviceKeys, Secrets, Unavailable, x963_public_key};
use crate::prefs::Prefs;
use crate::settings::{self, Identity, IdentityError, base64url_encode, sha256};
use serde_json::json;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Access tokens live 15 minutes on the server; the client refreshes after 12.
pub const REFRESH_AFTER: Duration = Duration::from_secs(12 * 60);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IdentityProvider {
    Apple,
    Google,
}
impl IdentityProvider {
    fn as_str(self) -> &'static str {
        match self {
            IdentityProvider::Apple => "apple",
            IdentityProvider::Google => "google",
        }
    }
}

/// `IdentitySignIn`: returns an ID token carrying `nonce`.
pub trait SignIn: Send + Sync {
    fn sign_in(&self, provider: IdentityProvider, nonce: &str) -> Result<String, Unavailable>;
}

/// `RemoteIdentityFetching`.
pub trait IdentityFetching: Send + Sync {
    fn fetch(&self, origin: &str) -> Result<Identity, IdentityError>;
}

/// `GET /v1/remote/identity` over HTTP.
pub struct HttpIdentity;
impl IdentityFetching for HttpIdentity {
    fn fetch(&self, origin: &str) -> Result<Identity, IdentityError> {
        settings::fetch_identity(origin)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EnrollError {
    /// Consent isn't confirmed or no usable address is set: nothing may connect.
    NotConfigured,
    /// The identity route answered something other than a v1 identity.
    InvalidIdentity,
    /// The identity route didn't answer.
    Unreachable,
    DeviceKeyUnavailable,
    SignInFailed,
    /// The server answered with an unexpected message.
    Protocol,
    /// The address reaches a server other than the one that issued the token, or than the pin.
    WrongServer,
    /// The server doesn't know `pair`. The token wasn't spent.
    UpdateRequired,
    /// The address answers the identity route but carries no channel.
    UnusableRoute,
    Channel(ChannelError),
    Storage(Unavailable),
    /// Turned off while this ran. Nothing was stored.
    TurnedOff,
}
impl From<ChannelError> for EnrollError {
    fn from(e: ChannelError) -> Self {
        EnrollError::Channel(e)
    }
}
impl From<Unavailable> for EnrollError {
    fn from(e: Unavailable) -> Self {
        EnrollError::Storage(e)
    }
}

/// The `remote.*` values enrollment reads and writes.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RemoteSettings {
    /// `remote_enrollment_origin`: `None` before consent, so nothing connects.
    pub origin: Option<String>,
    pub state: String,
    pub notice: Option<String>,
}

impl RemoteSettings {
    pub fn from_prefs(p: &Prefs) -> RemoteSettings {
        RemoteSettings { origin: settings::remote_enrollment_origin(p), state: settings::remote_state(p).to_string(), notice: settings::remote_notice(p).map(str::to_string) }
    }
    pub fn store(&self, p: &mut Prefs) {
        if let Some(origin) = &self.origin {
            p.set("remote.serverURL", origin.as_str());
        }
        p.set("remote.state", self.state.as_str());
        match &self.notice {
            Some(notice) => p.set("remote.notice", notice.as_str()),
            None => p.remove("remote.notice"),
        }
    }
}

/// What `pair` signs: the label, the channel binding and, for a refresh, the token's hash.
pub fn signature_input(label: &[u8], binding: &[u8], extra: &[u8]) -> Vec<u8> {
    [label, binding, extra].concat()
}

/// At most 64 UTF-8 bytes without control characters. The server refuses longer names.
fn device_name(name: &str) -> String {
    let mut out = String::new();
    for c in name.chars().filter(|c| !c.is_control()) {
        if out.len() + c.len_utf8() > 64 {
            break;
        }
        out.push(c);
    }
    out
}

pub struct Parts {
    pub secrets: Arc<dyn Secrets>,
    pub keys: Arc<dyn DeviceKeys>,
    pub sign_in: Arc<dyn SignIn>,
    pub identity: Arc<dyn IdentityFetching>,
    pub transports: Arc<dyn Transports>,
    /// Includes time asleep, as Swift's `ContinuousClock` does; a token doesn't stop ageing.
    pub now: Box<dyn Fn() -> Duration + Send + Sync>,
    pub device_name: String,
}

/// Wall time since the epoch: unlike `Instant` on macOS it keeps counting through sleep.
// ponytail: a clock set back makes a token look young for up to that long; the server's token_expired answer recovers.
pub fn system_now() -> Duration {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default()
}

#[derive(Default)]
struct Inner {
    settings: RemoteSettings,
    access_issued_at: Option<Duration>,
    /// The token being redeemed and its device key, kept until a definite answer: a lost reply can
    /// only be retried with the same key.
    pair_attempt: Option<(PairingToken, Vec<u8>, Vec<u8>)>,
}

pub struct Enrollment {
    parts: Parts,
    inner: Mutex<Inner>,
    /// One refresh at a time; holds the last result for whoever waited.
    refreshing: Mutex<Option<String>>,
    refreshes: AtomicU64,
    /// Bumped on turn off. Whatever started earlier stores nothing.
    generation: AtomicU64,
}

impl Enrollment {
    pub fn new(parts: Parts) -> Enrollment {
        Enrollment { parts, inner: Mutex::default(), refreshing: Mutex::new(None), refreshes: AtomicU64::new(0), generation: AtomicU64::new(0) }
    }

    /// Session channels for `Pool`, each with a live token.
    pub fn pool(this: &Arc<Enrollment>) -> Pool {
        let enrollment = this.clone();
        let open: Opener = Box::new(move || enrollment.session_channel());
        let clock = this.clone();
        Pool::new(open, Box::new(move || (clock.parts.now)()))
    }

    fn inner(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn load(&self, settings: RemoteSettings) {
        self.inner().settings = settings;
    }
    pub fn settings(&self) -> RemoteSettings {
        self.inner().settings.clone()
    }
    pub fn generation(&self) -> u64 {
        self.generation.load(Ordering::SeqCst)
    }

    fn origin(&self) -> Option<String> {
        self.inner().settings.origin.clone()
    }
    fn token(&self, account: &str) -> Option<String> {
        self.parts.secrets.read(account).ok().flatten().and_then(|v| String::from_utf8(v).ok())
    }
    pub fn pinned_key(&self) -> Option<Vec<u8>> {
        self.parts.secrets.read("server-key").ok().flatten()
    }

    fn connect(&self, origin: &str, key: &[u8]) -> Result<Channel, ChannelError> {
        let url = channel_url(origin).ok_or(ChannelError::Unreachable)?;
        let transport = self.parts.transports.open(&url).map_err(|e| if e == TransportError::Timeout { ChannelError::Timeout } else { ChannelError::Unreachable })?;
        Channel::new(transport, key)
    }

    // MARK: Identity and pinning

    /// The server identity for the user to compare. Nothing connects before consent and an address.
    pub fn fetch_server_identity(&self) -> Result<Identity, EnrollError> {
        let origin = self.origin().ok_or(EnrollError::NotConfigured)?;
        self.fetch_at(&origin)
    }

    fn fetch_at(&self, origin: &str) -> Result<Identity, EnrollError> {
        let identity = self.parts.identity.fetch(origin).map_err(|e| match e {
            IdentityError::Unreachable => EnrollError::Unreachable,
            IdentityError::Invalid => EnrollError::InvalidIdentity,
        })?;
        identity.validated_key().ok_or(EnrollError::InvalidIdentity)?;
        Ok(identity)
    }

    /// Pins the key the user saw. Only enrollment pins; a later mismatch never re-pins.
    pub fn pin(&self, identity: &Identity) -> Result<(), EnrollError> {
        let mut inner = self.inner();
        if inner.settings.origin.is_none() {
            return Err(EnrollError::NotConfigured);
        }
        let key = identity.validated_key().ok_or(EnrollError::InvalidIdentity)?;
        self.drop_device_key();
        self.parts.secrets.remove_all()?;
        inner.access_issued_at = None;
        self.parts.secrets.write("server-key", &key)?;
        inner.settings.notice = None;
        inner.settings.state = "pinned".into();
        Ok(())
    }

    /// A key only this device item names; TPM keys outlive the item, so they go with it.
    fn drop_device_key(&self) {
        if let Ok(Some(handle)) = self.parts.secrets.read("device-key") {
            let _ = self.parts.keys.delete(&handle);
        }
    }

    /// Moves to a new address for the same server. The identity there must be the pinned key and a
    /// channel must open there; on a match only the stored address changes.
    pub fn update_address(&self, address: &str) -> Result<(), EnrollError> {
        let generation = self.generation();
        let (Some(_), Some(pinned), Some(checked)) = (self.origin(), self.pinned_key(), super::address::origin(address)) else { return Err(EnrollError::NotConfigured) };
        let identity = self.fetch_at(&checked)?;
        let key = identity.validated_key().ok_or(EnrollError::InvalidIdentity)?;
        if key != pinned {
            return Err(EnrollError::WrongServer);
        }
        match self.open_checked(&checked, &pinned) {
            Ok(_) => {}
            Err(EnrollError::Channel(ChannelError::PinMismatch)) => return Err(EnrollError::WrongServer),
            Err(e) => return Err(e),
        }
        let mut inner = self.inner();
        if generation != self.generation() {
            return Err(EnrollError::TurnedOff);
        }
        inner.settings.origin = Some(checked);
        Ok(())
    }

    /// An enroll channel at an address whose identity route just answered, so a failure that isn't
    /// the server's own answer means the route doesn't carry WebSockets.
    fn open_checked(&self, origin: &str, key: &[u8]) -> Result<Channel, EnrollError> {
        let opened = self.connect(origin, key).and_then(|mut channel| channel.open(Purpose::Enroll, None).map(|_| channel));
        opened.map_err(|e| match e {
            ChannelError::PinMismatch | ChannelError::Server(_) => EnrollError::Channel(e),
            _ => EnrollError::UnusableRoute,
        })
    }

    // MARK: Enrollment

    /// Creates the device key, signs in on a nonce bound to this channel and registers the device.
    /// Returns the server's state for it.
    pub fn enroll(&self, provider: IdentityProvider) -> Result<String, EnrollError> {
        let generation = self.generation();
        let (Some(origin), Some(key)) = (self.origin(), self.pinned_key()) else { return Err(EnrollError::NotConfigured) };
        let (handle, public) = self.create_key()?;
        let result = self.enroll_with(provider, &origin, &key, &handle, &public, generation);
        if result.is_err() && generation != self.generation() {
            let _ = self.parts.keys.delete(&handle);
            return Err(EnrollError::TurnedOff);
        }
        if result.is_err() {
            let _ = self.parts.keys.delete(&handle);
        }
        match &result {
            Err(EnrollError::Channel(ChannelError::PinMismatch)) => self.handle_pin_mismatch(),
            Err(EnrollError::Channel(ChannelError::Server(code))) => self.apply(code),
            Ok(state) if state == "approved" => {
                self.refresh_now();
            }
            _ => {}
        }
        result
    }

    fn create_key(&self) -> Result<(Vec<u8>, Vec<u8>), EnrollError> {
        let (handle, public) = self.parts.keys.create().map_err(|_| EnrollError::DeviceKeyUnavailable)?;
        let public = x963_public_key(&public).ok_or(EnrollError::DeviceKeyUnavailable)?;
        Ok((handle, public))
    }

    fn enroll_with(&self, provider: IdentityProvider, origin: &str, key: &[u8], handle: &[u8], public: &[u8], generation: u64) -> Result<String, EnrollError> {
        let mut channel = self.connect(origin, key)?;
        channel.open(Purpose::Enroll, None)?;
        let binding = channel.binding();
        let raw = base64url_encode(&binding);
        let nonce = match provider {
            IdentityProvider::Apple => sha256(raw.as_bytes()).iter().map(|b| format!("{b:02x}")).collect(),
            IdentityProvider::Google => raw,
        };
        let id_token = self.parts.sign_in.sign_in(provider, &nonce).map_err(|_| EnrollError::SignInFailed)?;
        let signature = self.parts.keys.sign(&signature_input(b"localflow-v1-enroll", &binding, &[]), handle).map_err(|_| EnrollError::DeviceKeyUnavailable)?;
        channel.send(json!({"type": "enroll", "op": 1, "provider": provider.as_str(), "id_token": id_token, "device_name": device_name(&self.parts.device_name), "device_key": base64url_encode(public), "signature": base64url_encode(&signature)}))?;
        match channel.receive()? {
            ServerMessage::Enrolled { op: 1, state, refresh_token } => {
                let mut inner = self.inner();
                if generation != self.generation() {
                    return Err(EnrollError::TurnedOff);
                }
                self.parts.secrets.write("device-key", handle)?;
                let _ = self.parts.secrets.remove("access-token");
                inner.access_issued_at = None;
                if let Some(refresh) = refresh_token {
                    self.parts.secrets.write("refresh-token", refresh.as_bytes())?;
                }
                inner.settings.notice = None;
                inner.settings.state = state.clone();
                Ok(state)
            }
            ServerMessage::Error { code } => Err(ChannelError::Server(code).into()),
            _ => Err(EnrollError::Protocol),
        }
    }

    // MARK: Pairing

    /// Redeems a pairing token. The caller has shown consent. The token goes only into a channel
    /// sealed to the key it names, and only if the address serves that key. The pin, which clears
    /// existing credentials, comes after the server's answer, so a refused token leaves a working
    /// device as it was.
    pub fn pair(&self, token: &PairingToken) -> Result<(), EnrollError> {
        let generation = self.generation();
        let origin = self.origin().ok_or(EnrollError::NotConfigured)?;
        channel_url(&origin).ok_or(EnrollError::NotConfigured)?;
        let identity = self.fetch_at(&origin)?;
        if identity.validated_key().as_deref() != Some(&token.server_key[..]) {
            return Err(EnrollError::WrongServer);
        }
        let kept = self.inner().pair_attempt.as_ref().filter(|a| a.0 == *token).map(|a| (a.1.clone(), a.2.clone()));
        let (handle, public) = match kept {
            Some(device) => device,
            None => {
                let device = self.create_key()?;
                if let Some(old) = self.inner().pair_attempt.replace((token.clone(), device.0.clone(), device.1.clone())) {
                    let _ = self.parts.keys.delete(&old.1);
                }
                device
            }
        };
        let result = self.pair_with(token, &identity, &origin, &handle, &public, generation);
        if result.is_err() && generation != self.generation() {
            return Err(EnrollError::TurnedOff);
        }
        let definite = match &result {
            Ok(()) => false,
            Err(EnrollError::Channel(ChannelError::PinMismatch) | EnrollError::WrongServer) => true,
            // A temporary refusal keeps the key: the token may already be redeemed by it, and only
            // that key can get its credentials after a lost reply.
            Err(EnrollError::Channel(ChannelError::Server(code))) => code != "busy" && code != "internal",
            Err(_) => false,
        };
        if definite {
            self.forget_attempt();
        }
        match result {
            Ok(()) => {
                self.refresh_now();
                Ok(())
            }
            Err(EnrollError::Channel(ChannelError::PinMismatch)) => Err(EnrollError::WrongServer),
            // A flowd without `pair` refuses the unknown type with invalid_message, then closes.
            Err(EnrollError::Channel(ChannelError::Server(code))) if code == "invalid_message" || code == "unsupported_version" => {
                self.apply("unsupported_version");
                Err(EnrollError::UpdateRequired)
            }
            Err(e) => Err(e),
        }
    }

    fn forget_attempt(&self) {
        if let Some(attempt) = self.inner().pair_attempt.take() {
            let _ = self.parts.keys.delete(&attempt.1);
        }
    }

    fn pair_with(&self, token: &PairingToken, identity: &Identity, origin: &str, handle: &[u8], public: &[u8], generation: u64) -> Result<(), EnrollError> {
        let mut channel = self.open_checked(origin, &token.server_key)?;
        let signature = self.parts.keys.sign(&signature_input(b"localflow-v1-pair", &channel.binding(), &[]), handle).map_err(|_| EnrollError::DeviceKeyUnavailable)?;
        channel.send(json!({"type": "pair", "op": 1, "pairing_token": token.value, "device_name": device_name(&self.parts.device_name), "device_key": base64url_encode(public), "signature": base64url_encode(&signature)}))?;
        match channel.receive()? {
            ServerMessage::Enrolled { op: 1, state, refresh_token: Some(refresh) } if state == "approved" => {
                if generation != self.generation() {
                    return Err(EnrollError::TurnedOff);
                }
                self.pin(identity)?;
                let mut inner = self.inner();
                self.parts.secrets.write("device-key", handle)?;
                self.parts.secrets.write("refresh-token", refresh.as_bytes())?;
                inner.pair_attempt = None;
                inner.settings.state = "approved".into();
                Ok(())
            }
            ServerMessage::Error { code } => Err(ChannelError::Server(code).into()),
            _ => Err(EnrollError::Protocol),
        }
    }

    // MARK: Tokens

    /// A live access token for a session channel, refreshing first when it's 12 minutes old or its
    /// issue time is unknown. `None` when the device isn't approved or the refresh failed.
    pub fn access_token(&self) -> Option<String> {
        {
            let inner = self.inner();
            if inner.settings.origin.is_none() || inner.settings.state != "approved" {
                return None;
            }
            if let (Some(issued), Some(token)) = (inner.access_issued_at, self.token("access-token")) {
                if (self.parts.now)().saturating_sub(issued) < REFRESH_AFTER {
                    return Some(token);
                }
            }
        }
        self.refresh_now()
    }

    /// Whether a background refresh should run: an approved device's token is 12 minutes old or of
    /// unknown age.
    pub fn refresh_due(&self) -> bool {
        let inner = self.inner();
        inner.settings.origin.is_some() && inner.settings.state == "approved" && inner.access_issued_at.is_none_or(|issued| (self.parts.now)().saturating_sub(issued) >= REFRESH_AFTER)
    }

    /// After `token_expired`: the token is dropped and refreshed now.
    pub fn access_token_expired(&self) -> Option<String> {
        self.apply("token_expired");
        self.refresh_now()
    }

    /// One refresh at a time; whoever waited for a running one shares its result.
    pub fn refresh_now(&self) -> Option<String> {
        let seen = self.refreshes.load(Ordering::SeqCst);
        let mut last = self.refreshing.lock().unwrap_or_else(|e| e.into_inner());
        if self.refreshes.load(Ordering::SeqCst) != seen {
            return last.clone();
        }
        *last = self.perform_refresh();
        self.refreshes.fetch_add(1, Ordering::SeqCst);
        last.clone()
    }

    fn perform_refresh(&self) -> Option<String> {
        let generation = self.generation();
        let origin = self.origin()?;
        let key = self.pinned_key()?;
        let refresh = self.token("refresh-token")?;
        // A read that failed isn't a lost key: the Keychain may only be locked.
        let handle = self.parts.secrets.read("device-key").ok()?;
        let Some(handle) = handle.filter(|h| self.parts.keys.public_key(h).is_some()) else {
            self.device_key_lost();
            return None;
        };
        let mut channel = match self.connect(&origin, &key) {
            Ok(channel) => channel,
            Err(ChannelError::PinMismatch) => {
                self.handle_pin_mismatch();
                return None;
            }
            Err(_) => return None,
        };
        let result = (|| {
            channel.open(Purpose::Refresh, None)?;
            let input = signature_input(b"localflow-v1-refresh", &channel.binding(), &sha256(refresh.as_bytes()));
            let Ok(signature) = self.parts.keys.sign(&input, &handle) else { return Ok(None) };
            channel.send(json!({"type": "refresh", "op": 1, "refresh_token": refresh, "signature": base64url_encode(&signature)}))?;
            channel.receive().map(Some)
        })();
        match result {
            Ok(None) => {
                self.device_key_lost();
                None
            }
            Ok(Some(ServerMessage::Tokens { op: 1, access_token, refresh_token })) => {
                let mut inner = self.inner();
                if generation != self.generation() {
                    return None;
                }
                self.parts.secrets.write("refresh-token", refresh_token.as_bytes()).ok()?;
                self.parts.secrets.write("access-token", access_token.as_bytes()).ok()?;
                inner.access_issued_at = Some((self.parts.now)());
                inner.settings.notice = None;
                inner.settings.state = "approved".into();
                Some(access_token)
            }
            Ok(Some(ServerMessage::Error { code })) | Err(ChannelError::Server(code)) => {
                self.apply(&code);
                None
            }
            Err(ChannelError::PinMismatch) => {
                self.handle_pin_mismatch();
                None
            }
            _ => None,
        }
    }

    /// A session channel, with one retry after `token_expired`. Used by `Pool`.
    /// What the server offers now, for `server.capabilities`. None when it can't be reached.
    pub fn capabilities(&self) -> Option<settings::Capabilities> {
        let (origin, key, token) = (self.origin()?, self.pinned_key()?, self.access_token()?);
        settings::ping(&origin, Some(&key), Some(&token))?.1
    }

    pub fn session_channel(&self) -> Result<Channel, ChannelError> {
        let origin = self.origin().ok_or(ChannelError::Closed)?;
        let key = self.pinned_key().ok_or(ChannelError::Closed)?;
        let mut token = self.access_token().ok_or(ChannelError::Closed)?;
        let mut retried = false;
        loop {
            let mut channel = self.connect(&origin, &key)?;
            match channel.open(Purpose::Session, Some(&token)) {
                Ok(()) => return Ok(channel),
                Err(ChannelError::Server(code)) if code == "token_expired" && !retried => {
                    retried = true;
                    token = self.access_token_expired().ok_or(ChannelError::Server(code))?;
                }
                Err(e) => {
                    match &e {
                        ChannelError::PinMismatch => self.handle_pin_mismatch(),
                        ChannelError::Server(code) => self.apply(code),
                        _ => {}
                    }
                    return Err(e);
                }
            }
        }
    }

    // MARK: Server answers

    /// Applies an error code the server sent on any channel.
    pub fn apply(&self, code: &str) {
        let mut inner = self.inner();
        let answer = settings::server_answer(code, &inner.settings.state);
        if let Some(state) = answer.state {
            inner.settings.state = state.to_string();
        }
        if let Some(notice) = answer.notice {
            inner.settings.notice = Some(notice.to_string());
        }
        if answer.remove.contains(&"access-token") {
            inner.access_issued_at = None;
        }
        for account in answer.remove {
            let _ = self.parts.secrets.remove(account);
        }
    }

    /// Close code 4001: refuse to send anything until the user enrolls again. Never re-pins.
    pub fn handle_pin_mismatch(&self) {
        self.apply("pin_mismatch");
    }

    /// The key no longer loads, as after a restore onto new hardware. The user signs in again.
    fn device_key_lost(&self) {
        self.apply("device_key_lost");
    }

    // MARK: Turning off

    /// Deletes the four items and the device key, and stops what's running from storing anything.
    /// The caller resets `remote.*` in `Prefs`.
    pub fn turn_off(&self) {
        self.cancel();
        self.drop_device_key();
        let _ = self.parts.secrets.remove_all();
    }

    /// Whatever started before this stores nothing.
    pub fn cancel(&self) {
        let mut inner = self.inner();
        self.generation.fetch_add(1, Ordering::SeqCst);
        inner.settings = RemoteSettings::default();
        inner.access_issued_at = None;
        if let Some(attempt) = inner.pair_attempt.take() {
            let _ = self.parts.keys.delete(&attempt.1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::scripted::{Counters, Reply, Script};
    use super::super::{MemoryDeviceKeys, MemorySecrets};
    use super::*;
    use crate::settings::fingerprint_of;
    use std::sync::atomic::AtomicBool;

    struct FakeIdentity(Mutex<Result<Identity, IdentityError>>);
    impl IdentityFetching for FakeIdentity {
        fn fetch(&self, _: &str) -> Result<Identity, IdentityError> {
            self.0.lock().unwrap().clone()
        }
    }
    #[derive(Default)]
    struct FakeSignIn {
        nonce: Mutex<String>,
        refuse: AtomicBool,
    }
    impl SignIn for FakeSignIn {
        fn sign_in(&self, _: IdentityProvider, nonce: &str) -> Result<String, Unavailable> {
            *self.nonce.lock().unwrap() = nonce.into();
            if self.refuse.load(Ordering::SeqCst) { Err(Unavailable("sign in")) } else { Ok("id-token".into()) }
        }
    }

    pub(crate) fn identity_of(key: &[u8]) -> Identity {
        Identity { schema_version: 1, server: json!({}), protocol_versions: vec![1], suite: "x25519-hkdfsha256-chacha20poly1305".into(), server_key: base64url_encode(key), fingerprint: fingerprint_of(key) }
    }

    struct Fx {
        e: Enrollment,
        secrets: Arc<MemorySecrets>,
        keys: Arc<MemoryDeviceKeys>,
        sign_in: Arc<FakeSignIn>,
        counters: Counters,
        key: Vec<u8>,
        clock: Arc<AtomicU64>,
    }

    fn fx(replies: Vec<Reply>) -> Fx {
        let script = Script::new(replies);
        let (counters, key) = (script.counters(), script.public_key());
        let secrets = Arc::new(MemorySecrets::default());
        let keys = Arc::new(MemoryDeviceKeys::default());
        let sign_in = Arc::new(FakeSignIn::default());
        let clock = Arc::new(AtomicU64::new(1000));
        let now = clock.clone();
        let e = Enrollment::new(Parts {
            secrets: secrets.clone(),
            keys: keys.clone(),
            sign_in: sign_in.clone(),
            identity: Arc::new(FakeIdentity(Mutex::new(Ok(identity_of(&key))))),
            transports: Arc::new(script),
            now: Box::new(move || Duration::from_secs(now.load(Ordering::SeqCst))),
            device_name: "Test".into(),
        });
        e.load(RemoteSettings { origin: Some("https://flow.example.com".into()), state: "off".into(), notice: None });
        Fx { e, secrets, keys, sign_in, counters, key, clock }
    }

    fn pair_token(key: &[u8]) -> PairingToken {
        let value = format!("lfp_{}", base64url_encode(&[key, &[9u8; 32]].concat()));
        PairingToken::parse(&value).unwrap()
    }

    fn item(f: &Fx, account: &str) -> Option<Vec<u8>> {
        f.secrets.read(account).unwrap()
    }

    /// An approved device with a refresh token and a live key.
    fn approved(replies: Vec<Reply>) -> Fx {
        let f = fx(replies);
        f.e.pin(&identity_of(&f.key)).unwrap();
        let (handle, _) = f.keys.create().unwrap();
        f.secrets.write("device-key", &handle).unwrap();
        f.secrets.write("refresh-token", b"lfr_old").unwrap();
        f.e.load(RemoteSettings { state: "approved".into(), ..f.e.settings() });
        f
    }

    #[test]
    fn nothing_connects_before_consent() {
        let f = fx(vec![]);
        f.e.load(RemoteSettings::default());
        assert_eq!(f.e.fetch_server_identity().err(), Some(EnrollError::NotConfigured));
        assert_eq!(f.e.pin(&identity_of(&f.key)), Err(EnrollError::NotConfigured));
        assert_eq!(f.e.pair(&pair_token(&f.key)), Err(EnrollError::NotConfigured));
        assert_eq!(f.e.enroll(IdentityProvider::Google), Err(EnrollError::NotConfigured));
        assert_eq!(f.e.access_token(), None);
        assert_eq!(f.counters.opened(), 0);
    }

    #[test]
    fn pin_replaces_everything_and_never_a_bad_identity() {
        let f = approved(vec![]);
        let old = item(&f, "device-key").unwrap();
        let mut bad = identity_of(&f.key);
        bad.fingerprint = "0".into();
        assert_eq!(f.e.pin(&bad), Err(EnrollError::InvalidIdentity));
        assert!(item(&f, "refresh-token").is_some(), "a refused pin changes nothing");
        f.e.pin(&identity_of(&[1; 32])).unwrap();
        assert_eq!(item(&f, "server-key").unwrap(), [1; 32]);
        assert_eq!(item(&f, "refresh-token"), None);
        assert_eq!(f.keys.public_key(&old), None, "the old device key is deleted");
        assert_eq!(f.e.settings().state, "pinned");
    }

    #[test]
    fn enroll_binds_the_nonce_and_stores_the_answer() {
        let f = fx(vec![Reply::ready(), Reply::enrolled("pending", Some("lfr_1"))]);
        f.e.pin(&identity_of(&f.key)).unwrap();
        assert_eq!(f.e.enroll(IdentityProvider::Google), Ok("pending".to_string()));
        assert_eq!(*f.sign_in.nonce.lock().unwrap(), base64url_encode(&f.counters.binding()), "Google's nonce is the binding");
        let m = &f.counters.messages()[1];
        assert_eq!((m["type"].as_str(), m["provider"].as_str(), m["id_token"].as_str()), (Some("enroll"), Some("google"), Some("id-token")));
        assert_eq!(item(&f, "refresh-token").unwrap(), b"lfr_1");
        assert!(item(&f, "device-key").is_some());
        assert_eq!(f.e.settings().state, "pending");
    }

    #[test]
    fn apple_nonce_is_the_hash_of_the_binding() {
        let f = fx(vec![Reply::ready(), Reply::enrolled("rejected", None)]);
        f.e.pin(&identity_of(&f.key)).unwrap();
        assert_eq!(f.e.enroll(IdentityProvider::Apple), Ok("rejected".to_string()));
        let expect: String = sha256(base64url_encode(&f.counters.binding()).as_bytes()).iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(*f.sign_in.nonce.lock().unwrap(), expect);
        assert_eq!(item(&f, "refresh-token"), None);
    }

    #[test]
    fn enroll_failures() {
        let f = fx(vec![Reply::ready()]);
        f.e.pin(&identity_of(&f.key)).unwrap();
        f.sign_in.refuse.store(true, Ordering::SeqCst);
        assert_eq!(f.e.enroll(IdentityProvider::Google), Err(EnrollError::SignInFailed));
        assert!(f.keys.keys.lock().unwrap().is_empty(), "the unused key is deleted");
        assert_eq!(item(&f, "device-key"), None);

        let f = fx(vec![]);
        f.e.pin(&identity_of(&f.key)).unwrap();
        f.keys.unavailable.store(true, Ordering::SeqCst);
        assert_eq!(f.e.enroll(IdentityProvider::Google), Err(EnrollError::DeviceKeyUnavailable));
        assert_eq!(f.counters.opened(), 0);

        let f = fx(vec![Reply::Close(4001)]);
        f.e.pin(&identity_of(&f.key)).unwrap();
        assert_eq!(f.e.enroll(IdentityProvider::Google), Err(EnrollError::Channel(ChannelError::PinMismatch)));
        assert_eq!(f.e.settings().state, "pin_mismatch");
        assert_eq!(item(&f, "server-key").unwrap(), f.key, "never re-pins");
    }

    #[test]
    fn approved_enrollment_refreshes_at_once() {
        let f = fx(vec![Reply::ready(), Reply::enrolled("approved", Some("lfr_1")), Reply::ready(), Reply::tokens("lfa_1", "lfr_2")]);
        f.e.pin(&identity_of(&f.key)).unwrap();
        f.e.enroll(IdentityProvider::Google).unwrap();
        assert_eq!(item(&f, "access-token").unwrap(), b"lfa_1");
        assert_eq!(item(&f, "refresh-token").unwrap(), b"lfr_2");
    }

    #[test]
    fn pair_success_pins_then_refreshes() {
        let f = fx(vec![Reply::ready(), Reply::enrolled("approved", Some("lfr_1")), Reply::ready(), Reply::tokens("lfa_1", "lfr_2")]);
        f.e.pair(&pair_token(&f.key)).unwrap();
        assert_eq!(item(&f, "server-key").unwrap(), f.key);
        assert_eq!(item(&f, "refresh-token").unwrap(), b"lfr_2");
        assert_eq!(item(&f, "access-token").unwrap(), b"lfa_1");
        assert_eq!(f.e.settings().state, "approved");
        let m = &f.counters.messages()[1];
        assert_eq!(m["type"], "pair");
        assert_eq!(f.counters.messages()[0]["purpose"], "enroll");
    }

    #[test]
    fn a_token_for_another_server_never_opens_a_socket() {
        let f = fx(vec![]);
        assert_eq!(f.e.pair(&pair_token(&[5; 32])), Err(EnrollError::WrongServer));
        assert_eq!(f.counters.opened(), 0);
        assert!(f.keys.keys.lock().unwrap().is_empty());
    }

    #[test]
    fn a_refused_token_leaves_a_working_device_alone() {
        let f = approved(vec![Reply::ready(), Reply::error("pairing_token_invalid")]);
        assert_eq!(f.e.pair(&pair_token(&f.key)), Err(EnrollError::Channel(ChannelError::Server("pairing_token_invalid".into()))));
        assert_eq!(item(&f, "refresh-token").unwrap(), b"lfr_old");
        assert_eq!(f.e.settings().state, "approved");
        assert_eq!(f.keys.keys.lock().unwrap().len(), 1, "the attempt's key is deleted, the device's stays");
    }

    #[test]
    fn a_lost_reply_retries_with_the_same_key_and_busy_keeps_it() {
        let f = fx(vec![Reply::ready(), Reply::Close(1006), Reply::ready(), Reply::error("busy"), Reply::ready(), Reply::enrolled("approved", Some("lfr_1")), Reply::ready(), Reply::tokens("a", "r")]);
        let token = pair_token(&f.key);
        assert_eq!(f.e.pair(&token), Err(EnrollError::Channel(ChannelError::Unreachable)));
        assert_eq!(f.e.pair(&token), Err(EnrollError::Channel(ChannelError::Server("busy".into()))));
        f.e.pair(&token).unwrap();
        let sent = f.counters.messages();
        let keys: Vec<_> = sent.iter().filter(|m| m["type"] == "pair").map(|m| m["device_key"].clone()).collect();
        assert_eq!(keys.len(), 3);
        assert!(keys.iter().all(|k| *k == keys[0]));
        assert_eq!(f.keys.keys.lock().unwrap().len(), 1);
    }

    #[test]
    fn a_server_without_pair_needs_an_update_and_the_channel_may_not_carry() {
        let f = fx(vec![Reply::ready(), Reply::error("invalid_message")]);
        assert_eq!(f.e.pair(&pair_token(&f.key)), Err(EnrollError::UpdateRequired));
        assert_eq!(f.e.settings().notice.as_deref(), Some("update_required"));

        let f = fx(vec![Reply::Close(1006)]);
        assert_eq!(f.e.pair(&pair_token(&f.key)), Err(EnrollError::UnusableRoute));
        let f = fx(vec![Reply::Close(4001)]);
        assert_eq!(f.e.pair(&pair_token(&f.key)), Err(EnrollError::WrongServer), "the channel, unlike the identity route, proves who holds the key");
    }

    #[test]
    fn access_token_ages_on_the_clock() {
        let f = approved(vec![Reply::ready(), Reply::tokens("a1", "r1"), Reply::ready(), Reply::tokens("a2", "r2")]);
        assert!(f.e.refresh_due(), "unknown age");
        assert_eq!(f.e.access_token().as_deref(), Some("a1"));
        assert!(!f.e.refresh_due());
        f.clock.fetch_add(REFRESH_AFTER.as_secs() - 1, Ordering::SeqCst);
        assert_eq!(f.e.access_token().as_deref(), Some("a1"));
        assert_eq!(f.counters.opened(), 1);
        f.clock.fetch_add(1, Ordering::SeqCst);
        assert!(f.e.refresh_due());
        assert_eq!(f.e.access_token().as_deref(), Some("a2"));
        assert_eq!(item(&f, "refresh-token").unwrap(), b"r2");
    }

    #[test]
    fn concurrent_refreshes_share_one() {
        let f = approved(vec![Reply::ready(), Reply::tokens("a1", "r1")]);
        let (first, second) = std::thread::scope(|s| {
            let (a, b) = (s.spawn(|| f.e.refresh_now()), s.spawn(|| f.e.refresh_now()));
            (a.join().unwrap(), b.join().unwrap())
        });
        // Either they overlapped and shared, or the second started after and found no replies left.
        assert!(first.as_deref() == Some("a1") || second.as_deref() == Some("a1"));
        assert_eq!(item(&f, "refresh-token").unwrap(), b"r1");
    }

    #[test]
    fn server_answers_change_state_and_credentials() {
        let case = |code: &str| {
            let f = approved(vec![Reply::ready(), Reply::error(code)]);
            assert_eq!(f.e.refresh_now(), None);
            f
        };
        let f = case("revoked");
        assert_eq!(f.e.settings().state, "revoked");
        assert_eq!(item(&f, "refresh-token"), None);
        assert_eq!(item(&f, "server-key").unwrap(), f.key);
        let f = case("not_approved");
        assert_eq!(f.e.settings().state, "pending");
        assert_eq!(item(&f, "refresh-token").unwrap(), b"lfr_old", "stays valid");
        let f = case("unauthorized");
        assert_eq!((f.e.settings().state.as_str(), f.e.settings().notice.as_deref()), ("pinned", Some("sign_in_again")));
        assert_eq!(item(&f, "refresh-token"), None);
        let f = case("busy");
        assert_eq!(f.e.settings().state, "approved");
        assert_eq!(item(&f, "refresh-token").unwrap(), b"lfr_old");
    }

    #[test]
    fn device_key_loss_and_keychain_failure_differ() {
        let f = approved(vec![]);
        let handle = item(&f, "device-key").unwrap();
        f.keys.delete(&handle).unwrap();
        assert_eq!(f.e.refresh_now(), None);
        assert_eq!((f.e.settings().state.as_str(), f.e.settings().notice.as_deref()), ("pinned", Some("sign_in_again")));
        assert_eq!(item(&f, "refresh-token"), None);
        assert_eq!(item(&f, "device-key"), None);
        assert_eq!(item(&f, "server-key").unwrap(), f.key);
        assert_eq!(f.counters.opened(), 0);
    }

    #[test]
    fn a_pin_mismatch_on_refresh_blocks_and_keeps_the_pin() {
        let f = approved(vec![Reply::Close(4001)]);
        f.secrets.write("access-token", b"a").unwrap();
        assert_eq!(f.e.refresh_now(), None);
        assert_eq!(f.e.settings().state, "pin_mismatch");
        assert_eq!(item(&f, "access-token"), None);
        assert_eq!(item(&f, "server-key").unwrap(), f.key);
        assert_eq!(f.e.access_token(), None, "nothing goes out in this state");
        assert_eq!(f.counters.opened(), 1);
    }

    #[test]
    fn session_channel_retries_once_after_token_expired() {
        let f = approved(vec![Reply::ready(), Reply::tokens("a1", "r1"), Reply::error("token_expired"), Reply::ready(), Reply::tokens("a2", "r2"), Reply::ready()]);
        f.e.session_channel().unwrap();
        let hellos: Vec<_> = f.counters.messages().into_iter().filter(|m| m["purpose"] == "session").collect();
        assert_eq!(hellos[0]["access_token"], "a1");
        assert_eq!(hellos[1]["access_token"], "a2");

        let f = approved(vec![Reply::ready(), Reply::tokens("a1", "r1"), Reply::error("revoked")]);
        assert_eq!(f.e.session_channel().err(), Some(ChannelError::Server("revoked".into())));
        assert_eq!(f.e.settings().state, "revoked");
    }

    #[test]
    fn update_address_only_for_the_pinned_key() {
        let f = approved(vec![Reply::ready()]);
        f.e.update_address("https://new.example.com").unwrap();
        assert_eq!(f.e.settings().origin.as_deref(), Some("https://new.example.com"));
        assert_eq!(item(&f, "refresh-token").unwrap(), b"lfr_old", "only the address changes");
        assert_eq!(f.e.update_address("http://8.8.8.8"), Err(EnrollError::NotConfigured), "refused before connecting");
        assert_eq!(f.counters.opened(), 1);

        let f = approved(vec![Reply::Close(4001)]);
        assert_eq!(f.e.update_address("https://new.example.com"), Err(EnrollError::WrongServer));
        assert_eq!(f.e.settings().origin.as_deref(), Some("https://flow.example.com"));
        let f = approved(vec![Reply::Close(1006)]);
        assert_eq!(f.e.update_address("https://new.example.com"), Err(EnrollError::UnusableRoute));
    }

    #[test]
    fn turn_off_removes_everything_and_stops_what_runs() {
        let f = approved(vec![]);
        let handle = item(&f, "device-key").unwrap();
        let generation = f.e.generation();
        f.e.turn_off();
        assert!(f.secrets.items.lock().unwrap().is_empty());
        assert_eq!(f.keys.public_key(&handle), None);
        assert_ne!(f.e.generation(), generation);
        assert_eq!(f.e.settings().origin, None);
    }

    #[test]
    fn a_turn_off_during_a_pair_stores_nothing() {
        // The identity fetch answers, then the user turns off before the reply is read.
        struct OffDuring(Arc<Mutex<Option<Arc<Enrollment>>>>, Script);
        impl Transports for OffDuring {
            fn open(&self, url: &str) -> Result<Box<dyn Transport>, TransportError> {
                self.0.lock().unwrap().as_ref().unwrap().cancel();
                self.1.open(url)
            }
        }
        let script = Script::new(vec![Reply::ready(), Reply::enrolled("approved", Some("lfr_1"))]);
        let key = script.public_key();
        let slot = Arc::new(Mutex::new(None));
        let secrets = Arc::new(MemorySecrets::default());
        let e = Arc::new(Enrollment::new(Parts {
            secrets: secrets.clone(),
            keys: Arc::new(MemoryDeviceKeys::default()),
            sign_in: Arc::new(FakeSignIn::default()),
            identity: Arc::new(FakeIdentity(Mutex::new(Ok(identity_of(&key))))),
            transports: Arc::new(OffDuring(slot.clone(), script)),
            now: Box::new(|| Duration::ZERO),
            device_name: "T".into(),
        }));
        *slot.lock().unwrap() = Some(e.clone());
        e.load(RemoteSettings { origin: Some("https://x.example".into()), state: "off".into(), notice: None });
        assert_eq!(e.pair(&pair_token(&key)), Err(EnrollError::TurnedOff));
        assert!(secrets.items.lock().unwrap().is_empty());
    }

    #[test]
    fn identity_failures_map() {
        let f = fx(vec![]);
        let identity = |r| Enrollment::new(Parts { secrets: f.secrets.clone(), keys: f.keys.clone(), sign_in: f.sign_in.clone(), identity: Arc::new(FakeIdentity(Mutex::new(r))), transports: Arc::new(Script::new(vec![])), now: Box::new(|| Duration::ZERO), device_name: "T".into() });
        let e = identity(Err(IdentityError::Unreachable));
        e.load(f.e.settings());
        assert_eq!(e.fetch_server_identity().err(), Some(EnrollError::Unreachable));
        let e = identity(Err(IdentityError::Invalid));
        e.load(f.e.settings());
        assert_eq!(e.fetch_server_identity().err(), Some(EnrollError::InvalidIdentity));
    }

    #[test]
    fn device_names_fit_the_contract() {
        assert_eq!(device_name("Mac\u{7}\nmini"), "Macmini");
        assert_eq!(device_name(&"é".repeat(40)).len(), 64, "cut on a character boundary");
    }
}

/// T012: the real server. Each test gets its own flowd, on loopback, with temp data.
#[cfg(all(test, unix))]
pub(crate) mod flowd_tests {
    use super::super::MemorySecrets;
    use super::*;
    use crate::settings::test_flowd::Flowd;
    use std::sync::Arc;

    /// A software P-256 key in the test's Go overlay: flowd verifies what it signs.
    struct GoKeys {
        flowd: Arc<Flowd>,
        scalars: Mutex<Vec<(Vec<u8>, String, Vec<u8>)>>,
    }
    impl DeviceKeys for GoKeys {
        fn create(&self) -> Result<(Vec<u8>, Vec<u8>), Unavailable> {
            let (scalar, public) = self.flowd.keygen();
            let mut scalars = self.scalars.lock().unwrap();
            let handle = vec![scalars.len() as u8 + 1];
            scalars.push((handle.clone(), scalar, public.clone()));
            Ok((handle, public))
        }
        fn public_key(&self, handle: &[u8]) -> Option<Vec<u8>> {
            self.scalars.lock().unwrap().iter().find(|k| k.0 == handle).map(|k| k.2.clone())
        }
        fn sign(&self, message: &[u8], handle: &[u8]) -> Result<Vec<u8>, Unavailable> {
            let scalars = self.scalars.lock().unwrap();
            let key = scalars.iter().find(|k| k.0 == handle).ok_or(Unavailable("device key"))?;
            Ok(self.flowd.sign(&key.1, message))
        }
        fn delete(&self, handle: &[u8]) -> Result<(), Unavailable> {
            self.scalars.lock().unwrap().retain(|k| k.0 != handle);
            Ok(())
        }
    }

    struct NoSignIn;
    impl SignIn for NoSignIn {
        fn sign_in(&self, _: IdentityProvider, _: &str) -> Result<String, Unavailable> {
            Err(Unavailable("sign in"))
        }
    }

    pub(crate) fn client(flowd: &Arc<Flowd>, origin: &str) -> (Enrollment, Arc<MemorySecrets>) {
        let secrets = Arc::new(MemorySecrets::default());
        let e = Enrollment::new(Parts {
            secrets: secrets.clone(),
            keys: Arc::new(GoKeys { flowd: flowd.clone(), scalars: Mutex::default() }),
            sign_in: Arc::new(NoSignIn),
            identity: Arc::new(HttpIdentity),
            transports: Arc::new(WebSockets::default()),
            now: Box::new(system_now),
            device_name: "Conformance Mac".into(),
        });
        e.load(RemoteSettings { origin: Some(origin.into()), state: "off".into(), notice: None });
        (e, secrets)
    }

    pub(crate) fn token(f: &Flowd) -> PairingToken {
        PairingToken::parse(&f.pair_token("conformance")).unwrap()
    }

    fn get(s: &MemorySecrets, account: &str) -> Option<Vec<u8>> {
        s.read(account).unwrap()
    }

    #[test]
    fn pair_refresh_rotation_and_a_spent_token() {
        let f = Arc::new(Flowd::start());
        let (e, secrets) = client(&f, &f.remote);
        let t = token(&f);
        e.pair(&t).expect("pairs");
        assert_eq!(e.settings().state, "approved");
        assert!(get(&secrets, "device-key").is_some());
        let access = get(&secrets, "access-token").expect("refreshed right after pairing");
        let refresh = get(&secrets, "refresh-token").unwrap();
        assert_eq!(get(&secrets, "server-key").unwrap(), t.server_key);

        let live = e.access_token().unwrap();
        assert_eq!(live.as_bytes(), access, "still fresh: no refresh");
        assert!(settings::ping(&f.remote, Some(&t.server_key), Some(&live)).is_some(), "the token opens a session");

        let rotated = e.refresh_now().expect("refreshes");
        assert_ne!(rotated.as_bytes(), access);
        assert_ne!(get(&secrets, "refresh-token").unwrap(), refresh, "the refresh token rotates");
        assert!(settings::ping(&f.remote, Some(&t.server_key), Some(&rotated)).is_some());

        // Spent: a second device with the same token.
        let (other, other_secrets) = client(&f, &f.remote);
        assert_eq!(other.pair(&t), Err(EnrollError::Channel(ChannelError::Server("pairing_token_invalid".into()))));
        assert!(other_secrets.items.lock().unwrap().is_empty(), "nothing stored");
        assert_eq!(super::super::pairing::failure_message(&EnrollError::Channel(ChannelError::Server("pairing_token_invalid".into()))), "This token has expired, been used or been revoked. Ask for a new one.");

        let pool = Arc::new(e);
        assert!(Enrollment::pool(&pool).round_trip(super::super::pool::Role::Background).is_ok(), "the pool opens real session channels");
    }

    #[test]
    fn a_token_from_another_server_stays_unspent() {
        let (f, g) = (Arc::new(Flowd::start()), Arc::new(Flowd::start()));
        let t = token(&f);
        let (wrong, secrets) = client(&f, &g.remote);
        assert_eq!(wrong.pair(&t), Err(EnrollError::WrongServer));
        assert!(secrets.items.lock().unwrap().is_empty());
        let (right, _) = client(&f, &f.remote);
        right.pair(&t).expect("the token still works at its own server");
    }

    #[test]
    fn a_refused_http_address_never_connects_and_a_dead_one_doesnt_pair() {
        let f = Arc::new(Flowd::start());
        let (e, _) = client(&f, "http://8.8.8.8");
        assert_eq!(e.pair(&token(&f)), Err(EnrollError::NotConfigured));
        let (e, _) = client(&f, &f.down);
        assert_eq!(e.pair(&token(&f)), Err(EnrollError::Unreachable));
        let (e, _) = client(&f, &f.rewrite);
        assert_eq!(e.pair(&token(&f)), Err(EnrollError::InvalidIdentity), "answers, with no identity route");
    }

    #[test]
    fn address_edit_same_and_different_key() {
        let (f, g) = (Arc::new(Flowd::start()), Arc::new(Flowd::start()));
        let (e, secrets) = client(&f, &f.remote);
        e.pair(&token(&f)).unwrap();
        let refresh = get(&secrets, "refresh-token").unwrap();

        let same = f.remote.replace("127.0.0.1", "localhost");
        e.update_address(&same).expect("the same server under another name");
        assert_eq!(e.settings().origin.as_deref(), Some(same.as_str()));
        assert_eq!(get(&secrets, "refresh-token").unwrap(), refresh);

        assert_eq!(e.update_address(&g.remote), Err(EnrollError::WrongServer));
        assert_eq!(e.settings().origin.as_deref(), Some(same.as_str()), "unchanged");
        assert_eq!(e.update_address(&f.down), Err(EnrollError::Unreachable));
        assert_eq!(e.update_address(&f.rewrite), Err(EnrollError::InvalidIdentity));
        assert!(e.refresh_now().is_some(), "still works at the new address");
    }

    #[test]
    fn turn_off_removes_all_and_the_server_key_change_is_caught() {
        let (f, g) = (Arc::new(Flowd::start()), Arc::new(Flowd::start()));
        let (e, secrets) = client(&f, &f.remote);
        e.pair(&token(&f)).unwrap();
        e.turn_off();
        assert!(secrets.items.lock().unwrap().is_empty());
        assert_eq!(e.access_token(), None);

        // Pinned to one server, but the address now answers with another's key.
        let (e, secrets) = client(&f, &f.remote);
        e.pair(&token(&f)).unwrap();
        e.load(RemoteSettings { origin: Some(g.remote.clone()), ..e.settings() });
        assert_eq!(e.refresh_now(), None);
        assert_eq!(e.settings().state, "pin_mismatch");
        assert!(get(&secrets, "server-key").is_some(), "never re-pins");
        assert_eq!(get(&secrets, "access-token"), None);
    }

    #[test]
    fn revocation_reaches_the_client() {
        let f = Arc::new(Flowd::start());
        let (e, secrets) = client(&f, &f.remote);
        e.pair(&token(&f)).unwrap();
        f.revoke_newest_device();
        assert_eq!(e.refresh_now(), None);
        assert_eq!(e.settings().state, "revoked");
        assert_eq!(get(&secrets, "refresh-token"), None);
        assert_eq!(get(&secrets, "access-token"), None);
    }
}
