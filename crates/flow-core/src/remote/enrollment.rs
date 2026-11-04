//! `RemoteEnrollment`: identity and pin, pairing, tokens, server answers and turning off.
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
    /// An `https://` address whose server doesn't speak TLS. Holds the `http://` twin when FR-012a
    /// allows one on that host and it didn't answer either; `pair` tries it first.
    NotTls(Option<String>),
    /// The address's name doesn't resolve. Holds the host.
    UnknownHost(String),
    DeviceKeyUnavailable,
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
    /// Other addresses of the same server, tried in order when `origin` doesn't connect.
    pub alternates: Vec<String>,
}

impl RemoteSettings {
    pub fn from_prefs(p: &Prefs) -> RemoteSettings {
        let origin = settings::remote_enrollment_origin(p);
        let alternates = if origin.is_some() { settings::remote_addresses(p).into_iter().skip(1).collect() } else { vec![] };
        RemoteSettings { origin, state: settings::remote_state(p).to_string(), notice: settings::remote_notice(p).map(str::to_string), alternates }
    }
    pub fn store(&self, p: &mut Prefs) {
        if let Some(origin) = &self.origin {
            p.set("remote.serverURL", origin.as_str());
            if self.alternates.is_empty() {
                p.remove("remote.alternateAddresses");
            } else {
                p.set("remote.alternateAddresses", &self.alternates);
            }
        }
        p.set("remote.state", self.state.as_str());
        match &self.notice {
            Some(notice) => p.set("remote.notice", notice.as_str()),
            None => p.remove("remote.notice"),
        }
    }
    /// The current address first, then the others.
    pub fn addresses(&self) -> Vec<String> {
        self.origin.iter().chain(&self.alternates).cloned().collect()
    }
    pub fn knows(&self, origin: &str) -> bool {
        self.origin.as_deref() == Some(origin) || self.alternates.iter().any(|a| a == origin)
    }
    /// `old` becomes `new` wherever it is, without making a repeat. A no-op when `old` isn't there.
    fn replace(&mut self, old: &str, new: &str) {
        if old == new || !self.knows(old) {
            return;
        }
        let mut all: Vec<String> = Vec::new();
        for address in self.addresses() {
            let address = if address == old { new.to_string() } else { address };
            if !all.contains(&address) {
                all.push(address);
            }
        }
        let mut all = all.into_iter();
        self.origin = all.next();
        self.alternates = all.collect();
    }
    /// An alternate that worked becomes current, in place of the old current. Anything else is a no-op,
    /// so a turn off that emptied the settings stays empty.
    fn promote(&mut self, address: &str) {
        if let Some(i) = self.alternates.iter().position(|a| a == address)
            && let Some(old) = self.origin.replace(address.to_string())
        {
            self.alternates[i] = old;
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
    pub identity: Arc<dyn IdentityFetching>,
    pub transports: Arc<dyn Transports>,
    /// Includes time asleep, as Swift's `ContinuousClock` does; a token doesn't stop ageing.
    pub now: Box<dyn Fn() -> Duration + Send + Sync>,
    pub device_name: String,
    /// `mac`, `windows` or `iphone`, chosen by the platform; sent only to a server whose identity
    /// lists `device_kind` (Feature 028, contracts/device-kind.md).
    pub device_kind: Option<String>,
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
    /// A redeemed invite waiting for the inviting device: its key, this device's key and the binding
    /// of the channel that carried `pair`. Memory only; the code is all that's shown.
    invite_wait: Option<(Vec<u8>, Vec<u8>, [u8; 32])>,
}

pub struct Enrollment {
    parts: Parts,
    inner: Mutex<Inner>,
    /// One refresh at a time; holds the last result for whoever waited.
    refreshing: Mutex<Option<String>>,
    refreshes: AtomicU64,
    /// Bumped on turn off. Whatever started earlier stores nothing.
    generation: AtomicU64,
    /// Bumped on turn off and on every pin: a refresh already running holds the old credentials.
    credentials: AtomicU64,
}

impl Enrollment {
    pub fn new(parts: Parts) -> Enrollment {
        Enrollment { parts, inner: Mutex::default(), refreshing: Mutex::new(None), refreshes: AtomicU64::new(0), generation: AtomicU64::new(0), credentials: AtomicU64::new(0) }
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

    /// The first address that connects, which then stays current. Only a failure to reach an address
    /// moves on; what happens on the channel afterwards, a pin mismatch included, belongs to its caller.
    fn connect_any(&self, key: &[u8]) -> Result<Channel, ChannelError> {
        let mut last = ChannelError::Closed;
        for address in self.settings().addresses() {
            match self.connect(&address, key) {
                Ok(channel) => {
                    self.inner().settings.promote(&address);
                    return Ok(channel);
                }
                Err(e @ (ChannelError::Unreachable | ChannelError::Timeout)) => last = e,
                Err(e) => return Err(e),
            }
        }
        Err(last)
    }

    // MARK: Identity and pinning

    fn fetch_at(&self, origin: &str) -> Result<Identity, EnrollError> {
        let identity = self.parts.identity.fetch(origin).map_err(|e| match e {
            IdentityError::Unreachable => EnrollError::Unreachable,
            IdentityError::Invalid => EnrollError::InvalidIdentity,
            IdentityError::NotTls => EnrollError::NotTls(super::address::plain_http(origin)),
            IdentityError::UnknownHost => EnrollError::UnknownHost(super::address::host(origin).to_string()),
        })?;
        identity.validated_key().ok_or(EnrollError::InvalidIdentity)?;
        Ok(identity)
    }

    /// The identity at `origin` and the address that served it. An `https://` address that a plain
    /// listener answered is tried once as `http://` where FR-012a allows that host. This weakens
    /// nothing: the identity must still be the token's or the pinned key, and the token, credentials
    /// and content only travel sealed to that key (ADR 0037). Plain http shows timing, sizes and the
    /// public key, which FR-012a accepts for these hosts and the address row says.
    fn reach(&self, origin: &str) -> Result<(String, Identity), EnrollError> {
        match self.fetch_at(origin) {
            Ok(identity) => Ok((origin.to_string(), identity)),
            Err(EnrollError::NotTls(Some(plain))) => match self.fetch_at(&plain) {
                Ok(identity) => Ok((plain, identity)),
                Err(EnrollError::Unreachable) => Err(EnrollError::NotTls(Some(plain))),
                Err(e) => Err(e),
            },
            Err(e) => Err(e),
        }
    }

    /// An error that only says this address didn't answer, so another may be tried.
    fn not_answered(e: &EnrollError) -> bool {
        matches!(e, EnrollError::Unreachable | EnrollError::UnusableRoute | EnrollError::NotTls(_) | EnrollError::UnknownHost(_) | EnrollError::Channel(ChannelError::Unreachable | ChannelError::Timeout))
    }

    /// Pins a server's key. Only pairing pins; a later mismatch never re-pins.
    pub fn pin(&self, identity: &Identity) -> Result<(), EnrollError> {
        self.pin_locked(&mut self.inner(), identity)
    }

    fn pin_locked(&self, inner: &mut Inner, identity: &Identity) -> Result<(), EnrollError> {
        if inner.settings.origin.is_none() {
            return Err(EnrollError::NotConfigured);
        }
        let key = identity.validated_key().ok_or(EnrollError::InvalidIdentity)?;
        self.credentials.fetch_add(1, Ordering::SeqCst);
        self.drop_device_key();
        self.parts.secrets.remove_all()?;
        inner.access_issued_at = None;
        inner.invite_wait = None;
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

    /// Replaces the addresses of the same server. An address that's down now may be kept, but at least
    /// one must verify, and any that answers with another key refuses the lot. Only the addresses change.
    pub fn update_address(&self, text: &str) -> Result<(), EnrollError> {
        let generation = self.generation();
        let (Some(_), Some(pinned), Some(entered)) = (self.origin(), self.pinned_key(), super::address::origins(text)) else { return Err(EnrollError::NotConfigured) };
        let mut entered = entered;
        let mut verified = None;
        let mut last = EnrollError::NotConfigured;
        for address in entered.iter_mut() {
            match self.verify_address(address, &pinned) {
                Ok(answered) => {
                    *address = answered;
                    verified.get_or_insert_with(|| address.clone());
                }
                Err(e) if Self::not_answered(&e) && !matches!(e, EnrollError::Channel(_)) => last = e,
                Err(e) => return Err(e),
            }
        }
        let entered = entered.into_iter().fold(Vec::new(), |mut unique: Vec<String>, a| {
            if !unique.contains(&a) {
                unique.push(a);
            }
            unique
        });
        let Some(first) = verified else { return Err(last) };
        let mut inner = self.inner();
        if generation != self.generation() {
            return Err(EnrollError::TurnedOff);
        }
        inner.settings.alternates = entered.into_iter().filter(|a| *a != first).collect();
        inner.settings.origin = Some(first);
        Ok(())
    }

    /// The identity at `address` must be the pinned key and a channel must open there. The address
    /// that answered, which is `http://` for an `https://` one that `reach` downgraded.
    fn verify_address(&self, address: &str, pinned: &[u8]) -> Result<String, EnrollError> {
        let (address, identity) = self.reach(address)?;
        let key = identity.validated_key().ok_or(EnrollError::InvalidIdentity)?;
        if key != pinned {
            return Err(EnrollError::WrongServer);
        }
        match self.open_checked(&address, pinned) {
            Ok(_) => Ok(address),
            Err(EnrollError::Channel(ChannelError::PinMismatch)) => Err(EnrollError::WrongServer),
            Err(e) => Err(e),
        }
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

    fn create_key(&self) -> Result<(Vec<u8>, Vec<u8>), EnrollError> {
        let (handle, public) = self.parts.keys.create().map_err(|_| EnrollError::DeviceKeyUnavailable)?;
        let public = x963_public_key(&public).ok_or(EnrollError::DeviceKeyUnavailable)?;
        Ok((handle, public))
    }

    // MARK: Pairing

    /// Redeems a pairing token at the first address that reaches its server. The caller has shown
    /// consent. Only an address that can't be reached moves on: any answer from a server stops here,
    /// so a refused token goes nowhere else. The address that worked becomes current.
    pub fn pair(&self, token: &PairingToken) -> Result<(), EnrollError> {
        let generation = self.generation();
        let mut result = Err(EnrollError::NotConfigured);
        for address in self.settings().addresses() {
            result = self.pair_at(&address, token, generation);
            if !result.as_ref().is_err_and(Self::not_answered) {
                break;
            }
        }
        if result.is_ok() {
            self.refresh_now();
        }
        result
    }

    /// The token goes only into a channel sealed to the key it names, and only if the address serves
    /// that key. The pin, which clears existing credentials, comes after the server's answer, so a
    /// refused token leaves a working device as it was. The kept attempt means another address, like
    /// a retry, redeems with the same device key.
    fn pair_at(&self, tried: &str, token: &PairingToken, generation: u64) -> Result<(), EnrollError> {
        channel_url(tried).ok_or(EnrollError::NotConfigured)?;
        let (origin, identity) = self.reach(tried)?;
        let origin = origin.as_str();
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
        let result = self.pair_with(token, &identity, origin, &handle, &public, generation);
        if result.is_ok() && origin != tried {
            // The `http://` twin that answered takes the place of the address typed.
            let mut inner = self.inner();
            if generation == self.generation() {
                inner.settings.replace(tried, origin);
                inner.settings.promote(origin);
            }
        }
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
            Err(EnrollError::Channel(ChannelError::PinMismatch)) => Err(EnrollError::WrongServer),
            // A flowd without `pair` refuses the unknown type with invalid_message, then closes.
            Err(EnrollError::Channel(ChannelError::Server(code))) if code == "invalid_message" || code == "unsupported_version" => {
                self.apply("unsupported_version");
                Err(EnrollError::UpdateRequired)
            }
            other => other,
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
        let mut pair = json!({"type": "pair", "op": 1, "pairing_token": token.value, "device_name": device_name(&self.parts.device_name), "device_key": base64url_encode(public), "signature": base64url_encode(&signature)});
        // Older servers refuse unknown fields, so only one that advertises it gets the kind.
        if let Some(kind) = self.parts.device_kind.as_ref().filter(|_| identity.has_feature("device_kind")) {
            pair["device_kind"] = json!(kind);
        }
        channel.send(pair)?;
        match channel.receive()? {
            // An invite leaves the device pending until the inviting device confirms it.
            ServerMessage::Enrolled { op: 1, state, refresh_token: Some(refresh), invite } if state == "approved" || state == "pending" => {
                // One guard: a turn off comes wholly before this, or removes all of it afterwards.
                let mut inner = self.inner();
                if generation != self.generation() {
                    return Err(EnrollError::TurnedOff);
                }
                self.pin_locked(&mut inner, identity)?;
                self.parts.secrets.write("device-key", handle)?;
                self.parts.secrets.write("refresh-token", refresh.as_bytes())?;
                inner.pair_attempt = None;
                inner.settings.promote(origin);
                inner.settings.state = state;
                inner.invite_wait = invite.map(|(inviter, _)| (inviter, public.to_vec(), channel.binding()));
                Ok(())
            }
            ServerMessage::Error { code } => Err(ChannelError::Server(code).into()),
            _ => Err(EnrollError::Protocol),
        }
    }

    /// The 6-digit code this device shows while a redeemed invite waits for confirmation.
    pub fn invite_code(&self) -> Option<String> {
        let inner = self.inner();
        let (inviter, own, binding) = inner.invite_wait.as_ref().filter(|_| inner.settings.state == "pending")?;
        Some(super::devices::device_code(inviter, own, binding))
    }

    /// This device's X9.63 key, for the code the inviting device shows.
    pub fn device_public_key(&self) -> Option<Vec<u8>> {
        let handle = self.parts.secrets.read("device-key").ok()??;
        self.parts.keys.public_key(&handle)
    }

    /// A DER signature by this device's key, for `device_confirm`.
    pub fn device_sign(&self, input: &[u8]) -> Option<Vec<u8>> {
        let handle = self.parts.secrets.read("device-key").ok()??;
        self.parts.keys.sign(input, &handle).ok()
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
        let credentials = self.credentials.load(Ordering::SeqCst);
        self.origin()?;
        let key = self.pinned_key()?;
        let refresh = self.token("refresh-token")?;
        // A read that failed isn't a lost key: the Keychain may only be locked.
        let handle = self.parts.secrets.read("device-key").ok()?;
        let Some(handle) = handle.filter(|h| self.parts.keys.public_key(h).is_some()) else {
            self.device_key_lost();
            return None;
        };
        let mut channel = match self.connect_any(&key) {
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
        // Pinned or turned off meanwhile: this answer is about credentials that are gone.
        if credentials != self.credentials.load(Ordering::SeqCst) {
            return None;
        }
        match result {
            Ok(None) => {
                self.device_key_lost();
                None
            }
            Ok(Some(ServerMessage::Tokens { op: 1, access_token, refresh_token })) => {
                let mut inner = self.inner();
                if credentials != self.credentials.load(Ordering::SeqCst) {
                    return None;
                }
                self.parts.secrets.write("refresh-token", refresh_token.as_bytes()).ok()?;
                self.parts.secrets.write("access-token", access_token.as_bytes()).ok()?;
                inner.access_issued_at = Some((self.parts.now)());
                inner.invite_wait = None;
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
        let (key, token) = (self.pinned_key()?, self.access_token()?);
        self.settings().addresses().iter().find_map(|origin| settings::ping(origin, Some(&key), Some(&token)))?.1
    }

    /// The cooling probe (`dictation::cooling`): `GET /v1/remote/identity` at `origin` answers with
    /// the key this device pinned. No token and no channel, so it's cheap and sends nothing new.
    pub fn probe(&self, origin: &str) -> bool {
        let Some(pinned) = self.pinned_key() else { return false };
        self.parts.identity.fetch(origin).ok().and_then(|identity| identity.validated_key()).is_some_and(|key| key == pinned)
    }

    pub fn session_channel(&self) -> Result<Channel, ChannelError> {
        self.origin().ok_or(ChannelError::Closed)?;
        let key = self.pinned_key().ok_or(ChannelError::Closed)?;
        let mut token = self.access_token().ok_or(ChannelError::Closed)?;
        let mut retried = false;
        loop {
            let mut channel = self.connect_any(&key)?;
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

    /// Close code 4001: refuse to send anything until the user pairs again. Never re-pins.
    pub fn handle_pin_mismatch(&self) {
        self.apply("pin_mismatch");
    }

    /// The key no longer loads, as after a restore onto new hardware. The user pairs again.
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
        self.credentials.fetch_add(1, Ordering::SeqCst);
        inner.settings = RemoteSettings::default();
        inner.access_issued_at = None;
        inner.invite_wait = None;
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
    pub(crate) fn identity_of(key: &[u8]) -> Identity {
        Identity { schema_version: 1, server: json!({}), protocol_versions: vec![1], suite: "x25519-hkdfsha256-chacha20poly1305".into(), server_key: base64url_encode(key), fingerprint: fingerprint_of(key), features: vec![] }
    }

    struct Fx {
        e: Enrollment,
        secrets: Arc<MemorySecrets>,
        keys: Arc<MemoryDeviceKeys>,
        counters: Counters,
        key: Vec<u8>,
        clock: Arc<AtomicU64>,
    }

    fn fx(replies: Vec<Reply>) -> Fx {
        let script = Script::new(replies);
        let (counters, key) = (script.counters(), script.public_key());
        let secrets = Arc::new(MemorySecrets::default());
        let keys = Arc::new(MemoryDeviceKeys::default());
        let clock = Arc::new(AtomicU64::new(1000));
        let now = clock.clone();
        let e = Enrollment::new(Parts {
            secrets: secrets.clone(),
            keys: keys.clone(),
            identity: Arc::new(FakeIdentity(Mutex::new(Ok(identity_of(&key))))),
            transports: Arc::new(script),
            now: Box::new(move || Duration::from_secs(now.load(Ordering::SeqCst))),
            device_name: "Test".into(),
            device_kind: None,
        });
        e.load(RemoteSettings { origin: Some("https://flow.example.com".into()), state: "off".into(), notice: None, alternates: vec![] });
        Fx { e, secrets, keys, counters, key, clock }
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

    /// T041: `device_kind` goes in `pair` only when the identity lists the feature.
    #[test]
    fn device_kind_is_sent_only_when_advertised() {
        let pair = |features: &[&str], kind: Option<&str>| {
            let script = Script::new(vec![Reply::ready(), Reply::enrolled("approved", Some("lfr_1")), Reply::ready(), Reply::tokens("lfa_1", "lfr_2")]);
            let (counters, key) = (script.counters(), script.public_key());
            let identity = Identity { features: features.iter().map(|f| f.to_string()).collect(), ..identity_of(&key) };
            let e = Enrollment::new(Parts {
                secrets: Arc::new(MemorySecrets::default()),
                keys: Arc::new(MemoryDeviceKeys::default()),
                identity: Arc::new(FakeIdentity(Mutex::new(Ok(identity)))),
                transports: Arc::new(script),
                now: Box::new(|| Duration::from_secs(1000)),
                device_name: "Test".into(),
                device_kind: kind.map(String::from),
            });
            e.load(RemoteSettings { origin: Some("https://flow.example.com".into()), state: "off".into(), notice: None, alternates: vec![] });
            e.pair(&pair_token(&key)).unwrap();
            counters.messages()[1].clone()
        };
        assert_eq!(pair(&["device_kind"], Some("mac"))["device_kind"], "mac");
        assert_eq!(pair(&["device_invite", "device_kind", "later"], Some("windows"))["device_kind"], "windows");
        assert!(pair(&[], Some("mac")).get("device_kind").is_none(), "an older server refuses unknown fields");
        assert!(pair(&["device_invite"], Some("mac")).get("device_kind").is_none());
        assert!(pair(&["device_kind"], None).get("device_kind").is_none(), "a platform without a kind");
    }

    #[test]
    fn nothing_connects_before_consent() {
        let f = fx(vec![]);
        f.e.load(RemoteSettings::default());
        assert_eq!(f.e.pin(&identity_of(&f.key)), Err(EnrollError::NotConfigured));
        assert_eq!(f.e.pair(&pair_token(&f.key)), Err(EnrollError::NotConfigured));
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

    /// An invite: pending with a code until a refresh finds the device confirmed.
    #[test]
    fn an_invite_waits_with_the_code_until_confirmed() {
        let inviter = [&[4u8][..], &[7; 64]].concat();
        let enrolled = json!({"schema_version": 1, "type": "enrolled", "op": 1, "state": "pending", "refresh_token": "lfr_1", "inviter_device_key": base64url_encode(&inviter), "confirm_by": "2026-11-03T10:24:30Z"});
        let f = fx(vec![Reply::ready(), Reply::Json(enrolled), Reply::ready(), Reply::error("not_approved"), Reply::ready(), Reply::tokens("lfa_1", "lfr_2")]);
        f.e.pair(&pair_token(&f.key)).unwrap();
        assert_eq!(f.e.settings().state, "pending");
        assert_eq!(item(&f, "refresh-token").unwrap(), b"lfr_1");
        let own = f.e.device_public_key().unwrap();
        assert_eq!(f.e.invite_code(), Some(super::super::devices::device_code(&inviter, &own, &f.counters.bindings()[0])));
        f.e.refresh_now();
        assert_eq!(f.e.settings().state, "approved");
        assert_eq!(f.e.invite_code(), None, "gone once confirmed");
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
    fn pair_needs_a_device_key() {
        let f = fx(vec![]);
        f.keys.unavailable.store(true, Ordering::SeqCst);
        assert_eq!(f.e.pair(&pair_token(&f.key)), Err(EnrollError::DeviceKeyUnavailable));
        assert_eq!(f.counters.opened(), 0);
    }

    // parity: SET-099
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

    // parity: SET-099
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

    // parity: SET-097
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
        let f = case("unsupported_version");
        assert_eq!(f.e.settings().notice.as_deref(), Some("update_required"));
        let f = case("busy");
        assert_eq!(f.e.settings().state, "approved");
        assert_eq!(item(&f, "refresh-token").unwrap(), b"lfr_old");
    }

    /// Runs `during` once, as the first frame of the second reply arrives: an op caught in flight.
    struct Midway {
        script: Script,
        during: Arc<Mutex<Option<Box<dyn FnOnce() + Send>>>>,
    }
    struct MidwayEnd(Box<dyn Transport>, Arc<Mutex<Option<Box<dyn FnOnce() + Send>>>>, u32);
    impl Transports for Midway {
        fn open(&self, url: &str) -> Result<Box<dyn Transport>, TransportError> {
            Ok(Box::new(MidwayEnd(self.script.open(url)?, self.during.clone(), 0)))
        }
    }
    impl Transport for MidwayEnd {
        fn send(&mut self, frame: &[u8]) -> Result<(), TransportError> {
            self.0.send(frame)
        }
        fn receive(&mut self) -> Result<Received, TransportError> {
            self.2 += 1;
            if self.2 == 2 {
                if let Some(during) = self.1.lock().unwrap().take() {
                    during();
                }
            }
            self.0.receive()
        }
        fn close(&mut self) {
            self.0.close();
        }
    }

    #[test]
    fn a_refresh_running_during_a_new_pin_stores_nothing() {
        let script = Script::new(vec![Reply::ready(), Reply::tokens("old-access", "old-refresh")]);
        let key = script.public_key();
        let secrets = Arc::new(MemorySecrets::default());
        let keys = Arc::new(MemoryDeviceKeys::default());
        let during: Arc<Mutex<Option<Box<dyn FnOnce() + Send>>>> = Arc::default();
        let e = Arc::new(Enrollment::new(Parts {
            secrets: secrets.clone(),
            keys: keys.clone(),
            identity: Arc::new(FakeIdentity(Mutex::new(Ok(identity_of(&key))))),
            transports: Arc::new(Midway { script, during: during.clone() }),
            now: Box::new(|| Duration::from_secs(1000)),
            device_name: "Test".into(),
            device_kind: None,
        }));
        e.load(RemoteSettings { origin: Some("https://flow.example.com".into()), state: "approved".into(), notice: None, alternates: vec![] });
        e.pin(&identity_of(&key)).unwrap();
        e.load(RemoteSettings { state: "approved".into(), ..e.settings() });
        let (handle, _) = keys.create().unwrap();
        secrets.write("device-key", &handle).unwrap();
        secrets.write("refresh-token", b"lfr_old").unwrap();
        let (again, store, pinned) = (e.clone(), secrets.clone(), key.clone());
        *during.lock().unwrap() = Some(Box::new(move || {
            again.pin(&identity_of(&pinned)).unwrap();
            store.write("refresh-token", b"lfr_new").unwrap();
        }));
        assert_eq!(e.refresh_now(), None);
        assert_eq!(secrets.read("refresh-token").unwrap().unwrap(), b"lfr_new");
        assert_eq!(secrets.read("access-token").unwrap(), None);
    }

    /// A turn off on another thread while pairing stores its credentials ends with none of them.
    #[test]
    fn a_turn_off_racing_a_pair_leaves_no_credentials() {
        struct Racing(MemorySecrets, Mutex<Option<Box<dyn FnOnce() + Send>>>);
        impl Secrets for Racing {
            fn read(&self, account: &str) -> Result<Option<Vec<u8>>, Unavailable> {
                self.0.read(account)
            }
            fn write(&self, account: &str, value: &[u8]) -> Result<(), Unavailable> {
                if account == "server-key" {
                    if let Some(off) = self.1.lock().unwrap().take() {
                        std::thread::spawn(off);
                        std::thread::sleep(Duration::from_millis(20));
                    }
                }
                self.0.write(account, value)
            }
            fn remove(&self, account: &str) -> Result<(), Unavailable> {
                self.0.remove(account)
            }
        }
        let script = Script::new(vec![Reply::ready(), Reply::enrolled("approved", Some("lfr_1"))]);
        let key = script.public_key();
        let secrets = Arc::new(Racing(MemorySecrets::default(), Mutex::new(None)));
        let e = Arc::new(Enrollment::new(Parts {
            secrets: secrets.clone(),
            keys: Arc::new(MemoryDeviceKeys::default()),
            identity: Arc::new(FakeIdentity(Mutex::new(Ok(identity_of(&key))))),
            transports: Arc::new(script),
            now: Box::new(|| Duration::from_secs(1000)),
            device_name: "Test".into(),
            device_kind: None,
        }));
        e.load(RemoteSettings { origin: Some("https://flow.example.com".into()), state: "off".into(), notice: None, alternates: vec![] });
        let (off, done) = (e.clone(), Arc::new(AtomicBool::new(false)));
        let finished = done.clone();
        *secrets.1.lock().unwrap() = Some(Box::new(move || {
            off.turn_off();
            finished.store(true, Ordering::SeqCst);
        }));
        let _ = e.pair(&pair_token(&key));
        while !done.load(Ordering::SeqCst) {
            std::thread::sleep(Duration::from_millis(1));
        }
        for account in ["server-key", "device-key", "refresh-token", "access-token"] {
            assert_eq!(secrets.read(account).unwrap(), None, "{account}");
        }
    }

    // parity: SET-098
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

    // parity: SET-068
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

    /// One server behind several addresses. `dead` answers nothing at all, `no_socket` answers the
    /// identity route but carries no channel, `wrong` serves another server's key. A `Script` serves the rest.
    #[derive(Clone, Default)]
    struct Net {
        dead: Vec<&'static str>,
        no_socket: Vec<&'static str>,
        wrong: Vec<&'static str>,
        /// A plain http listener: `https://` fails TLS there.
        plain: Vec<&'static str>,
        /// Names that don't resolve.
        unknown: Vec<&'static str>,
        identities: Arc<Mutex<Vec<String>>>,
        sockets: Arc<Mutex<Vec<String>>>,
        urls: Arc<Mutex<Vec<String>>>,
    }
    struct NetIdentity(Net, Identity);
    impl IdentityFetching for NetIdentity {
        fn fetch(&self, origin: &str) -> Result<Identity, IdentityError> {
            self.0.identities.lock().unwrap().push(origin.to_string());
            let hit = |list: &[&str]| list.iter().any(|d| origin.contains(d));
            if hit(&self.0.unknown) {
                return Err(IdentityError::UnknownHost);
            }
            if hit(&self.0.plain) && origin.starts_with("https://") {
                return Err(IdentityError::NotTls);
            }
            if hit(&self.0.dead) {
                return Err(IdentityError::Unreachable);
            }
            Ok(if hit(&self.0.wrong) { identity_of(&[1; 32]) } else { self.1.clone() })
        }
    }
    struct NetTransports(Net, Script);
    impl Transports for NetTransports {
        fn open(&self, url: &str) -> Result<Box<dyn Transport>, TransportError> {
            let host = url.split('/').nth(2).unwrap_or_default().to_string();
            self.0.sockets.lock().unwrap().push(host.clone());
            self.0.urls.lock().unwrap().push(url.to_string());
            if self.0.dead.iter().chain(&self.0.no_socket).any(|d| host.contains(d)) {
                return Err(TransportError::Unreachable);
            }
            self.1.open(url)
        }
    }

    /// `current` then `others`, with nothing pinned yet. `dead`, `no_socket` and `wrong` name hosts.
    fn net(net: Net, replies: Vec<Reply>, current: &str, others: &[&str]) -> (Fx, Net) {
        let script = Script::new(replies);
        let (counters, key) = (script.counters(), script.public_key());
        let (secrets, keys) = (Arc::new(MemorySecrets::default()), Arc::new(MemoryDeviceKeys::default()));
        let e = Enrollment::new(Parts {
            secrets: secrets.clone(),
            keys: keys.clone(),
            identity: Arc::new(NetIdentity(net.clone(), identity_of(&key))),
            transports: Arc::new(NetTransports(net.clone(), script)),
            now: Box::new(|| Duration::from_secs(1000)),
            device_name: "Test".into(),
            device_kind: None,
        });
        e.load(RemoteSettings { origin: Some(current.into()), state: "off".into(), notice: None, alternates: others.iter().map(|o| o.to_string()).collect() });
        (Fx { e, secrets, keys, counters, key, clock: Arc::default() }, net)
    }

    /// `net`, as an approved device.
    fn approved_net(n: Net, replies: Vec<Reply>, current: &str, others: &[&str]) -> (Fx, Net) {
        let (f, n) = net(n, replies, current, others);
        f.e.pin(&identity_of(&f.key)).unwrap();
        let (handle, _) = f.keys.create().unwrap();
        f.secrets.write("device-key", &handle).unwrap();
        f.secrets.write("refresh-token", b"lfr_old").unwrap();
        f.e.load(RemoteSettings { state: "approved".into(), ..f.e.settings() });
        (f, n)
    }

    fn seen(list: &Mutex<Vec<String>>) -> Vec<String> {
        std::mem::take(&mut list.lock().unwrap())
    }

    #[test]
    fn settings_round_trip_the_alternates_and_know_them() {
        let mut p = Prefs::memory();
        p.set("remote.enabled", true);
        p.set("remote.consentVersion", 2);
        p.set("remote.serverURL", "https://a.example");
        p.set("remote.alternateAddresses", ["https://b.example"]);
        let mut s = RemoteSettings::from_prefs(&p);
        assert_eq!(s.alternates, ["https://b.example"]);
        assert!(s.knows("https://a.example") && s.knows("https://b.example") && !s.knows("https://c.example"));
        s.promote("https://b.example");
        s.store(&mut p);
        assert_eq!(settings::remote_addresses(&p), ["https://b.example", "https://a.example"]);
        s.alternates.clear();
        s.store(&mut p);
        assert!(!p.contains("remote.alternateAddresses"));
        p.set("remote.alternateAddresses", ["https://b.example"]);
        p.set("remote.enabled", false);
        assert_eq!(RemoteSettings::from_prefs(&p).addresses(), Vec::<String>::new(), "nothing to connect to while off");
    }

    #[test]
    fn a_dead_address_fails_over_and_the_one_that_answers_sticks() {
        let n = Net { dead: vec!["a.example"], ..Default::default() };
        let (f, n) = approved_net(n, vec![Reply::ready(), Reply::tokens("a1", "r1"), Reply::ready(), Reply::tokens("a2", "r2"), Reply::ready()], "https://a.example", &["https://b.example", "https://c.example"]);
        assert_eq!(f.e.refresh_now().as_deref(), Some("a1"));
        assert_eq!(seen(&n.sockets), ["a.example", "b.example"]);
        let s = f.e.settings();
        assert_eq!(s.origin.as_deref(), Some("https://b.example"));
        assert_eq!(s.alternates, ["https://a.example", "https://c.example"], "the old current takes its place");
        assert_eq!(f.e.refresh_now().as_deref(), Some("a2"));
        assert_eq!(seen(&n.sockets), ["b.example"], "the dead one isn't tried first again");
        f.e.session_channel().unwrap();
        assert_eq!(seen(&n.sockets), ["b.example"]);
        assert_eq!(f.e.settings().origin.as_deref(), Some("https://b.example"));
    }

    #[test]
    fn every_address_dead_fails_like_one() {
        let n = Net { dead: vec!["a.example", "b.example"], ..Default::default() };
        let (f, n) = approved_net(n, vec![], "https://a.example", &["https://b.example"]);
        assert_eq!(f.e.refresh_now(), None);
        assert_eq!(f.e.session_channel().err(), Some(ChannelError::Closed), "no token to open one with");
        assert_eq!(seen(&n.sockets).len(), 4);
        assert_eq!(f.e.settings().origin.as_deref(), Some("https://a.example"));
        assert_eq!(f.e.settings().state, "approved");
    }

    #[test]
    fn a_pin_mismatch_is_never_retried_elsewhere() {
        let (f, n) = approved_net(Net::default(), vec![Reply::Close(4001)], "https://a.example", &["https://b.example"]);
        assert_eq!(f.e.refresh_now(), None);
        assert_eq!(f.e.settings().state, "pin_mismatch");
        assert_eq!(seen(&n.sockets), ["a.example"]);
        assert_eq!(item(&f, "server-key").unwrap(), f.key);

        let (f, n) = approved_net(Net::default(), vec![Reply::ready(), Reply::tokens("a", "r"), Reply::Close(4001)], "https://a.example", &["https://b.example"]);
        assert_eq!(f.e.session_channel().err(), Some(ChannelError::PinMismatch));
        assert_eq!(seen(&n.sockets), ["a.example", "a.example"], "the refresh, then the session");
    }

    #[test]
    fn pair_skips_a_dead_address_and_refreshes_through_the_one_that_worked() {
        let n = Net { dead: vec!["a.example"], ..Default::default() };
        let (f, n) = net(n, vec![Reply::ready(), Reply::enrolled("approved", Some("lfr_1")), Reply::ready(), Reply::tokens("lfa_1", "lfr_2")], "https://a.example", &["https://b.example"]);
        f.e.pair(&pair_token(&f.key)).unwrap();
        assert_eq!(seen(&n.identities), ["https://a.example", "https://b.example"]);
        assert_eq!(seen(&n.sockets), ["b.example", "b.example"], "the current address is the new one before the refresh");
        let s = f.e.settings();
        assert_eq!((s.origin.as_deref(), s.alternates.as_slice(), s.state.as_str()), (Some("https://b.example"), ["https://a.example".to_string()].as_slice(), "approved"));
        assert_eq!(item(&f, "refresh-token").unwrap(), b"lfr_2");
    }

    #[test]
    fn pair_skips_an_unusable_route_and_a_lost_reply_with_the_same_key() {
        let n = Net { no_socket: vec!["a.example"], ..Default::default() };
        let (f, n) = net(n, vec![Reply::ready(), Reply::Close(1006), Reply::ready(), Reply::enrolled("approved", Some("lfr_1")), Reply::ready(), Reply::tokens("a", "r")], "https://a.example", &["https://b.example", "https://c.example"]);
        f.e.pair(&pair_token(&f.key)).unwrap();
        assert_eq!(seen(&n.sockets), ["a.example", "b.example", "c.example", "c.example"]);
        let sent: Vec<_> = f.counters.messages().into_iter().filter(|m| m["type"] == "pair").map(|m| m["device_key"].clone()).collect();
        assert_eq!(sent.len(), 2);
        assert_eq!(sent[0], sent[1], "another address retries with the same device key");
        assert_eq!(f.keys.keys.lock().unwrap().len(), 1);
        assert_eq!(f.e.settings().origin.as_deref(), Some("https://c.example"));
    }

    #[test]
    fn a_refused_token_never_goes_to_another_address() {
        let (f, n) = net(Net::default(), vec![Reply::ready(), Reply::error("pairing_token_invalid")], "https://a.example", &["https://b.example"]);
        assert_eq!(f.e.pair(&pair_token(&f.key)), Err(EnrollError::Channel(ChannelError::Server("pairing_token_invalid".into()))));
        assert_eq!(seen(&n.identities), ["https://a.example"]);
        assert_eq!(seen(&n.sockets), ["a.example"]);
        assert_eq!(f.e.settings().origin.as_deref(), Some("https://a.example"));

        let n = Net { wrong: vec!["a.example"], ..Default::default() };
        let (f, n) = net(n, vec![], "https://a.example", &["https://b.example"]);
        assert_eq!(f.e.pair(&pair_token(&f.key)), Err(EnrollError::WrongServer), "another server's key stops too");
        assert_eq!(seen(&n.identities), ["https://a.example"]);
        assert!(seen(&n.sockets).is_empty());
    }

    #[test]
    fn every_pair_address_dead_returns_the_last_failure() {
        let n = Net { dead: vec!["a.example"], no_socket: vec!["b.example"], ..Default::default() };
        let (f, _n) = net(n, vec![], "https://a.example", &["https://b.example"]);
        assert_eq!(f.e.pair(&pair_token(&f.key)), Err(EnrollError::UnusableRoute));
        assert_eq!(f.e.settings().origin.as_deref(), Some("https://a.example"));
    }

    /// The owner typed `https://` for flowd's plain listener on a tailnet name: the `http://` twin
    /// pairs, through a channel sealed to the token's key, and replaces what was typed.
    #[test]
    fn https_to_a_plain_tailnet_listener_pairs_over_http() {
        let n = Net { plain: vec!["ai.tail75b52d.ts.net"], ..Default::default() };
        let replies = vec![Reply::ready(), Reply::enrolled("approved", Some("lfr_1")), Reply::ready(), Reply::tokens("lfa_1", "lfr_2")];
        let (f, n) = net(n, replies, "https://ai.tail75b52d.ts.net:8090", &["https://b.example"]);
        f.e.pair(&pair_token(&f.key)).unwrap();
        assert_eq!(seen(&n.identities), ["https://ai.tail75b52d.ts.net:8090", "http://ai.tail75b52d.ts.net:8090"], "retried once over http");
        assert_eq!(seen(&n.urls), ["ws://ai.tail75b52d.ts.net:8090/v1/remote/channel", "ws://ai.tail75b52d.ts.net:8090/v1/remote/channel"]);
        let s = f.e.settings();
        assert_eq!((s.origin.as_deref(), s.alternates.as_slice()), (Some("http://ai.tail75b52d.ts.net:8090"), ["https://b.example".to_string()].as_slice()));
        assert_eq!(s.state, "approved");
        assert_eq!(f.counters.messages()[1]["type"], "pair");
    }

    #[test]
    fn a_plain_listener_on_an_alternate_becomes_current_over_http() {
        let n = Net { dead: vec!["a.example"], plain: vec!["mini.local"], ..Default::default() };
        let replies = vec![Reply::ready(), Reply::enrolled("approved", Some("lfr_1")), Reply::ready(), Reply::tokens("lfa_1", "lfr_2")];
        let (f, _n) = net(n, replies, "https://a.example", &["https://mini.local"]);
        f.e.pair(&pair_token(&f.key)).unwrap();
        let s = f.e.settings();
        assert_eq!((s.origin.as_deref(), s.alternates.as_slice()), (Some("http://mini.local"), ["https://a.example".to_string()].as_slice()));
    }

    #[test]
    fn https_that_isnt_tls_says_so_and_never_downgrades_a_public_host() {
        let n = Net { plain: vec!["plain.example.com"], ..Default::default() };
        let (f, n) = net(n, vec![], "https://plain.example.com", &[]);
        assert_eq!(f.e.pair(&pair_token(&f.key)), Err(EnrollError::NotTls(None)));
        assert_eq!(seen(&n.identities), ["https://plain.example.com"], "plain http is refused for a public name");
        assert!(seen(&n.sockets).is_empty());

        // The twin is tried but doesn't answer either: the form suggests it, nothing more.
        let n = Net { plain: vec!["ai.tail75b52d.ts.net"], dead: vec!["ai.tail75b52d.ts.net"], ..Default::default() };
        let (f, n) = net(n, vec![], "https://ai.tail75b52d.ts.net:8090", &[]);
        assert_eq!(f.e.pair(&pair_token(&f.key)), Err(EnrollError::NotTls(Some("http://ai.tail75b52d.ts.net:8090".into()))));
        assert_eq!(seen(&n.identities).len(), 2);
        assert_eq!(f.e.settings().origin.as_deref(), Some("https://ai.tail75b52d.ts.net:8090"), "nothing stored");

        // The twin answers with another server's key: refused like any address.
        let n = Net { plain: vec!["mini.local"], wrong: vec!["mini.local"], ..Default::default() };
        let (f, n) = net(n, vec![], "https://mini.local", &[]);
        assert_eq!(f.e.pair(&pair_token(&f.key)), Err(EnrollError::WrongServer));
        assert!(seen(&n.sockets).is_empty(), "the token never left");
    }

    #[test]
    fn an_unknown_name_says_so_and_moves_on() {
        let n = Net { unknown: vec!["typo.example"], ..Default::default() };
        let (f, _n) = net(n, vec![], "https://typo.example:8443", &[]);
        assert_eq!(f.e.pair(&pair_token(&f.key)), Err(EnrollError::UnknownHost("typo.example".into())));
        let n = Net { unknown: vec!["typo.example"], ..Default::default() };
        let replies = vec![Reply::ready(), Reply::enrolled("approved", Some("lfr_1")), Reply::ready(), Reply::tokens("lfa_1", "lfr_2")];
        let (f, _n) = net(n, replies, "https://typo.example", &["https://b.example"]);
        f.e.pair(&pair_token(&f.key)).expect("the next address");
        assert_eq!(f.e.settings().origin.as_deref(), Some("https://b.example"));
    }

    #[test]
    fn update_address_takes_the_http_twin_of_a_plain_listener() {
        let n = Net { plain: vec!["mini.local"], ..Default::default() };
        let (f, n) = approved_net(n, vec![Reply::ready(), Reply::ready()], "https://old.example", &[]);
        f.e.update_address("https://mini.local:8090, http://mini.local:8090").unwrap();
        let s = f.e.settings();
        assert_eq!((s.origin.as_deref(), s.alternates.len()), (Some("http://mini.local:8090"), 0), "one address, no repeat");
        assert_eq!(seen(&n.urls), ["ws://mini.local:8090/v1/remote/channel"; 2], "each entry verified over http");
        let (f, _n) = approved_net(Net { plain: vec!["plain.example.com"], ..Default::default() }, vec![], "https://old.example", &[]);
        assert_eq!(f.e.update_address("https://plain.example.com"), Err(EnrollError::NotTls(None)));
        assert_eq!(f.e.settings().origin.as_deref(), Some("https://old.example"));
    }

    #[test]
    fn update_address_keeps_what_is_down_and_refuses_another_key_anywhere() {
        let list = "https://dead.example, https://good.example, https://two.example";
        let n = Net { dead: vec!["dead.example"], ..Default::default() };
        let (f, _n) = approved_net(n, vec![Reply::ready(), Reply::ready()], "https://old.example", &["https://older.example"]);
        f.e.update_address(list).unwrap();
        let s = f.e.settings();
        assert_eq!(s.origin.as_deref(), Some("https://good.example"), "the first that verified");
        assert_eq!(s.alternates, ["https://dead.example", "https://two.example"], "the rest as entered, the old list gone");
        assert_eq!(item(&f, "refresh-token").unwrap(), b"lfr_old");

        let n = Net { dead: vec!["dead.example"], wrong: vec!["wrong.example"], ..Default::default() };
        let (f, _n) = approved_net(n, vec![Reply::ready()], "https://old.example", &[]);
        assert_eq!(f.e.update_address("https://dead.example, https://good.example, https://wrong.example"), Err(EnrollError::WrongServer));
        assert_eq!((f.e.settings().origin.as_deref(), f.e.settings().alternates.len()), (Some("https://old.example"), 0), "nothing stored");

        let n = Net { dead: vec!["dead.example"], no_socket: vec!["nosocket.example"], ..Default::default() };
        let (f, _n) = approved_net(n, vec![], "https://old.example", &[]);
        assert_eq!(f.e.update_address("https://nosocket.example, https://dead.example"), Err(EnrollError::Unreachable), "the last failure");
        assert_eq!(f.e.settings().origin.as_deref(), Some("https://old.example"));
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
            identity: Arc::new(FakeIdentity(Mutex::new(Ok(identity_of(&key))))),
            transports: Arc::new(OffDuring(slot.clone(), script)),
            now: Box::new(|| Duration::ZERO),
            device_name: "T".into(),
            device_kind: None,
        }));
        *slot.lock().unwrap() = Some(e.clone());
        e.load(RemoteSettings { origin: Some("https://x.example".into()), state: "off".into(), notice: None, alternates: vec![] });
        assert_eq!(e.pair(&pair_token(&key)), Err(EnrollError::TurnedOff));
        assert!(secrets.items.lock().unwrap().is_empty());
    }

    #[test]
    fn identity_failures_map() {
        let f = fx(vec![]);
        let identity = |r| Enrollment::new(Parts { secrets: f.secrets.clone(), keys: f.keys.clone(), identity: Arc::new(FakeIdentity(Mutex::new(r))), transports: Arc::new(Script::new(vec![])), now: Box::new(|| Duration::ZERO), device_name: "T".into(), device_kind: None });
        assert_eq!(identity(Err(IdentityError::Unreachable)).fetch_at("https://x.example").err(), Some(EnrollError::Unreachable));
        assert_eq!(identity(Err(IdentityError::Invalid)).fetch_at("https://x.example").err(), Some(EnrollError::InvalidIdentity));
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

    pub(crate) fn client(flowd: &Arc<Flowd>, origin: &str) -> (Enrollment, Arc<MemorySecrets>) {
        let secrets = Arc::new(MemorySecrets::default());
        let e = Enrollment::new(Parts {
            secrets: secrets.clone(),
            keys: Arc::new(GoKeys { flowd: flowd.clone(), scalars: Mutex::default() }),
            identity: Arc::new(HttpIdentity),
            transports: Arc::new(WebSockets::default()),
            now: Box::new(system_now),
            device_name: "Conformance Mac".into(),
            device_kind: None,
        });
        e.load(RemoteSettings { origin: Some(origin.into()), state: "off".into(), notice: None, alternates: vec![] });
        (e, secrets)
    }

    pub(crate) fn token(f: &Flowd) -> PairingToken {
        PairingToken::parse(&f.pair_token("conformance")).unwrap()
    }

    fn get(s: &MemorySecrets, account: &str) -> Option<Vec<u8>> {
        s.read(account).unwrap()
    }

    // A real flowd behind a dead address: pairing and the session both reach it, and it stays first.
    #[test]
    fn a_dead_first_address_falls_through_to_the_real_server() {
        let f = Arc::new(Flowd::start());
        let dead = {
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port())
        };
        let (e, _) = client(&f, &dead);
        let mut s = e.settings();
        s.alternates = vec![f.remote.clone()];
        e.load(s);
        e.pair(&token(&f)).expect("pairs through the second address");
        assert_eq!(e.settings().origin.as_deref(), Some(f.remote.as_str()));
        assert_eq!(e.settings().alternates, [dead]);
        e.session_channel().expect("a session opens");
    }

    // parity: SET-099
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

    /// The owner's case against a real flowd: `https://` typed for its plain remote listener.
    #[test]
    fn pairs_over_http_when_https_was_typed_for_a_plain_listener() {
        let f = Arc::new(Flowd::start());
        let typed = f.remote.replace("http://", "https://");
        let (e, _) = client(&f, &typed);
        e.pair(&token(&f)).expect("the http twin pairs");
        assert_eq!(e.settings().origin.as_deref(), Some(f.remote.as_str()));
        assert!(e.settings().alternates.is_empty());
        assert!(e.refresh_now().is_some(), "and works afterwards");
    }

    #[test]
    fn pairs_past_a_closed_port() {
        let f = Arc::new(Flowd::start());
        let (e, _) = client(&f, &f.down);
        e.load(RemoteSettings { alternates: vec![f.remote.clone()], ..e.settings() });
        e.pair(&token(&f)).expect("pairs at the second address");
        assert_eq!(e.settings().origin.as_deref(), Some(f.remote.as_str()));
        assert_eq!(e.settings().alternates, [f.down.clone()]);
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

        e.update_address(&format!("{}, {same}", f.down)).expect("a down address may be kept");
        assert_eq!((e.settings().origin.as_deref(), e.settings().alternates.as_slice()), (Some(same.as_str()), [f.down.clone()].as_slice()));
        e.load(RemoteSettings { origin: Some(f.down.clone()), alternates: vec![same.clone()], ..e.settings() });
        assert!(e.refresh_now().is_some(), "over the real channel, past a closed port");
        assert_eq!(e.settings().origin.as_deref(), Some(same.as_str()), "and it sticks");
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
