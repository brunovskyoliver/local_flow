//! Store and logic behind the settings views: preference keys and their defaults, routing,
//! validators, the microphone list, shortcut rules, known speakers and the server's HTTP calls.
//! Keychain, audio and model work stay behind the platform crate's `Services`.
use crate::db::Db;
use crate::prefs::Prefs;
use rusqlite::{OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
use std::time::Duration;

/// Synthetic rows for tests, the audit and the Swift reference app. Every visible Settings
/// control lives in preferences or the secret store, so there are none.
pub fn seed(_db: &Db) {}

pub const BUNDLE_ID: &str = "org.localflow.LocalFlow";
pub const PORT_BASE: u16 = 8000;
/// The reason `enroll_device` gives when the channel failed rather than the sign-in (SET-067).
pub const SERVER_UNREACHABLE: &str = "server unreachable";
pub const CONSENT_VERSION: i64 = 2;
pub const DICTATION_CONSENT_VERSION: i64 = 1;
pub const MAX_CONTEXT_RULES: usize = 200;
pub const REMOTE_KEYS: [&str; 6] =
    ["remote.enabled", "remote.serverURL", "remote.state", "remote.consentVersion", "remote.fallbackThresholdMs", "remote.notice"];
pub const RETIRED_KEYS: [&str; 4] =
    ["meetingTranscriptionEnabled", "meetingDiarizationEnabled", "settings.meetingSummariesAutomatic", "settings.speakerIdentificationEnabled"];
pub const RELEASES_URL: &str = "https://github.com/brunovskyoliver/local_flow/releases/latest";

pub const CONSENT_TEXT: &str = "Dictation audio, transcripts, Dictionary terms and rewrite text will leave this Mac for the server below while remote dictation is on. With Use this server for everything, so will meeting audio, meeting transcripts and the text summaries are made from. The server's administrator can see audio while it is being processed. Nothing is sent until the administrator approves this device; dictation stays local whenever the server can't be reached.";
pub const MEETING_CONSENT_TEXT: &str = "Meeting audio, meeting transcripts and the text summaries are made from will leave this Mac for the server below. The server's administrator can see audio while it is being processed. Meetings handed off to the server stay there until they are merged back, at most 7 days. Nothing is sent until the administrator approves this device; recordings wait on this Mac while the server can't be reached. If you set up dictation later, dictation audio, transcripts, Dictionary terms and rewrite text go to this server too.";
pub const CONTEXT_DISCLOSURE: &str = "Reads the app name, window title and text around the cursor to spell names as they appear on screen. Never reads passwords, the clipboard or excluded apps.";

/// `http://127.0.0.1:<flowd port>`: port base plus 80.
pub fn loopback_endpoint() -> String {
    format!("http://127.0.0.1:{}", PORT_BASE + 80)
}
pub fn remote_keychain(account: &str) -> String {
    format!("{BUNDLE_ID}.remote/{account}")
}
pub fn rewrite_keychain(account: &str) -> String {
    format!("{BUNDLE_ID}.rewrite/{account}")
}
pub const SUMMARY_ACCOUNT: &str = "summary-server";

// MARK: Preferences

fn one_of(p: &Prefs, key: &str, allowed: &[&'static str], default: &'static str) -> &'static str {
    let stored = p.string(key);
    allowed.iter().find(|a| Some(**a) == stored.as_deref()).copied().unwrap_or(default)
}

pub fn appearance(p: &Prefs) -> &'static str {
    one_of(p, "appearance", &["system", "light", "dark"], "system")
}
pub fn purpose(p: &Prefs) -> &'static str {
    one_of(p, "setup.purpose", &["dictation", "meetings", "both"], "both")
}
pub fn meeting_only(p: &Prefs) -> bool {
    purpose(p) == "meetings"
}
pub fn meeting_language(p: &Prefs) -> &'static str {
    one_of(p, "settings.meetingLanguage", &["automatic", "slovak", "english"], "automatic")
}
pub fn whisper_language(language: &str) -> &'static str {
    match language {
        "slovak" => "sk",
        "english" => "en",
        _ => "auto",
    }
}
pub fn speech_model(p: &Prefs) -> &'static str {
    match p.string("speechModel").as_deref() {
        Some("parakeet-ultra") => "parakeet-ultra",
        Some(_) => "parakeet-v3",
        None if p.int_or("setupVersion", 0) == 0 => "parakeet-ultra",
        None => "parakeet-v3",
    }
}
pub fn summary_server(p: &Prefs) -> &'static str {
    one_of(p, "summaryServer", &["remote", "local"], "local")
}
pub fn rewrite_mode(p: &Prefs) -> &'static str {
    one_of(p, "rewriteDefaultMode", &["exact", "clean", "polished", "concise"], "clean")
}
pub fn rewrite_timeout(p: &Prefs) -> i64 {
    p.int_or("rewriteTimeoutSeconds", 20).clamp(5, 60)
}
pub fn local_model_idle_unload(p: &Prefs) -> i64 {
    match p.int_or("localModelIdleUnload", 0) {
        v @ (900 | 3600) => v,
        _ => 0,
    }
}
pub fn remote_state(p: &Prefs) -> &'static str {
    one_of(p, "remote.state", &["off", "pinned", "pending", "approved", "rejected", "revoked", "pin_mismatch"], "off")
}
pub fn remote_notice(p: &Prefs) -> Option<&'static str> {
    p.string("remote.notice").and_then(|n| ["sign_in_again", "update_required"].into_iter().find(|k| *k == n))
}
pub fn remote_server_url(p: &Prefs) -> String {
    p.string("remote.serverURL").and_then(|s| remote_origin(&s)).unwrap_or_default()
}
pub fn fallback_threshold(p: &Prefs) -> i64 {
    p.int_or("remote.fallbackThresholdMs", 1500)
}
/// What a key reads as when it was never written, for the booleans Swift defaults to true.
pub fn bool_pref(p: &Prefs, key: &str) -> bool {
    let default = matches!(key, "unloadLocalModelDuringGames" | "showsBackgroundProgress");
    p.bool_or(key, default)
}
/// `meetingTranscriptionEnabled` and its siblings have no switch and are not persisted.
pub const ALWAYS_ON_MEETING_FLAGS: bool = true;

/// At launch: retired keys go, and a removed language rewrites as the default.
pub fn migrate(p: &mut Prefs) {
    for key in RETIRED_KEYS {
        if p.contains(key) {
            p.remove(key);
        }
    }
    if p.contains("settings.meetingLanguage") {
        let language = meeting_language(p);
        if p.string("settings.meetingLanguage").as_deref() != Some(language) {
            p.set("settings.meetingLanguage", language);
        }
    }
}

/// `resetRemote`: the stored values go; the switch is stored off. `server.only`,
/// `server.useForEverything` and the overrides stay.
pub fn reset_remote(p: &mut Prefs) {
    p.set("remote.enabled", false);
    for key in REMOTE_KEYS.iter().filter(|k| **k != "remote.enabled") {
        p.remove(key);
    }
    p.remove("server.capabilities");
}

// MARK: Addresses and credentials

fn split_url(text: &str) -> Option<(String, &str, &str)> {
    let (scheme, rest) = text.split_once("://")?;
    if scheme.is_empty() || !scheme.chars().all(|c| c.is_ascii_alphanumeric() || "+-.".contains(c)) {
        return None;
    }
    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    Some((scheme.to_lowercase(), &rest[..end], &rest[end..]))
}

/// host, optional port. A bracketed IPv6 host keeps no brackets. `None` for a malformed authority.
fn split_authority(authority: &str) -> Option<(String, Option<u32>)> {
    if authority.contains('@') {
        return None;
    }
    let (host, port) = if let Some(rest) = authority.strip_prefix('[') {
        let (h, tail) = rest.split_once(']')?;
        (h, tail.strip_prefix(':'))
    } else {
        match authority.rsplit_once(':') {
            Some((h, p)) => (h, Some(p)),
            None => (authority, None),
        }
    };
    let port = match port {
        Some("") | None => None,
        Some(p) => Some(p.parse::<u32>().ok()?),
    };
    Some((host.to_lowercase(), port))
}

/// `RemoteDictationSettings.origin`: https, a host, no user, query, fragment or path.
pub fn remote_origin(text: &str) -> Option<String> {
    let (scheme, authority, tail) = split_url(text.trim())?;
    if scheme != "https" || (!tail.is_empty() && tail != "/") {
        return None;
    }
    let (host, port) = split_authority(authority)?;
    if host.is_empty() || host.chars().any(|c| c.is_whitespace()) || port.is_some_and(|p| p > 65535) {
        return None;
    }
    Some(match port {
        Some(p) => format!("https://{host}:{p}"),
        None => format!("https://{host}"),
    })
}

/// The host part of a stored origin, for "Server: <host>".
pub fn origin_host(origin: &str) -> String {
    let rest = origin.split_once("://").map_or(origin, |x| x.1);
    split_authority(rest).map_or_else(|| rest.to_string(), |(h, _)| h)
}

/// `RewriteSettings.normalizedOrigin`: `scheme://host:port` with an explicit port.
pub fn normalized_origin(endpoint: &str) -> Option<String> {
    let trimmed = endpoint.trim();
    if trimmed.is_empty() || trimmed.len() > 2048 {
        return None;
    }
    let (scheme, authority, _) = split_url(trimmed)?;
    if scheme != "http" && scheme != "https" {
        return None;
    }
    let (mut host, port) = split_authority(authority)?;
    if host.is_empty() || host.chars().any(|c| (c as u32) <= 32 || c as u32 == 127) {
        return None;
    }
    if port.is_some_and(|p| !(1..=65535).contains(&p)) {
        return None;
    }
    let port = port.unwrap_or(if scheme == "https" { 443 } else { 80 });
    if host.contains(':') {
        host = format!("[{host}]");
    }
    let origin = format!("{scheme}://{host}:{port}");
    (origin.len() <= 255).then_some(origin)
}

pub fn is_loopback_host(host: &str) -> bool {
    let v = host.to_lowercase();
    if v == "localhost" || v == "::1" || v == "[::1]" {
        return true;
    }
    let octets: Vec<&str> = v.split('.').collect();
    octets.len() == 4
        && octets[0] == "127"
        && octets.iter().all(|o| !o.is_empty() && o.chars().all(|c| c.is_ascii_digit()) && o.parse::<u32>().is_ok_and(|n| n <= 255))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CredentialError {
    Empty,
    TooLarge,
    InvalidCharacters,
}

pub fn validate_credential(secret: &str) -> Result<(), CredentialError> {
    if secret.is_empty() {
        return Err(CredentialError::Empty);
    }
    if secret.len() > 4096 {
        return Err(CredentialError::TooLarge);
    }
    if secret != secret.trim() || secret.contains(['\n', '\r']) {
        return Err(CredentialError::InvalidCharacters);
    }
    Ok(())
}
pub fn credential_message(e: Option<CredentialError>) -> &'static str {
    match e {
        Some(CredentialError::Empty) => "Enter a credential first.",
        Some(CredentialError::TooLarge) => "The credential must be no more than 4,096 bytes.",
        Some(CredentialError::InvalidCharacters) => "Remove surrounding whitespace and line breaks.",
        None => "Could not access the credential in Keychain.",
    }
}

/// The captured rewrite settings as the Enable switch and the connection test see them.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct RewriteSettings {
    pub origin: String,
    pub insecure_override: bool,
    pub credential_present: bool,
}

impl RewriteSettings {
    /// `credential` answers for an origin; the value is never read here.
    pub fn capture(p: &Prefs, credential: impl Fn(&str) -> bool) -> Self {
        let raw = routing(p).rewrite_endpoint(&p.string("rewriteEndpoint").unwrap_or_default());
        let origin = normalized_origin(&raw).unwrap_or_default();
        let insecure_override = !origin.is_empty() && insecure_override(p, &origin);
        let credential_present = !origin.is_empty() && credential(&origin);
        RewriteSettings { origin, insecure_override, credential_present }
    }
    pub fn valid(&self) -> bool {
        !self.origin.is_empty()
    }
    pub fn host(&self) -> String {
        origin_host(&self.origin)
    }
    pub fn is_loopback(&self) -> bool {
        is_loopback_host(&self.host())
    }
    pub fn is_unencrypted_remote(&self) -> bool {
        self.origin.starts_with("http://") && !self.is_loopback()
    }
    pub fn blocked_reason(&self) -> Option<&'static str> {
        if self.valid() && self.is_unencrypted_remote() && !self.insecure_override {
            return Some("Allow the unencrypted connection to this server first, or use https://.");
        }
        if self.valid() && !self.is_loopback() && !self.credential_present {
            return Some("Set a credential for this server first.");
        }
        (!self.valid()).then_some("Enter a valid http:// or https:// endpoint first.")
    }
    pub fn warning(&self) -> Option<String> {
        (self.is_unencrypted_remote() && self.insecure_override).then(|| {
            format!("Transcripts and the credential travel unencrypted to {}. Authentication does not encrypt them. Use this only on a network you trust.", self.host())
        })
    }
    /// The two checks that send nothing.
    pub fn preflight(&self) -> Option<Connection> {
        if !self.valid() {
            return Some(Connection::ServiceUnavailable);
        }
        if self.is_unencrypted_remote() && !self.insecure_override {
            return Some(Connection::InsecureBlocked);
        }
        (!self.is_loopback() && !self.credential_present).then_some(Connection::MissingCredential)
    }
}

pub fn insecure_override(p: &Prefs, origin: &str) -> bool {
    p.get::<BTreeMap<String, bool>>("rewriteInsecureOverrides").unwrap_or_default().get(origin).copied().unwrap_or(false)
}
/// Writes only for plain HTTP to a non-loopback host.
pub fn set_insecure_override(p: &mut Prefs, origin: &str, allow: bool) {
    let mut all = p.get::<BTreeMap<String, bool>>("rewriteInsecureOverrides").unwrap_or_default();
    if allow {
        all.insert(origin.into(), true);
    } else {
        all.remove(origin);
    }
    p.set("rewriteInsecureOverrides", all);
}

pub fn context_rewrite_blocked(context_enabled: bool, rewrite_enabled: bool) -> Option<&'static str> {
    if !context_enabled {
        return Some("Turn on Use app context first.");
    }
    (!rewrite_enabled).then_some("Turn on rewriting first.")
}
pub fn bypass_note(shortcut: &Shortcut) -> &'static str {
    if shortcut.includes_shift() { "Shift bypass is unavailable because Shift is in your shortcut." } else { "Hold Shift on release to skip rewriting once." }
}
pub fn mode_definition(mode: &str) -> &'static str {
    match mode {
        "exact" => "Insert the saved transcript unchanged. No request is sent.",
        "polished" => "Restructure sentences into natural professional writing while keeping every fact and action.",
        "concise" => "Remove repetition and clutter while keeping every fact and action.",
        _ => "Keep wording and meaning; fix punctuation, grammar and capitalization, and remove fillers, stutters and self-corrections.",
    }
}

// MARK: Server routing

#[derive(Clone, Debug, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Capabilities {
    pub ops: BTreeSet<String>,
    #[serde(default)]
    pub meeting_jobs: BTreeSet<String>,
}
impl Capabilities {
    pub fn feature014() -> Self {
        Capabilities { ops: ["dictation_start".to_string(), "rewrite".to_string()].into(), meeting_jobs: BTreeSet::new() }
    }
}
fn capabilities(p: &Prefs) -> Capabilities {
    p.get("server.capabilities").unwrap_or_else(Capabilities::feature014)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Service {
    Dictation,
    Rewrite,
    Summaries,
    FinalTranscript,
    Diarization,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Path {
    Server,
    ThisMac,
    Custom,
}

pub fn override_of(p: &Prefs, key: &str) -> &'static str {
    let v = one_of(p, key, &["server", "thisMac", "custom"], "server");
    if v == "custom" && matches!(key, "server.override.dictation" | "server.override.meetings") { "server" } else { v }
}
pub fn custom_summaries_host(p: &Prefs) -> Option<String> {
    let url = p.string("summaryServerURL").unwrap_or_default();
    let model = p.string("summaryServerModel").unwrap_or_default();
    let url = url.trim();
    if summary_server(p) != "remote" || url.is_empty() || model.trim().is_empty() {
        return None;
    }
    Some(split_url(url).and_then(|(_, a, _)| split_authority(a)).map_or(url.to_string(), |x| x.0))
}
pub fn routes_to_server(p: &Prefs) -> bool {
    p.bool_or("remote.enabled", false)
        && p.int_or("remote.consentVersion", 0) >= DICTATION_CONSENT_VERSION
        && !remote_server_url(p).is_empty()
        && remote_state(p) == "approved"
}
pub fn use_for_everything(p: &Prefs) -> bool {
    p.get::<bool>("server.useForEverything").unwrap_or_else(|| routes_to_server(p))
}
pub fn consent_current(p: &Prefs) -> bool {
    p.int_or("remote.consentVersion", 0) >= CONSENT_VERSION
}

/// `ServerRouting`: pure, so the whole truth table is testable without a server.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Routing {
    pub routes: bool,
    pub dictation_on_this_mac: bool,
    pub use_for_everything: bool,
    pub server_only: bool,
    pub rewrite: &'static str,
    pub summaries: &'static str,
    pub meetings: &'static str,
    pub capabilities: Capabilities,
    pub consent_current: bool,
    pub custom_rewrite: bool,
    pub custom_summaries: bool,
}

pub fn routing(p: &Prefs) -> Routing {
    let server_only = p.bool_or("server.only", false);
    let ov = |key| if server_only { "server" } else { override_of(p, key) };
    let custom_rewrite = normalized_origin(&p.string("rewriteEndpoint").unwrap_or_default()).is_some_and(|o| !is_loopback_host(&origin_host(&o)));
    Routing {
        routes: routes_to_server(p),
        dictation_on_this_mac: !server_only && override_of(p, "server.override.dictation") == "thisMac",
        use_for_everything: use_for_everything(p) || server_only,
        server_only,
        rewrite: ov("server.override.rewrite"),
        summaries: ov("server.override.summaries"),
        meetings: ov("server.override.meetings"),
        capabilities: capabilities(p),
        consent_current: consent_current(p),
        custom_rewrite,
        custom_summaries: custom_summaries_host(p).is_some(),
    }
}

impl Routing {
    pub fn offered(&self, s: Service) -> bool {
        let op = |o: &str| self.capabilities.ops.contains(o);
        match s {
            Service::Dictation => op("dictation_start"),
            Service::Rewrite => op("rewrite"),
            Service::Summaries => op("analysis"),
            Service::FinalTranscript => op("meeting_job") && self.capabilities.meeting_jobs.contains("transcribe"),
            Service::Diarization => op("meeting_job") && self.capabilities.meeting_jobs.contains("diarize"),
        }
    }
    pub fn served(&self, s: Service) -> bool {
        if !self.routes {
            return false;
        }
        if s == Service::Dictation {
            return !self.dictation_on_this_mac;
        }
        if !self.use_for_everything || !self.offered(s) {
            return false;
        }
        match s {
            Service::Dictation => true,
            Service::Rewrite => self.rewrite == "server",
            Service::Summaries => self.summaries == "server" && self.consent_current,
            Service::FinalTranscript | Service::Diarization => self.meetings == "server" && self.consent_current,
        }
    }
    pub fn switch_applies(&self) -> bool {
        self.routes && self.use_for_everything
    }
    fn rewrites_over_channel(&self) -> bool {
        self.routes && (!self.use_for_everything || self.served(Service::Rewrite))
    }
    pub fn path(&self, s: Service) -> Path {
        if self.served(s) {
            return Path::Server;
        }
        match s {
            Service::Rewrite => {
                if self.rewrites_over_channel() {
                    return Path::Server;
                }
                if self.switch_applies() && self.rewrite != "server" {
                    return if self.rewrite == "custom" { Path::Custom } else { Path::ThisMac };
                }
                if self.custom_rewrite { Path::Custom } else { Path::ThisMac }
            }
            Service::Summaries => {
                if self.switch_applies() && self.summaries != "custom" {
                    return Path::ThisMac;
                }
                if self.custom_summaries { Path::Custom } else { Path::ThisMac }
            }
            _ => Path::ThisMac,
        }
    }
    pub fn rewrite_endpoint(&self, stored: &str) -> String {
        if self.switch_applies() && self.rewrite == "thisMac" { loopback_endpoint() } else { stored.to_string() }
    }
    pub fn local_rewrite_model_unneeded(&self) -> bool {
        self.served(Service::Rewrite) && self.served(Service::Summaries)
    }
    pub fn place(&self, s: Service) -> &'static str {
        match self.path(s) {
            Path::Server => "On your server",
            Path::Custom => "On your custom server",
            Path::ThisMac => {
                let needs_consent = matches!(s, Service::Summaries | Service::FinalTranscript | Service::Diarization) && !self.consent_current && self.offered(s);
                if self.server_only {
                    return if self.routes && needs_consent { "Needs consent" } else { "Unavailable" };
                }
                if self.routes && self.use_for_everything && !self.offered(s) { "Not offered by this server" } else { "On this Mac" }
            }
        }
    }
    /// "Everything on your server", or each place with its services.
    pub fn placement(&self) -> String {
        let rows = [("Dictation", Service::Dictation), ("Rewriting", Service::Rewrite), ("Summaries", Service::Summaries), ("Meetings", Service::FinalTranscript)];
        let mut groups: Vec<(&str, Vec<&str>)> = vec![];
        for (name, service) in rows {
            let place = self.place(service);
            match groups.iter_mut().find(|g| g.0 == place) {
                Some(g) => g.1.push(name),
                None => groups.push((place, vec![name])),
            }
        }
        if groups.len() == 1 {
            if let Some(rest) = groups[0].0.strip_prefix("On ") {
                return format!("Everything on {rest}");
            }
        }
        groups.iter().map(|(place, rows)| format!("{place}: {}", rows.join(", "))).collect::<Vec<_>>().join(" · ")
    }
    pub fn anything_on_server(&self) -> bool {
        [Service::Dictation, Service::Rewrite, Service::Summaries, Service::FinalTranscript].iter().any(|s| self.path(*s) == Path::Server)
    }
    /// Settings › Models: where a model's work runs, or nil before approval.
    pub fn model_place(&self, s: Service) -> Option<&'static str> {
        if !self.routes {
            return None;
        }
        if !self.served(s) {
            return Some(if self.server_only { "Unavailable" } else { "On this Mac" });
        }
        Some(if s == Service::Dictation && !self.server_only { "On this Mac (used if the server is unreachable)" } else { "On your server" })
    }
}

/// The one-line remote state, or nil while the switch is off.
pub fn remote_status(p: &Prefs, has_identity: bool) -> Option<&'static str> {
    if !p.bool_or("remote.enabled", false) {
        return None;
    }
    if remote_notice(p) == Some("update_required") {
        return Some("Update LocalFlow or the server");
    }
    Some(match remote_state(p) {
        "off" if has_identity => "Compare the fingerprint",
        "off" => "Checking the server…",
        "pinned" if remote_notice(p) == Some("sign_in_again") => "Sign in again",
        "pinned" => "Sign in to finish",
        "pending" => "Waiting for approval",
        "approved" => "Approved",
        "rejected" => "Rejected",
        "revoked" => "Removed from the server",
        _ => "Server identity changed",
    })
}
/// The detail of the main remote row.
pub fn remote_detail(p: &Prefs, has_identity: bool) -> String {
    if !p.bool_or("remote.enabled", false) {
        return if meeting_only(p) { "Run meeting transcripts and notes on a LocalFlow server you run." } else { "Run dictation, rewriting, summaries and meetings on a LocalFlow server you run." }.into();
    }
    [Some(remote_server_url(p).as_str()), remote_status(p, has_identity)].into_iter().flatten().filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" · ")
}
pub fn consent_text(p: &Prefs) -> &'static str {
    if meeting_only(p) || p.bool_or("server.only", false) { MEETING_CONSENT_TEXT } else { CONSENT_TEXT }
}
/// Which server answers map to what `RemoteEnrollment` stores. Returns the Keychain accounts to
/// remove.
pub fn apply_server_answer(p: &mut Prefs, code: &str) -> Vec<&'static str> {
    match code {
        "revoked" => {
            p.set("remote.state", "revoked");
            vec!["access-token", "refresh-token"]
        }
        "not_approved" => {
            if remote_state(p) != "rejected" {
                p.set("remote.state", "pending");
            }
            vec!["access-token"]
        }
        "unauthorized" => {
            p.set("remote.state", "pinned");
            p.set("remote.notice", "sign_in_again");
            vec!["access-token", "refresh-token"]
        }
        "unsupported_version" => {
            p.set("remote.notice", "update_required");
            vec![]
        }
        "token_expired" => vec!["access-token"],
        "pin_mismatch" => {
            p.set("remote.state", "pin_mismatch");
            vec!["access-token"]
        }
        "device_key_lost" => {
            p.set("remote.state", "pinned");
            p.set("remote.notice", "sign_in_again");
            vec!["access-token", "refresh-token", "device-key"]
        }
        _ => vec![],
    }
}

// MARK: Server HTTP

/// `GET /v1/remote/identity`.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct Identity {
    pub schema_version: i64,
    pub server: Value,
    pub protocol_versions: Vec<i64>,
    pub suite: String,
    pub server_key: String,
    pub fingerprint: String,
}

/// First 16 bytes of SHA-256 over the raw key, as eight groups of four hex digits.
pub fn fingerprint_of(key: &[u8]) -> String {
    let hex = hex_of(&sha256(key));
    hex.as_bytes().chunks(4).take(8).map(|c| std::str::from_utf8(c).unwrap()).collect::<Vec<_>>().join("-")
}
fn hex_of(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
pub fn base64url_encode(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let n = chunk.iter().fold(0u32, |acc, b| acc << 8 | u32::from(*b)) << (8 * (3 - chunk.len()));
        for i in 0..=chunk.len() {
            out.push(ALPHABET[(n >> (18 - 6 * i) & 63) as usize] as char);
        }
    }
    out
}

pub fn base64url_decode(s: &str) -> Option<Vec<u8>> {
    let mut out = vec![];
    let (mut acc, mut bits) = (0u32, 0u32);
    for c in s.trim_end_matches('=').bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'-' | b'+' => 62,
            b'_' | b'/' => 63,
            _ => return None,
        };
        acc = (acc << 6) | v as u32;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    Some(out)
}
/// Plain SHA-256; the crate has no other use for a hashing dependency.
pub fn sha256(data: &[u8]) -> [u8; 32] {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];
    let mut h: [u32; 8] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    let mut msg = data.to_vec();
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&((data.len() as u64) * 8).to_be_bytes());
    for chunk in msg.chunks(64) {
        let mut w = [0u32; 64];
        for (i, b) in chunk.chunks(4).enumerate() {
            w[i] = u32::from_be_bytes(b.try_into().unwrap());
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
        }
        let mut v = h;
        for i in 0..64 {
            let s1 = v[4].rotate_right(6) ^ v[4].rotate_right(11) ^ v[4].rotate_right(25);
            let ch = (v[4] & v[5]) ^ (!v[4] & v[6]);
            let t1 = v[7].wrapping_add(s1).wrapping_add(ch).wrapping_add(K[i]).wrapping_add(w[i]);
            let s0 = v[0].rotate_right(2) ^ v[0].rotate_right(13) ^ v[0].rotate_right(22);
            let maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]);
            let t2 = s0.wrapping_add(maj);
            v = [t1.wrapping_add(t2), v[0], v[1], v[2], v[3].wrapping_add(t1), v[4], v[5], v[6]];
        }
        for (a, b) in h.iter_mut().zip(v) {
            *a = a.wrapping_add(b);
        }
    }
    let mut out = [0; 32];
    for (o, v) in out.chunks_mut(4).zip(h) {
        o.copy_from_slice(&v.to_be_bytes());
    }
    out
}

const IDENTITY_SUITE: &str = "x25519-hkdfsha256-chacha20poly1305";
impl Identity {
    /// The 32-byte key, or nil when the response is not a v1 identity.
    pub fn validated_key(&self) -> Option<Vec<u8>> {
        let key = base64url_decode(&self.server_key)?;
        (self.schema_version == 1 && self.protocol_versions.contains(&1) && self.suite == IDENTITY_SUITE && key.len() == 32 && self.fingerprint == fingerprint_of(&key)).then_some(key)
    }
}

fn agent(timeout: Duration) -> ureq::Agent {
    // No redirects: a credential never follows one. No cookies by construction.
    ureq::Agent::config_builder().timeout_global(Some(timeout)).max_redirects(0).http_status_as_error(false).proxy(None).build().into()
}

/// 10 s, must be a 200 of at most 4,096 bytes with a valid key.
pub fn fetch_identity(origin: &str) -> Result<Identity, ()> {
    let mut response = agent(Duration::from_secs(10)).get(format!("{}/v1/remote/identity", origin.trim_end_matches('/'))).call().map_err(|_| ())?;
    if response.status().as_u16() != 200 {
        return Err(());
    }
    let body = response.body_mut().with_config().limit(4096).read_to_vec().map_err(|_| ())?;
    let identity: Identity = serde_json::from_slice(&body).map_err(|_| ())?;
    identity.validated_key().map(|_| identity).ok_or(())
}

/// `wss://<host>/v1/remote/channel` for an origin; `ws://` only for a plain-HTTP local test server.
pub fn channel_url(origin: &str) -> String {
    let origin = origin.trim_end_matches('/');
    let socket = origin.strip_prefix("https://").map(|h| format!("wss://{h}")).or_else(|| origin.strip_prefix("http://").map(|h| format!("ws://{h}"))).unwrap_or_else(|| origin.to_string());
    format!("{socket}/v1/remote/channel")
}

/// Why a channel didn't reach `ready`. Swift maps all of these to "Server unreachable".
#[derive(Debug, PartialEq, Eq)]
pub enum ChannelError {
    Unreachable,
    Protocol,
    /// The server's `error.code`.
    Server(String),
}

/// `RemoteChannel.open` and `RemoteChannelPool.roundTrip`: a fresh channel with the HPKE hello
/// sealed to the pinned key, timed to `ready`, then closed. Returns the milliseconds and what
/// `ready` offered. `token` makes it a session hello; `None` is an anonymous enroll hello.
pub fn channel_round_trip(origin: &str, server_key: &[u8], token: Option<&str>) -> Result<(u128, Option<Capabilities>), ChannelError> {
    use hpke::{Deserializable, Kem as _, OpModeR, OpModeS, Serializable, aead::ChaCha20Poly1305 as Aead, kdf::HkdfSha256 as Kdf, kem::X25519HkdfSha256 as Kem};
    use rand_core::{OsRng, TryRngCore};
    use tungstenite::Message;
    const MAX_FRAME: usize = 70_000;
    let bad = |_| ChannelError::Protocol;
    let key = <Kem as hpke::Kem>::PublicKey::from_bytes(server_key).map_err(bad)?;
    let mut rng = OsRng.unwrap_err();
    let (reply_private, reply_public) = Kem::gen_keypair(&mut rng);
    let (enc, mut sender) = hpke::setup_sender::<Aead, Kdf, Kem, _>(&OpModeS::Base, &key, b"localflow remote v1", &mut rng).map_err(bad)?;
    let mut s2c_info = [0u8; 32];
    sender.export(b"localflow v1 s2c info", &mut s2c_info).map_err(bad)?;
    let mut hello = serde_json::json!({"schema_version": 1, "type": "hello", "reply_key": base64url_encode(&reply_public.to_bytes()), "purpose": if token.is_some() { "session" } else { "enroll" }});
    if let Some(token) = token {
        hello["access_token"] = token.into();
    }
    let seq = 0u64.to_be_bytes();
    let aad = [&b"LFR1"[..], &seq].concat();
    let sealed = sender.seal(hello.to_string().as_bytes(), &aad).map_err(bad)?;
    let frame = [&b"LFR1"[..], &enc.to_bytes(), &seq, &sealed].concat();

    let url = channel_url(origin);
    let started = std::time::Instant::now();
    let timeout = Duration::from_secs(10);
    let authority = url.split_once("://").map_or("", |u| u.1).split('/').next().unwrap_or_default();
    let port_default = if url.starts_with("wss") { 443 } else { 80 };
    let target = if authority.rsplit(':').next().is_some_and(|p| p.parse::<u16>().is_ok()) && !authority.ends_with(']') { authority.to_string() } else { format!("{authority}:{port_default}") };
    let address = std::net::ToSocketAddrs::to_socket_addrs(&target).ok().and_then(|mut a| a.next()).ok_or(ChannelError::Unreachable)?;
    let stream = std::net::TcpStream::connect_timeout(&address, timeout).map_err(|_| ChannelError::Unreachable)?;
    stream.set_read_timeout(Some(timeout)).map_err(|_| ChannelError::Unreachable)?;
    stream.set_write_timeout(Some(timeout)).map_err(|_| ChannelError::Unreachable)?;
    let (mut socket, _) = tungstenite::client_tls(url.as_str(), stream).map_err(|_| ChannelError::Unreachable)?;
    socket.send(Message::binary(frame)).map_err(|_| ChannelError::Unreachable)?;
    let body = loop {
        match socket.read().map_err(|_| ChannelError::Unreachable)? {
            Message::Binary(b) => break b,
            Message::Ping(_) | Message::Pong(_) => continue,
            _ => return Err(ChannelError::Unreachable),
        }
    };
    if body.len() > MAX_FRAME || body.len() <= 40 {
        return Err(ChannelError::Protocol);
    }
    let enc_s2c = <Kem as hpke::Kem>::EncappedKey::from_bytes(&body[..32]).map_err(bad)?;
    let mut recipient = hpke::setup_receiver::<Aead, Kdf, Kem>(&OpModeR::Base, &reply_private, &enc_s2c, &s2c_info).map_err(bad)?;
    let seq = &body[32..40];
    if seq != 0u64.to_be_bytes() {
        return Err(ChannelError::Protocol);
    }
    let plain = recipient.open(&body[40..], seq).map_err(bad)?;
    let elapsed = started.elapsed().as_millis();
    let _ = socket.close(None);
    let (kind, json) = plain.split_first().ok_or(ChannelError::Protocol)?;
    if *kind != 0 {
        return Err(ChannelError::Protocol);
    }
    let message: Value = serde_json::from_slice(json).map_err(|_| ChannelError::Protocol)?;
    match message.get("type").and_then(Value::as_str) {
        Some("ready") => Ok((elapsed, message.get("capabilities").and_then(|c| serde_json::from_value(c.clone()).ok()))),
        Some("error") => Err(ChannelError::Server(message.get("code").and_then(Value::as_str).unwrap_or_default().to_string())),
        _ => Err(ChannelError::Protocol),
    }
}

/// Swift's `ping()`: nil when this device has no pinned key or token, or the channel fails.
pub fn ping(origin: &str, server_key: Option<&str>, token: Option<&str>) -> Option<(u128, Option<Capabilities>)> {
    let key = base64url_decode(server_key?)?;
    channel_round_trip(origin, &key, Some(token?)).ok()
}

/// The eight connection-test outcomes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Connection {
    Connected,
    AuthenticationFailed,
    Unreachable,
    ServiceUnavailable,
    BackendUnavailable,
    IncompatibleVersion,
    MissingCredential,
    InsecureBlocked,
}
impl Connection {
    pub fn status_text(self) -> &'static str {
        match self {
            Connection::Connected => "Connected.",
            Connection::AuthenticationFailed => "The server rejected the credential.",
            Connection::Unreachable => "Could not reach the server.",
            Connection::ServiceUnavailable => "This endpoint does not provide the LocalFlow rewrite service.",
            Connection::BackendUnavailable => "The rewrite model is not available on the server.",
            Connection::IncompatibleVersion => "The server does not support rewrite protocol version 1.",
            Connection::MissingCredential => "Set a credential for this server first.",
            Connection::InsecureBlocked => "Allow the unencrypted connection to this server first, or use https://.",
        }
    }
    pub fn category(self) -> &'static str {
        match self {
            Connection::Connected => "connected",
            Connection::AuthenticationFailed => "authenticationFailed",
            Connection::Unreachable => "serverUnreachable",
            Connection::ServiceUnavailable => "rewriteServiceUnavailable",
            Connection::BackendUnavailable => "backendUnavailable",
            Connection::IncompatibleVersion => "incompatibleVersion",
            Connection::MissingCredential => "missingCredential",
            Connection::InsecureBlocked => "insecureEndpointBlocked",
        }
    }
}

/// What `GET /v1/rewrite/health` said.
#[derive(Clone, Debug, PartialEq, Eq, Default, Deserialize)]
pub struct Health {
    #[serde(default)]
    pub service: String,
    #[serde(default)]
    pub protocol_versions: Vec<i64>,
    #[serde(default)]
    pub server: Option<HealthServer>,
    #[serde(default)]
    pub backend: Option<HealthBackend>,
    #[serde(default)]
    pub prompt_versions: BTreeMap<String, i64>,
    #[serde(default)]
    pub shield_version: Option<i64>,
}
#[derive(Clone, Debug, PartialEq, Eq, Default, Deserialize)]
pub struct HealthServer {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub version: Option<String>,
}
#[derive(Clone, Debug, PartialEq, Eq, Default, Deserialize)]
pub struct HealthBackend {
    #[serde(default)]
    pub state: String,
    #[serde(default)]
    pub kind: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
}

impl Health {
    /// Service, protocol, backend, in that order.
    pub fn evaluate(&self) -> Connection {
        if self.service != "localflow-rewrite" {
            return Connection::ServiceUnavailable;
        }
        if !self.protocol_versions.contains(&1) {
            return Connection::IncompatibleVersion;
        }
        if self.backend.as_ref().is_none_or(|b| b.state != "ready") { Connection::BackendUnavailable } else { Connection::Connected }
    }
    pub fn identity_text(&self) -> String {
        let unknown = "Unknown";
        let server = self.server.clone().unwrap_or_default();
        let backend = self.backend.clone().unwrap_or_default();
        let prompts = ["clean", "polished", "concise"].iter().filter_map(|m| self.prompt_versions.get(*m).map(|v| format!("{m}: {v}"))).collect::<Vec<_>>().join(", ");
        format!(
            "Server: {} {}\nBackend: {} · {}\nPrompts: {prompts}\nShield: {}\nProtocol: {}",
            server.name.as_deref().unwrap_or(unknown),
            server.version.as_deref().unwrap_or(unknown),
            backend.kind.as_deref().unwrap_or(unknown),
            backend.model.as_deref().unwrap_or(unknown),
            self.shield_version.map_or(unknown.to_string(), |v| v.to_string()),
            self.protocol_versions.iter().take(16).map(i64::to_string).collect::<Vec<_>>().join(", "),
        )
    }
}

fn get_health(endpoint: &str, path: &str, secret: Option<&str>) -> Result<(u16, Vec<u8>), ()> {
    let (scheme, authority, _) = split_url(endpoint.trim()).ok_or(())?;
    let mut request = agent(Duration::from_secs(10)).get(format!("{scheme}://{authority}{path}")).header("Accept", "application/json");
    if let Some(secret) = secret {
        request = request.header("Authorization", format!("Bearer {secret}"));
    }
    let mut response = request.call().map_err(|_| ())?;
    let status = response.status().as_u16();
    let body = if status == 200 { response.body_mut().with_config().limit(64 * 1024).read_to_vec().map_err(|_| ())? } else { vec![] };
    Ok((status, body))
}

pub fn rewrite_health(endpoint: &str, secret: Option<&str>) -> Result<Health, Connection> {
    let (status, body) = get_health(endpoint, "/v1/rewrite/health", secret).map_err(|_| Connection::Unreachable)?;
    match status {
        200 => serde_json::from_slice(&body).map_err(|_| Connection::ServiceUnavailable),
        401 | 403 => Err(Connection::AuthenticationFailed),
        _ => Err(Connection::ServiceUnavailable),
    }
}

/// `settings.analysisStatus`, on the same endpoint and credential.
pub fn analysis_status(endpoint: &str, secret: Option<&str>) -> &'static str {
    analysis_status_line(get_health(endpoint, "/v1/analysis/health", secret))
}
fn analysis_status_line(result: Result<(u16, Vec<u8>), ()>) -> &'static str {
    match result {
        Ok((200, body)) => match serde_json::from_slice::<Health>(&body) {
            Ok(h) if h.service == "localflow-analysis" => match h.backend.and_then(|b| b.model).filter(|m| !m.is_empty()) {
                Some(_) => "__model__",
                None => "Meeting analysis: available.",
            },
            Ok(_) => "This server does not offer meeting analysis.",
            Err(_) => "Meeting analysis could not be checked.",
        },
        Ok((404, _)) => "This server does not offer meeting analysis.",
        _ => "Meeting analysis could not be checked.",
    }
}
/// The status line, with the model when the server names one.
pub fn analysis_status_text(endpoint: &str, secret: Option<&str>) -> String {
    let result = get_health(endpoint, "/v1/analysis/health", secret);
    let model = result.as_ref().ok().and_then(|(s, b)| (*s == 200).then(|| serde_json::from_slice::<Health>(b).ok()).flatten()).and_then(|h| h.backend).and_then(|b| b.model);
    match (analysis_status_line(result), model) {
        ("__model__", Some(m)) => format!("Meeting analysis: available (model {m})."),
        (line, _) => line.to_string(),
    }
}

/// `X-LocalFlow-Primary-*` for a Remote summaries server. `primary_only` on the custom path.
pub fn summary_headers(p: &Prefs, key: Option<&str>, primary_only: bool) -> Vec<(&'static str, String)> {
    let url = p.string("summaryServerURL").unwrap_or_default();
    let model = p.string("summaryServerModel").unwrap_or_default();
    if summary_server(p) != "remote" || url.trim().is_empty() || model.trim().is_empty() {
        return vec![];
    }
    let mut out = vec![("X-LocalFlow-Primary-URL", url.trim().to_string()), ("X-LocalFlow-Primary-Model", model.trim().to_string())];
    if let Some(key) = key {
        out.push(("X-LocalFlow-Primary-Key", key.to_string()));
    }
    if primary_only {
        out.push(("X-LocalFlow-Primary-Only", "1".to_string()));
    }
    out
}

// MARK: Error copy

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Failure {
    AccessibilityRequired,
    InputMonitoringDenied,
    InvalidBinding,
    Conflict,
    ShortcutUnavailable,
    Busy,
    ModelUnavailable,
    Cancelled,
    ServerOnly,
    /// Anything else: a type and a code, never a description.
    Other(String, i64),
}
pub fn describe(f: &Failure) -> String {
    match f {
        Failure::AccessibilityRequired => "Allow Accessibility to record and prioritize shortcuts.".into(),
        Failure::InputMonitoringDenied => "Allow Input Monitoring to use the dictation shortcut.".into(),
        Failure::InvalidBinding => "That shortcut is unavailable. Try another key combination.".into(),
        Failure::Conflict => "That shortcut is already registered. Try another combination.".into(),
        Failure::ShortcutUnavailable => "The keyboard shortcut could not start. Check permissions and try again.".into(),
        Failure::Busy => "Another dictation or model operation is still running. Wait for it to finish.".into(),
        Failure::ModelUnavailable => "The speech model is unavailable. Verify the local model in Settings.".into(),
        Failure::Cancelled => "The operation was cancelled.".into(),
        Failure::ServerOnly => "Server only is on, but this Mac can't use your server. Check Settings › Server.".into(),
        Failure::Other(ty, code) => format!("Error type {ty}, code {code}."),
    }
}

// MARK: Snapshot

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Permission {
    #[default]
    Unknown,
    Denied,
    Granted,
}
impl Permission {
    pub fn label(self) -> &'static str {
        match self {
            Permission::Unknown => "Not determined",
            Permission::Denied => "Not allowed",
            Permission::Granted => "Allowed",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Runtime {
    #[default]
    Unloaded,
    Preparing,
    Releasing,
    Ready,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Alternate {
    pub choice: &'static str,
    pub installed: bool,
    pub installing: bool,
    pub completed: u64,
    pub total: u64,
    pub bytes: u64,
}
impl Alternate {
    pub fn name(&self) -> &'static str {
        speech_name(self.choice)
    }
    pub fn role(&self) -> &'static str {
        if self.choice == "parakeet-ultra" { "Default for new setups" } else { "Alternative dictation model" }
    }
    pub fn readiness(&self) -> String {
        if self.installing {
            "Downloading…".into()
        } else if self.installed {
            "Installed".into()
        } else {
            format!("Not installed · {}", byte_count(self.bytes))
        }
    }
}

/// `SpeechModelChoice.downloadBytes`: the sum of the file sizes in `Resources/Models/<choice>.json`.
pub fn speech_download_bytes(choice: &str) -> u64 {
    if choice == "parakeet-ultra" { 632_162_964 } else { 483_105_645 }
}
pub fn other_speech_model(choice: &str) -> &'static str {
    if choice == "parakeet-ultra" { "parakeet-v3" } else { "parakeet-ultra" }
}
impl Alternate {
    pub fn not_installed(choice: &'static str) -> Self {
        Alternate { choice, installed: false, installing: false, completed: 0, total: 0, bytes: speech_download_bytes(choice) }
    }
}
pub fn speech_name(choice: &str) -> &'static str {
    if choice == "parakeet-ultra" { "Parakeet Ultra" } else { "Parakeet v3" }
}
pub fn speech_attribution(choice: &str) -> &'static str {
    if choice == "parakeet-ultra" {
        "Moondream parakeet-ultra (post-trained from NVIDIA parakeet-tdt-0.6b-v3), Core ML conversion by FluidInference. License: CC BY 4.0."
    } else {
        "NVIDIA parakeet-tdt-0.6b-v3, Core ML conversion by FluidInference. License: CC BY 4.0."
    }
}
/// `ByteCountFormatter` with `.file`: decimal units, up to two fractional digits for GB.
pub fn byte_count(bytes: u64) -> String {
    super::onboarding::bytes(bytes as i64)
}

/// `SettingsViewModel.Snapshot`: the model and permission state the page draws. Everything here
/// comes from a Mac service the rewrite doesn't have yet, so it reads as nothing installed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Snapshot {
    pub model_installed: bool,
    pub speech_model: &'static str,
    pub model_install_error: Option<String>,
    pub alternate: Option<Alternate>,
    pub keep_model_ready: bool,
    pub meeting_installed: bool,
    pub meeting_installing: bool,
    pub speaker_installed: bool,
    pub speaker_installing: bool,
    pub boost_installed: bool,
    pub boost_installing: bool,
    pub runtime: Runtime,
    pub controls_available: bool,
    pub leased: bool,
    pub installing: bool,
    pub verifying: bool,
    pub completed: u64,
    pub total: u64,
    pub download_bytes: Option<u64>,
    pub microphone: Permission,
    pub input_monitoring: Permission,
    pub accessibility: Permission,
    pub system_audio: Permission,
    pub shortcut: Shortcut,
    pub shortcut_ready: bool,
    pub storage_available: bool,
    pub busy: bool,
    pub status: String,
}
impl Default for Snapshot {
    fn default() -> Self {
        Snapshot {
            model_installed: false,
            speech_model: "parakeet-ultra",
            model_install_error: None,
            alternate: None,
            keep_model_ready: false,
            meeting_installed: false,
            meeting_installing: false,
            speaker_installed: false,
            speaker_installing: false,
            boost_installed: false,
            boost_installing: false,
            runtime: Runtime::Unloaded,
            controls_available: true,
            leased: false,
            installing: false,
            verifying: false,
            completed: 0,
            total: 0,
            download_bytes: None,
            microphone: Permission::Unknown,
            input_monitoring: Permission::Unknown,
            accessibility: Permission::Unknown,
            system_audio: Permission::Unknown,
            shortcut: Shortcut::default(),
            shortcut_ready: false,
            storage_available: false,
            busy: false,
            status: "Checking local prerequisites…".into(),
        }
    }
}
impl Snapshot {
    pub fn loaded(&self) -> bool {
        self.runtime == Runtime::Ready
    }
    pub fn model_readiness(&self) -> &'static str {
        if !self.model_installed {
            return "Not installed";
        }
        match self.runtime {
            Runtime::Preparing => "Preparing…",
            Runtime::Releasing => "Unloading…",
            Runtime::Ready => "Ready",
            Runtime::Unloaded => "Unloaded",
        }
    }
    pub fn meeting_readiness(&self) -> &'static str {
        if self.meeting_installing {
            "Installing…"
        } else if self.meeting_installed {
            "Ready"
        } else {
            "Not installed · 1.63 GB"
        }
    }
    pub fn speaker_readiness(&self) -> &'static str {
        if self.speaker_installing {
            "Installing…"
        } else if self.speaker_installed {
            "Ready"
        } else {
            "Not installed"
        }
    }
    pub fn boost_readiness(&self) -> &'static str {
        if self.boost_installing {
            "Installing…"
        } else if self.boost_installed {
            "Ready"
        } else {
            "Not installed · 103 MB"
        }
    }
    pub fn has_missing_permissions(&self) -> bool {
        [self.microphone, self.input_monitoring, self.accessibility].iter().any(|p| *p != Permission::Granted)
    }
    pub fn meeting_blocked_reason(&self) -> Option<&'static str> {
        if self.microphone != Permission::Granted {
            return Some("Allow Microphone access to record.");
        }
        (!self.storage_available).then_some("Local storage is not ready. Check Settings before recording.")
    }
    pub fn test_blocked_reason(&self) -> Option<String> {
        if !self.model_installed {
            return Some(self.model_install_error.clone().unwrap_or_else(|| "Finish downloading speech recognition first.".into()));
        }
        let reason = if self.microphone != Permission::Granted {
            "Allow Microphone access to record."
        } else if self.input_monitoring != Permission::Granted {
            "Allow Input Monitoring to use the shortcut."
        } else if !self.shortcut.enabled {
            "Enable a dictation shortcut."
        } else if !self.shortcut_ready {
            if self.shortcut.kind == "key_combination" && self.accessibility != Permission::Granted {
                "Allow Accessibility for this shortcut, or choose a modifier key."
            } else {
                "Starting the dictation shortcut…"
            }
        } else if self.installing || !self.controls_available {
            "Wait for the model operation to finish."
        } else if self.busy {
            "Wait for the current dictation to finish."
        } else if !self.storage_available {
            "Local storage is not ready. Check Settings before recording."
        } else {
            return None;
        };
        Some(reason.into())
    }
}

// MARK: Shortcut

const CMD: u32 = 1 << 8;
const SHIFT: u32 = 1 << 9;
const OPTION: u32 = 1 << 11;
const CONTROL: u32 = 1 << 12;
pub const FN: u32 = 1 << 23;
const SIDES: [(u64, u32, &str); 8] = [
    (0x1, CONTROL, "Left Control"),
    (0x2000, CONTROL, "Right Control"),
    (0x20, OPTION, "Left Option"),
    (0x40, OPTION, "Right Option"),
    (0x2, SHIFT, "Left Shift"),
    (0x4, SHIFT, "Right Shift"),
    (0x8, CMD, "Left Command"),
    (0x10, CMD, "Right Command"),
];
const DEVICE_MASK: u64 = 0x1 | 0x2000 | 0x20 | 0x40 | 0x2 | 0x4 | 0x8 | 0x10;
const FUNCTION_KEYS: [u32; 20] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90];
const NAV_KEYS: [u32; 10] = [114, 115, 116, 117, 119, 121, 123, 124, 125, 126];

/// `ShortcutPreference`, the JSON Swift stores under `shortcut`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Shortcut {
    pub version: u32,
    pub kind: String,
    pub enabled: bool,
    pub key_code: u32,
    pub modifiers: u32,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub device_modifiers: Option<u64>,
}
impl Default for Shortcut {
    fn default() -> Self {
        Shortcut { version: 1, kind: "fn_globe".into(), enabled: true, key_code: 49, modifiers: CONTROL | OPTION, device_modifiers: None }
    }
}

impl Shortcut {
    /// The shape `Services::install_shortcut` takes.
    pub fn json(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }
    pub fn right_control() -> Self {
        Shortcut { kind: "modifier_only".into(), modifiers: CONTROL, device_modifiers: Some(0x2000), ..Default::default() }
    }
    pub fn load(p: &Prefs) -> Self {
        p.get::<Shortcut>("shortcut").filter(Shortcut::is_valid).unwrap_or_default()
    }
    pub fn is_saved(p: &Prefs) -> bool {
        p.contains("shortcut")
    }
    pub fn save(&self, p: &mut Prefs) {
        if self.is_valid() {
            p.set("shortcut", self);
        }
    }
    pub fn is_valid(&self) -> bool {
        if let Some(d) = self.device_modifiers {
            let sides_ok = SIDES.iter().all(|(mask, modifier, _)| d & mask == 0 || self.modifiers & modifier != 0);
            if d == 0 || d & !DEVICE_MASK != 0 || self.kind == "fn_globe" || !sides_ok {
                return false;
            }
        }
        if self.version != 1 || self.modifiers & !(CMD | CONTROL | OPTION | SHIFT | FN) != 0 {
            return false;
        }
        match self.kind.as_str() {
            "fn_globe" => true,
            "modifier_only" => self.modifiers != 0,
            "key_combination" => self.key_code < 128 && !(54..=63).contains(&self.key_code) && !(self.key_code == 53 && self.modifiers == 0),
            _ => false,
        }
    }
    pub fn includes_shift(&self) -> bool {
        self.modifiers & SHIFT != 0 || self.device_modifiers.unwrap_or(0) & 0x6 != 0
    }
    pub fn title(&self) -> String {
        if !self.enabled {
            return "Disabled".into();
        }
        if self.kind == "fn_globe" {
            return "fn / Globe".into();
        }
        let mut parts: Vec<String> = vec![];
        for (modifier, symbol) in [(CONTROL, "⌃"), (OPTION, "⌥"), (SHIFT, "⇧"), (CMD, "⌘")] {
            if self.modifiers & modifier == 0 {
                continue;
            }
            let names: Vec<String> = SIDES.iter().filter(|s| s.1 == modifier && self.device_modifiers.unwrap_or(0) & s.0 != 0).map(|s| s.2.to_string()).collect();
            if names.is_empty() {
                parts.push(symbol.into());
            } else {
                parts.extend(names);
            }
        }
        if self.modifiers & FN != 0 {
            parts.push("fn".into());
        }
        if self.kind == "key_combination" {
            parts.push(key_title(self.key_code));
        }
        parts.join(" ")
    }
}

/// Fixed key names. Others come from the keyboard layout in Swift (`UCKeyTranslate`).
/// ponytail: no layout lookup, so a letter key reads "Key <code>", Swift's own fallback.
pub fn key_title(code: u32) -> String {
    let special = match code {
        36 => "Return",
        48 => "Tab",
        49 => "Space",
        51 => "⌫",
        53 => "Esc",
        65 => ".",
        67 => "*",
        69 => "+",
        71 => "Clear",
        75 => "/",
        76 => "Enter",
        78 => "−",
        81 => "=",
        82 => "0",
        83 => "1",
        84 => "2",
        85 => "3",
        86 => "4",
        87 => "5",
        88 => "6",
        89 => "7",
        91 => "8",
        92 => "9",
        114 => "Help",
        115 => "Home",
        116 => "Page Up",
        117 => "⌦",
        119 => "End",
        121 => "Page Down",
        123 => "←",
        124 => "→",
        125 => "↓",
        126 => "↑",
        _ => "",
    };
    if !special.is_empty() {
        return special.into();
    }
    match FUNCTION_KEYS.iter().position(|c| *c == code) {
        Some(i) => format!("F{}", i + 1),
        None => format!("Key {code}"),
    }
}

/// The CGEvent flag bits this rule reads: command, control, alternate, shift, secondary fn.
pub const FLAG_SHIFT: u64 = 0x20000;
pub const FLAG_CONTROL: u64 = 0x40000;
pub const FLAG_OPTION: u64 = 0x80000;
pub const FLAG_COMMAND: u64 = 0x100000;
pub const FLAG_FN: u64 = 0x800000;

/// `modifiers(from:keyCode:)`: the secondary Fn flag on function and navigation keys is implicit.
pub fn modifiers_from(flags: u64, key_code: Option<u32>) -> u32 {
    let mut v = 0;
    for (flag, m) in [(FLAG_COMMAND, CMD), (FLAG_CONTROL, CONTROL), (FLAG_OPTION, OPTION), (FLAG_SHIFT, SHIFT)] {
        if flags & flag != 0 {
            v |= m;
        }
    }
    let implicit = key_code.is_some_and(|c| FUNCTION_KEYS.contains(&c) || NAV_KEYS.contains(&c));
    if flags & FLAG_FN != 0 && !implicit {
        v |= FN;
    }
    v
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyEvent {
    Down,
    Up,
    Flags,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Capture {
    Pending,
    Cancelled,
    Captured(Shortcut),
}

/// One chord only; commits after key and modifiers release.
#[derive(Default)]
pub struct CaptureState {
    candidate: Option<Shortcut>,
    key_released: bool,
    finished: bool,
}
impl CaptureState {
    pub fn receive(&mut self, event: KeyEvent, key_code: u32, flags: u64) -> Capture {
        if self.finished {
            return Capture::Pending;
        }
        let modifiers = modifiers_from(flags, (event != KeyEvent::Flags).then_some(key_code));
        if event == KeyEvent::Down && key_code == 53 {
            self.finished = true;
            return Capture::Cancelled;
        }
        let physical = Some(flags & DEVICE_MASK).filter(|v| *v != 0);
        let is_combo = self.candidate.as_ref().is_some_and(|c| c.kind == "key_combination");
        if event == KeyEvent::Down && !is_combo {
            self.candidate = Some(Shortcut { kind: "key_combination".into(), key_code, modifiers, device_modifiers: physical, ..Default::default() });
        } else if event == KeyEvent::Flags && !is_combo && modifiers != 0 {
            let mut v = self.candidate.take().unwrap_or(Shortcut { kind: "modifier_only".into(), modifiers: 0, ..Default::default() });
            v.modifiers |= modifiers;
            if let Some(ph) = physical {
                v.device_modifiers = Some(v.device_modifiers.unwrap_or(0) | ph);
            }
            self.candidate = Some(v);
        } else if event == KeyEvent::Up && self.candidate.as_ref().is_some_and(|c| c.key_code == key_code) {
            self.key_released = true;
        }
        let Some(mut value) = self.candidate.clone() else { return Capture::Pending };
        if modifiers != 0 || !(value.kind == "modifier_only" || self.key_released) {
            return Capture::Pending;
        }
        if value.kind == "modifier_only" && value.modifiers == FN {
            value.kind = "fn_globe".into();
        }
        if !value.is_valid() {
            return Capture::Pending;
        }
        self.finished = true;
        Capture::Captured(value)
    }
}

// MARK: App context

pub const DEFAULT_EXCLUSIONS: [&str; 9] = [
    "com.apple.Passwords",
    "com.apple.keychainaccess",
    "com.1password.1password",
    "com.agilebits.onepassword7",
    "com.bitwarden.desktop",
    "com.lastpass.LastPass",
    "org.keepassxc.keepassxc",
    "com.dashlane.dashlanephonefinal",
    "com.moneymoney-app.retail",
];
pub const KINDS: [(&str, &str); 7] = [("email", "Email"), ("work_chat", "Work chat"), ("personal_chat", "Personal chat"), ("code", "Code"), ("terminal", "Terminal"), ("document", "Document"), ("other", "Other")];
pub fn kind_title(raw: &str) -> &'static str {
    KINDS.iter().find(|k| k.0 == raw).map_or("Other", |k| k.1)
}
const BUILT_IN: [(&str, &str); 32] = [
    ("com.apple.mail", "email"),
    ("com.microsoft.Outlook", "email"),
    ("com.readdle.SparkDesktop", "email"),
    ("com.readdle.smartemail-Mac", "email"),
    ("com.superhuman.electron", "email"),
    ("com.tinyspeck.slackmacgap", "work_chat"),
    ("com.microsoft.teams", "work_chat"),
    ("com.microsoft.teams2", "work_chat"),
    ("com.apple.MobileSMS", "personal_chat"),
    ("net.whatsapp.WhatsApp", "personal_chat"),
    ("desktop.WhatsApp", "personal_chat"),
    ("ru.keepcoder.Telegram", "personal_chat"),
    ("org.telegram.desktop", "personal_chat"),
    ("org.whispersystems.signal-desktop", "personal_chat"),
    ("com.hnc.Discord", "personal_chat"),
    ("com.apple.dt.Xcode", "code"),
    ("com.microsoft.VSCode", "code"),
    ("com.todesktop.230313mzl4w4u92", "code"),
    ("dev.zed.Zed", "code"),
    ("com.apple.Terminal", "terminal"),
    ("com.googlecode.iterm2", "terminal"),
    ("com.mitchellh.ghostty", "terminal"),
    ("com.cmuxterm.app", "terminal"),
    ("dev.warp.Warp-Stable", "terminal"),
    ("org.alacritty", "terminal"),
    ("net.kovidgoyal.kitty", "terminal"),
    ("com.github.wez.wezterm", "terminal"),
    ("com.apple.Notes", "document"),
    ("com.apple.iWork.Pages", "document"),
    ("com.microsoft.Word", "document"),
    ("md.obsidian", "document"),
    ("notion.id", "document"),
];
/// Override, then the built-in map, then JetBrains by prefix, else other.
pub fn effective_kind(p: &Prefs, id: &str) -> &'static str {
    if let Some(k) = overrides(p).get(id) {
        return KINDS.iter().find(|x| x.0 == k).map_or("other", |x| x.0);
    }
    if let Some(k) = BUILT_IN.iter().find(|b| b.0 == id) {
        return k.1;
    }
    if id.starts_with("com.jetbrains.") { "code" } else { "other" }
}
pub fn is_valid_bundle_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 255 && !id.chars().any(char::is_whitespace)
}
/// Sorted; defaults on a fresh install; invalid dropped; capped at 200 including our own ID.
pub fn exclusions(p: &Prefs) -> Vec<String> {
    let stored = p.get::<Vec<String>>("contextExcludedBundleIDs").unwrap_or_else(|| DEFAULT_EXCLUSIONS.iter().map(|s| s.to_string()).collect());
    let mut set: BTreeSet<String> = stored.into_iter().filter(|i| is_valid_bundle_id(i) && i != BUNDLE_ID).take(MAX_CONTEXT_RULES - 1).collect();
    set.insert(BUNDLE_ID.into());
    set.into_iter().collect()
}
/// Trimmed, valid, under the limit. An existing one succeeds.
pub fn add_exclusion(p: &mut Prefs, raw: &str) -> bool {
    let id = raw.trim();
    let mut all = exclusions(p);
    if !is_valid_bundle_id(id) {
        return false;
    }
    if all.iter().any(|x| x == id) {
        return true;
    }
    if all.len() >= MAX_CONTEXT_RULES {
        return false;
    }
    all.push(id.into());
    all.sort();
    p.set("contextExcludedBundleIDs", all);
    true
}
/// Refuses our own bundle ID.
pub fn remove_exclusion(p: &mut Prefs, id: &str) {
    if id == BUNDLE_ID {
        return;
    }
    let all: Vec<String> = exclusions(p).into_iter().filter(|x| x != id).collect();
    p.set("contextExcludedBundleIDs", all);
}
pub fn overrides(p: &Prefs) -> BTreeMap<String, String> {
    p.get::<BTreeMap<String, String>>("contextCategoryOverrides").unwrap_or_default().into_iter().filter(|(_, v)| KINDS.iter().any(|k| k.0 == v)).take(MAX_CONTEXT_RULES).collect()
}
pub fn set_kind(p: &mut Prefs, raw: &str, kind: Option<&str>) -> bool {
    let id = raw.trim();
    if !is_valid_bundle_id(id) {
        return false;
    }
    let mut all = overrides(p);
    match kind {
        None => {
            all.remove(id);
        }
        Some(k) => {
            if !all.contains_key(id) && all.len() >= MAX_CONTEXT_RULES {
                return false;
            }
            all.insert(id.into(), k.into());
        }
    }
    p.set("contextCategoryOverrides", all);
    true
}
pub fn app_count(n: usize) -> String {
    if n == 1 { "1 app".into() } else { format!("{n} apps") }
}
/// `localizedStandardCompare`: case-insensitive with digit runs compared as numbers.
pub fn natural_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    let (mut x, mut y) = (a.chars().peekable(), b.chars().peekable());
    loop {
        match (x.peek().copied(), y.peek().copied()) {
            (None, None) => return std::cmp::Ordering::Equal,
            (None, _) => return std::cmp::Ordering::Less,
            (_, None) => return std::cmp::Ordering::Greater,
            (Some(c), Some(d)) if c.is_ascii_digit() && d.is_ascii_digit() => {
                let read = |it: &mut std::iter::Peekable<std::str::Chars>| {
                    let mut n = 0u128;
                    while let Some(v) = it.peek().and_then(|c| c.to_digit(10)) {
                        n = n.saturating_mul(10).saturating_add(v as u128);
                        it.next();
                    }
                    n
                };
                let (l, r) = (read(&mut x), read(&mut y));
                if l != r {
                    return l.cmp(&r);
                }
            }
            (Some(c), Some(d)) => {
                let (l, r) = (c.to_lowercase().next(), d.to_lowercase().next());
                if l != r {
                    return l.cmp(&r);
                }
                x.next();
                y.next();
            }
        }
    }
}

// MARK: Microphones

/// `RankedInputEntry` as Swift stores it. Dates are its numeric seconds since 2001.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InputEntry {
    pub id: String,
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub uid: Option<String>,
    #[serde(rename = "modelUID", default, skip_serializing_if = "Option::is_none")]
    pub model_uid: Option<String>,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_seen_at: Option<f64>,
}
impl InputEntry {
    pub fn system_default() -> Self {
        InputEntry { id: "00000000-0000-0000-0000-000000000000".into(), kind: "systemDefault".into(), uid: None, model_uid: None, name: "System default".into(), last_seen_at: None }
    }
    pub fn is_system_default(&self) -> bool {
        self.kind == "systemDefault"
    }
    fn is_valid(&self) -> bool {
        let name = self.name.trim();
        let uid_ok = self.is_system_default() == self.uid.is_none() && self.uid.as_ref().is_none_or(|u| valid_uid(u));
        !name.is_empty() && name.chars().count() <= 128 && uid_ok
    }
}
fn valid_uid(uid: &str) -> bool {
    (1..=256).contains(&uid.len())
}
pub fn kind_label(kind: &str) -> &'static str {
    match kind {
        "builtIn" => "Built-in",
        "usb" => "USB",
        "bluetooth" => "Bluetooth",
        "iPhone" => "iPhone",
        "virtual" => "Virtual",
        "systemDefault" => "System default",
        _ => "Other",
    }
}

#[derive(Clone, Debug, PartialEq, Default)]
pub struct ConnectedInput {
    pub device_id: u32,
    pub uid: String,
    pub model_uid: Option<String>,
    pub name: String,
    pub kind: String,
    pub alive: bool,
}
#[derive(Clone, Debug, PartialEq, Default)]
pub struct InputSnapshot {
    pub inputs: Vec<ConnectedInput>,
    pub default_input: Option<u32>,
    pub clamshell: bool,
}

#[derive(Serialize, Deserialize)]
struct StoredInputs {
    version: u32,
    entries: Vec<InputEntry>,
}
pub const INPUTS_KEY: &str = "inputDevices.priority.v1";
pub const INPUT_CAPACITY: usize = 32;

/// V1, V2 and the field rules; keeps one System default and at most 32.
pub fn validated_inputs(entries: Vec<InputEntry>) -> Vec<InputEntry> {
    let mut seen = BTreeSet::new();
    let mut has_default = false;
    let mut out = vec![];
    for e in entries.into_iter().filter(InputEntry::is_valid) {
        if e.is_system_default() {
            if has_default {
                continue;
            }
            has_default = true;
        } else if let Some(u) = &e.uid {
            if !seen.insert(u.clone()) {
                continue;
            }
        }
        out.push(e);
    }
    if !has_default {
        out.push(InputEntry::system_default());
    }
    while out.len() > INPUT_CAPACITY {
        let Some(i) = out.iter().rposition(|e| !e.is_system_default()) else { break };
        out.remove(i);
    }
    out
}
/// Missing or unreadable data reads as a single System default; only the next edit overwrites it.
pub fn load_inputs(p: &Prefs) -> Vec<InputEntry> {
    match p.get::<StoredInputs>(INPUTS_KEY) {
        Some(s) if s.version == 1 => validated_inputs(s.entries),
        _ => vec![InputEntry::system_default()],
    }
}
pub fn save_inputs(p: &mut Prefs, entries: Vec<InputEntry>) {
    p.set(INPUTS_KEY, StoredInputs { version: 1, entries: validated_inputs(entries) });
}
/// Rules M1 to M3: for each entry, the input it matched.
pub fn match_inputs(entries: &[InputEntry], inputs: &[ConnectedInput]) -> Vec<Option<usize>> {
    let mut result = vec![None; entries.len()];
    let mut taken = BTreeSet::new();
    for (i, e) in entries.iter().enumerate() {
        let Some(uid) = &e.uid else { continue };
        if let Some(m) = inputs.iter().position(|x| &x.uid == uid) {
            if taken.insert(m) {
                result[i] = Some(m);
            }
        }
    }
    let key = |kind: &str, name: &str, model: &Option<String>| (kind.to_string(), name.to_string(), model.clone());
    for (i, e) in entries.iter().enumerate() {
        if result[i].is_some() || e.is_system_default() {
            continue;
        }
        let k = key(&e.kind, &e.name, &e.model_uid);
        let same_entries = entries.iter().enumerate().filter(|(j, o)| result[*j].is_none() && !o.is_system_default() && key(&o.kind, &o.name, &o.model_uid) == k).count();
        let free: Vec<usize> = inputs.iter().enumerate().filter(|(j, x)| !taken.contains(j) && key(&x.kind, &x.name, &x.model_uid) == k).map(|(j, _)| j).collect();
        if same_entries == 1 && free.len() == 1 {
            result[i] = Some(free[0]);
        }
    }
    result
}
/// Matched entries take the device's current name, UID and last-seen time.
pub fn reconcile_inputs(entries: &[InputEntry], snapshot: &InputSnapshot, now: f64) -> Vec<InputEntry> {
    let matches = match_inputs(entries, &snapshot.inputs);
    let mut out = entries.to_vec();
    for (i, m) in matches.iter().enumerate() {
        let Some(m) = m else { continue };
        let input = &snapshot.inputs[*m];
        if !valid_uid(&input.uid) {
            continue;
        }
        let name = input.name.trim();
        if !name.is_empty() && name.chars().count() <= 128 {
            out[i].name = name.to_string();
        }
        out[i].uid = Some(input.uid.clone());
        out[i].last_seen_at = Some(now);
    }
    out
}
/// `lastSeenAt` alone is worth saving once a minute.
pub fn inputs_meaningfully_changed(old: &[InputEntry], new: &[InputEntry]) -> bool {
    old.len() != new.len()
        || old.iter().zip(new).any(|(a, b)| {
            a.name != b.name
                || a.uid != b.uid
                || match (a.last_seen_at, b.last_seen_at) {
                    (None, None) => false,
                    (Some(x), Some(y)) => (y - x).abs() >= 60.,
                    _ => true,
                }
        })
}
pub fn add_input(entries: &[InputEntry], input: &ConnectedInput, new_id: String, now: f64) -> Result<Vec<InputEntry>, &'static str> {
    if entries.len() >= INPUT_CAPACITY {
        return Err("full");
    }
    if entries.iter().any(|e| e.uid.as_deref() == Some(input.uid.as_str())) {
        return Err("duplicate");
    }
    let entry = InputEntry { id: new_id, kind: input.kind.clone(), uid: Some(input.uid.clone()), model_uid: input.model_uid.clone(), name: input.name.trim().to_string(), last_seen_at: Some(now) };
    if !entry.is_valid() {
        return Err("invalid");
    }
    let mut out = entries.to_vec();
    let at = out.iter().position(InputEntry::is_system_default).unwrap_or(out.len());
    out.insert(at, entry);
    Ok(out)
}
/// Drag and drop: the dragged row takes the target's place.
pub fn move_input(entries: &[InputEntry], id: &str, target: &str) -> Vec<InputEntry> {
    let (Some(from), Some(to)) = (entries.iter().position(|e| e.id == id), entries.iter().position(|e| e.id == target)) else { return entries.to_vec() };
    if from == to {
        return entries.to_vec();
    }
    let mut out = entries.to_vec();
    let e = out.remove(from);
    out.insert(to, e);
    out
}

#[derive(Clone, Debug, PartialEq)]
pub struct MicRow {
    pub id: String,
    pub name: String,
    pub suffix: Option<String>,
    pub kind_label: &'static str,
    pub is_default: bool,
    pub available: bool,
    pub secondary: Option<String>,
    pub note: Option<&'static str>,
    pub rank: usize,
    pub count: usize,
}
impl MicRow {
    pub fn title(&self) -> String {
        format!("{}{}", self.name, self.suffix.as_ref().map(|s| format!(" {s}")).unwrap_or_default())
    }
    pub fn detail(&self) -> String {
        if self.is_default {
            return self.secondary.clone().unwrap_or_default();
        }
        let mut parts = vec![self.kind_label.to_string()];
        parts.extend(self.secondary.clone());
        parts.extend(self.note.map(String::from));
        parts.join(" · ")
    }
    pub fn a11y_label(&self) -> String {
        let mut parts = vec![self.title()];
        parts.push(if self.is_default { self.secondary.clone().unwrap_or_else(|| self.kind_label.to_string()) } else { self.kind_label.to_string() });
        parts.push(format!("{} of {}", self.rank, self.count));
        if !self.is_default && !self.available {
            parts.push("not connected".into());
        }
        parts.join(", ")
    }
}
#[derive(Clone, Debug, PartialEq, Default)]
pub struct MicList {
    pub rows: Vec<MicRow>,
    pub add: Vec<ConnectedInput>,
    pub add_disabled: Option<&'static str>,
}
pub fn mic_list(entries: &[InputEntry], s: &InputSnapshot) -> MicList {
    let matches = match_inputs(entries, &s.inputs);
    let default_name = s.default_input.and_then(|d| s.inputs.iter().find(|i| i.device_id == d)).map(|i| i.name.clone());
    let count_of = |n: &str| entries.iter().filter(|e| e.name == n).count();
    let rows = entries
        .iter()
        .enumerate()
        .map(|(i, e)| {
            let available = if e.is_system_default() {
                s.default_input.is_some()
            } else {
                matches[i].is_some_and(|m| s.inputs[m].alive && !(s.inputs[m].kind == "builtIn" && s.clamshell))
            };
            let secondary = if e.is_system_default() {
                Some(format!("Currently: {}", default_name.as_deref().unwrap_or("none")))
            } else {
                (!available).then(|| "Not connected".to_string())
            };
            let suffix = (!e.is_system_default() && count_of(&e.name) > 1).then(|| e.uid.as_ref().map(|u| format!("· {}", &u[u.len().saturating_sub(4)..]))).flatten();
            MicRow {
                id: e.id.clone(),
                name: e.name.clone(),
                suffix,
                kind_label: kind_label(&e.kind),
                is_default: e.is_system_default(),
                available,
                secondary,
                note: (e.kind == "bluetooth").then_some("Uses call-quality audio and lowers playback quality while recording."),
                rank: i + 1,
                count: entries.len(),
            }
        })
        .collect();
    let matched: BTreeSet<usize> = matches.iter().flatten().copied().collect();
    let add: Vec<ConnectedInput> = s.inputs.iter().enumerate().filter(|(i, x)| !matched.contains(i) && x.alive && !entries.iter().any(|e| e.uid.as_deref() == Some(x.uid.as_str()))).map(|(_, x)| x.clone()).collect();
    let add_disabled = if entries.len() >= INPUT_CAPACITY {
        Some("The list is full")
    } else if add.is_empty() {
        Some("All connected microphones are listed")
    } else {
        None
    };
    MicList { rows, add, add_disabled }
}

// MARK: Known speakers (model only; Swift has no view)

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KnownSpeaker {
    pub id: String,
    pub name: String,
    pub active_samples: i64,
    pub recognition: bool,
    pub revision: i64,
}
impl KnownSpeaker {
    pub fn needs_reenrollment(&self) -> bool {
        self.active_samples == 0
    }
    pub fn sample_count_text(&self) -> String {
        if self.active_samples == 1 { "1 voice sample".into() } else { format!("{} voice samples", self.active_samples) }
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VoiceSample {
    pub id: String,
    pub source_title: Option<String>,
    pub provenance_unavailable: bool,
    pub source_date: i64,
    pub speech_ms: i64,
    pub quality: String,
}
impl VoiceSample {
    pub fn source_text(&self, day: &str, fallback_title: &str) -> String {
        if self.provenance_unavailable {
            return format!("Source meeting deleted · {day}");
        }
        format!("{} · {day}", self.source_title.as_deref().unwrap_or(fallback_title))
    }
    pub fn duration_text(&self) -> String {
        format!("{} s", (self.speech_ms + 500) / 1000)
    }
    pub fn quality_text(&self) -> &'static str {
        if self.quality == "good" { "Good" } else { "Fair" }
    }
}
pub fn delete_confirmation(name: &str) -> String {
    format!("Delete {name}? Voice samples are removed and future meetings will no longer recognize this voice. Past meetings keep the name.")
}
/// Rename rules: `Ok(None)` is blank.
pub fn validate_speaker_name(raw: &str) -> Result<Option<String>, &'static str> {
    let name = raw.trim();
    if name.is_empty() {
        return Ok(None);
    }
    if name.chars().any(char::is_control) {
        return Err("Remove the control character.");
    }
    if name.chars().count() > 80 {
        return Err("Use 80 characters or fewer.");
    }
    Ok(Some(name.to_string()))
}
pub fn rename_error(raw: &str) -> Option<&'static str> {
    match validate_speaker_name(raw) {
        Ok(None) => Some("Enter a name."),
        Ok(Some(_)) => None,
        Err(e) => Some(e),
    }
}
#[derive(Debug, PartialEq, Eq)]
pub enum EditError {
    Stale,
    Invalid,
    Other,
}
pub fn edit_notice(e: &EditError) -> &'static str {
    match e {
        EditError::Stale => "Known speakers changed elsewhere; the list was reloaded.",
        EditError::Invalid => "That name can't be used.",
        EditError::Other => "The change could not be saved.",
    }
}
pub const LOAD_NOTICE: &str = "Known speakers could not be loaded.";
pub const SAMPLES_NOTICE: &str = "Voice samples could not be loaded.";
pub const REMOVE_SAMPLE_NOTICE: &str = "The voice sample could not be removed.";

pub fn known_speakers(db: &Db) -> rusqlite::Result<Vec<KnownSpeaker>> {
    let mut s = db.conn.prepare(
        "SELECT k.id, k.display_name, k.recognition_enabled, k.revision, (SELECT count(*) FROM voice_samples v WHERE v.known_speaker_id=k.id AND v.active=1)
         FROM known_speakers k ORDER BY k.display_name, k.created_at, k.id",
    )?;
    let rows = s.query_map([], |r| Ok(KnownSpeaker { id: r.get(0)?, name: r.get(1)?, recognition: r.get(2)?, revision: r.get(3)?, active_samples: r.get(4)? }))?;
    rows.collect()
}
fn bump(db: &Db, id: &str, expected: i64, now: i64) -> Result<(), EditError> {
    let n = db.conn.execute("UPDATE known_speakers SET revision=revision+1, updated_at=?1 WHERE id=?2 AND revision=?3", params![now, id, expected]).map_err(|_| EditError::Other)?;
    if n == 1 { Ok(()) } else { Err(EditError::Stale) }
}
fn in_tx<T>(db: &Db, f: impl FnOnce() -> Result<T, EditError>) -> Result<T, EditError> {
    db.conn.execute_batch("BEGIN IMMEDIATE").map_err(|_| EditError::Other)?;
    match f() {
        Ok(v) => {
            db.conn.execute_batch("COMMIT").map_err(|_| EditError::Other)?;
            Ok(v)
        }
        Err(e) => {
            let _ = db.conn.execute_batch("ROLLBACK");
            Err(e)
        }
    }
}
/// Copies the new name to confirmed and recognized meeting speakers, as Swift does.
pub fn rename_speaker(db: &Db, id: &str, name: &str, expected: i64, now: i64) -> Result<(), EditError> {
    let Ok(Some(name)) = validate_speaker_name(name) else { return Err(EditError::Invalid) };
    in_tx(db, || {
        bump(db, id, expected, now)?;
        db.conn.execute("UPDATE known_speakers SET display_name=?1 WHERE id=?2", params![name, id]).map_err(|_| EditError::Other)?;
        db.conn
            .execute(
                "UPDATE meeting_speakers SET display_name=?1 WHERE id IN (SELECT meeting_speaker_id FROM identity_assignments WHERE known_speaker_id=?2 AND state IN ('confirmed','recognized'))",
                params![name, id],
            )
            .map_err(|_| EditError::Other)?;
        Ok(())
    })
}
pub fn set_recognition(db: &Db, id: &str, enabled: bool, expected: i64, now: i64) -> Result<(), EditError> {
    in_tx(db, || {
        bump(db, id, expected, now)?;
        db.conn.execute("UPDATE known_speakers SET recognition_enabled=?1 WHERE id=?2", params![enabled, id]).map_err(|_| EditError::Other)?;
        Ok(())
    })
}
pub fn delete_speaker(db: &Db, id: &str, expected: i64) -> Result<(), EditError> {
    in_tx(db, || {
        let row: Option<(String, i64)> = db.conn.query_row("SELECT display_name, revision FROM known_speakers WHERE id=?1", [id], |r| Ok((r.get(0)?, r.get(1)?))).optional().map_err(|_| EditError::Other)?;
        let Some((name, revision)) = row else { return Err(EditError::Other) };
        if revision != expected {
            return Err(EditError::Stale);
        }
        let exec = |sql: &str, args: &[&dyn rusqlite::ToSql]| db.conn.execute(sql, args).map(|_| ()).map_err(|_| EditError::Other);
        exec(
            "UPDATE meeting_speakers SET display_name=?1 WHERE display_name IS NULL AND id IN (SELECT meeting_speaker_id FROM identity_assignments WHERE known_speaker_id=?2 AND state IN ('confirmed','recognized'))",
            &[&name, &id],
        )?;
        for table in ["identity_assignments", "rejected_candidates", "match_candidates", "voice_samples"] {
            exec(&format!("DELETE FROM {table} WHERE known_speaker_id=?1"), &[&id])?;
        }
        exec("UPDATE identity_assignments SET second_known_speaker_id=NULL WHERE second_known_speaker_id=?1", &[&id])?;
        exec("DELETE FROM known_speakers WHERE id=?1", &[&id])
    })
}
pub fn voice_samples(db: &Db, speaker: &str) -> rusqlite::Result<Vec<VoiceSample>> {
    let mut s = db.conn.prepare(
        "SELECT v.id, v.speech_ms, v.quality_label, v.created_at, v.source_meeting_id, m.title, m.started_at, m.created_at
         FROM voice_samples v LEFT JOIN meetings m ON m.id=v.source_meeting_id
         WHERE v.known_speaker_id=?1 AND v.active=1 ORDER BY v.created_at DESC, v.id LIMIT 64",
    )?;
    let rows = s.query_map([speaker], |r| {
        let created: i64 = r.get(3)?;
        let source: Option<String> = r.get(4)?;
        let meeting: Option<i64> = r.get::<_, Option<i64>>(6)?.or(r.get(7)?);
        Ok(VoiceSample {
            id: r.get(0)?,
            speech_ms: r.get(1)?,
            quality: r.get(2)?,
            provenance_unavailable: source.is_none(),
            source_title: if source.is_none() { None } else { r.get(5)? },
            source_date: if source.is_none() { created } else { meeting.unwrap_or(created) },
        })
    })?;
    rows.collect()
}
pub fn remove_sample(db: &Db, id: &str) -> Result<(), EditError> {
    match db.conn.execute("DELETE FROM voice_samples WHERE id=?1", [id]) {
        Ok(1) => Ok(()),
        _ => Err(EditError::Other),
    }
}

#[derive(Default)]
pub struct KnownSpeakersModel {
    pub rows: Vec<KnownSpeaker>,
    pub samples: BTreeMap<String, Vec<VoiceSample>>,
    pub expanded: Option<String>,
    pub notice: Option<String>,
    pub is_loading: bool,
    pub pending_delete: Option<KnownSpeaker>,
    pub renaming: Option<String>,
    pub rename_draft: String,
}
impl KnownSpeakersModel {
    pub fn load(&mut self, db: &Db) {
        self.is_loading = true;
        match known_speakers(db) {
            Ok(rows) => {
                self.rows = rows;
                if let Some(id) = self.expanded.clone() {
                    if let Ok(s) = voice_samples(db, &id) {
                        self.samples.insert(id, s);
                    }
                }
            }
            Err(_) => self.notice = Some(LOAD_NOTICE.into()),
        }
        self.is_loading = false;
    }
    pub fn begin_rename(&mut self, id: &str) {
        if let Some(r) = self.rows.iter().find(|r| r.id == id) {
            self.rename_draft = r.name.clone();
            self.renaming = Some(id.into());
        }
    }
    pub fn cancel_rename(&mut self) {
        self.renaming = None;
    }
    pub fn commit_rename(&mut self, db: &Db, now: i64) {
        let Some(id) = self.renaming.clone() else { return };
        let Some(row) = self.rows.iter().find(|r| r.id == id).cloned() else { return };
        let Ok(Some(name)) = validate_speaker_name(&self.rename_draft) else { return };
        self.renaming = None;
        if name != row.name {
            let r = rename_speaker(db, &id, &name, row.revision, now);
            self.apply(db, r);
        }
    }
    pub fn set_recognition(&mut self, db: &Db, id: &str, enabled: bool, now: i64) {
        let Some(row) = self.rows.iter().find(|r| r.id == id).cloned() else { return };
        let r = set_recognition(db, id, enabled, row.revision, now);
        self.apply(db, r);
    }
    pub fn request_delete(&mut self, id: &str) {
        self.pending_delete = self.rows.iter().find(|r| r.id == id).cloned();
    }
    pub fn cancel_delete(&mut self) {
        self.pending_delete = None;
    }
    pub fn confirm_delete(&mut self, db: &Db) {
        let Some(row) = self.pending_delete.take() else { return };
        let r = delete_speaker(db, &row.id, row.revision);
        self.apply(db, r);
        if self.expanded.as_deref() == Some(row.id.as_str()) {
            self.expanded = None;
        }
        self.samples.remove(&row.id);
    }
    pub fn toggle_samples(&mut self, db: &Db, id: &str) {
        if self.expanded.as_deref() == Some(id) {
            self.expanded = None;
            return;
        }
        self.expanded = Some(id.into());
        match voice_samples(db, id) {
            Ok(s) => {
                self.samples.insert(id.into(), s);
            }
            Err(_) => self.notice = Some(SAMPLES_NOTICE.into()),
        }
    }
    pub fn remove_sample(&mut self, db: &Db, sample: &str) {
        self.notice = remove_sample(db, sample).err().map(|_| REMOVE_SAMPLE_NOTICE.to_string());
        self.load(db);
    }
    fn apply(&mut self, db: &Db, r: Result<(), EditError>) {
        self.notice = r.err().map(|e| edit_notice(&e).to_string());
        self.load(db);
    }
}

/// Usage notices that exist in Swift with no view. Kept for the screen that will show them.
pub const USAGE_NOTICES: [&str; 10] = [
    "Usage sharing is off.",
    "Sharing stopped. Waiting to confirm the change with your server.",
    "Sharing is on. Some usage could not be counted.",
    "Sharing daily counts and audio duration.",
    "Usage storage is unavailable. Dictation is unaffected.",
    "Sharing stopped for this session; its setting could not be saved. Retry before quitting.",
    "Sharing stopped. Hosted removal is still pending.",
    "Usage sharing stopped because this device no longer has server approval.",
    "Usage reporting is unavailable on this server. Your dictations remain available.",
    "Usage could not be sent. It will retry while sharing is on.",
];
/// `prepareAutomaticEnrollment`: no binding enrolls, an inactive one stays off, a changed server or key wipes the days and enrolls again.
/// ponytail: the store half of enrollment. The channel that sends the reports is the usage service (SET-375).
/// The usage binding's `credentialFingerprint`: SHA-256 of the device key as lower-case hex.
pub fn usage_fingerprint(key: &[u8]) -> String {
    hex_of(&sha256(key))
}

pub fn prepare_automatic_enrollment(db: &Db, origin: &str, fingerprint: &str) -> rusqlite::Result<bool> {
    let conn = &db.conn;
    let Some((raw, enabled)) = conn
        .query_row("SELECT binding, enabled FROM usage_reporting_state WHERE id=1", [], |r| Ok((r.get::<_, Option<String>>(0)?, r.get::<_, bool>(1)?)))
        .optional()?
        .and_then(|(raw, enabled)| raw.map(|raw| (raw, enabled)))
    else {
        return Ok(true);
    };
    if !enabled {
        return Ok(false);
    }
    let old: Value = serde_json::from_str(&raw).unwrap_or_default();
    if old["origin"] == origin && old["credentialFingerprint"] == fingerprint {
        return Ok(false);
    }
    conn.execute_batch(
        "DELETE FROM usage_reporting_days; DELETE FROM usage_reporting_completions;
         UPDATE usage_reporting_state SET binding=NULL,enabled=0,pending=NULL,incomplete=0,last_report=NULL WHERE id=1",
    )?;
    Ok(true)
}

/// `SYNC` backoff: double, min 30, max 3,600 seconds.
pub fn usage_backoff(previous: u64) -> u64 {
    previous.saturating_mul(2).clamp(30, 3600)
}

#[cfg(all(test, unix))]
mod test_flowd;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::Db;

    fn approved() -> Prefs {
        let mut p = Prefs::memory();
        p.set("remote.enabled", true);
        p.set("remote.serverURL", "https://flow.example.com");
        p.set("remote.state", "approved");
        p.set("remote.consentVersion", 2);
        p
    }

    // parity: SET-090 SET-310 SET-322 SET-403
    #[test]
    fn address_and_credential_validators_match_swift() {
        assert_eq!(remote_origin(" https://Flow.Example.com:8443/ ").as_deref(), Some("https://flow.example.com:8443"));
        for bad in ["http://a.com", "https://", "https://a.com/x", "https://u:p@a.com", "https://a.com?q=1", "https://a.com#f", "a.com"] {
            assert_eq!(remote_origin(bad), None, "{bad}");
        }
        assert_eq!(normalized_origin("HTTP://LOCALHOST").as_deref(), Some("http://localhost:80"));
        assert_eq!(normalized_origin("https://a.com/v1").as_deref(), Some("https://a.com:443"));
        assert_eq!(normalized_origin("http://[::1]:8080").as_deref(), Some("http://[::1]:8080"));
        assert_eq!(normalized_origin("ftp://a.com"), None);
        assert_eq!(normalized_origin("http://a.com:0"), None);
        assert_eq!(normalized_origin("http://a.com:70000"), None);
        assert_eq!(normalized_origin("http://u@a.com"), None);
        assert_eq!(normalized_origin(&format!("http://{}.com", "a".repeat(260))), None);
        assert!(is_loopback_host("127.9.0.1") && is_loopback_host("::1") && is_loopback_host("localhost"));
        assert!(!is_loopback_host("128.0.0.1") && !is_loopback_host("127.0.0.256"));
        assert_eq!(validate_credential(""), Err(CredentialError::Empty));
        assert_eq!(validate_credential(&"x".repeat(4097)), Err(CredentialError::TooLarge));
        assert_eq!(validate_credential(" x"), Err(CredentialError::InvalidCharacters));
        assert_eq!(validate_credential("a\nb"), Err(CredentialError::InvalidCharacters));
        assert_eq!(validate_credential("ok"), Ok(()));
        let mut p = Prefs::memory();
        p.set("remote.serverURL", "http://not-valid");
        assert_eq!(remote_server_url(&p), "");
    }

    // parity: SET-406 SET-377 SET-378 SET-379 SET-380 SET-381 SET-382 SET-383 SET-384 SET-385 SET-386 SET-387 SET-388 SET-389 SET-390 SET-391 SET-392 SET-393 SET-394 SET-395 SET-396 SET-397 SET-398 SET-399 SET-402 SET-404 SET-405 SET-407 SET-408 SET-409 SET-410 SET-411 SET-412 SET-413 SET-422
    #[test]
    fn preference_defaults_and_keys_match_swift() {
        let mut p = Prefs::memory();
        assert_eq!(appearance(&p), "system");
        assert!(!bool_pref(&p, "keepModelReady") && !bool_pref(&p, "learnCorrections"));
        assert!(bool_pref(&p, "unloadLocalModelDuringGames") && bool_pref(&p, "showsBackgroundProgress"));
        assert_eq!(speech_model(&p), "parakeet-ultra");
        p.set("setupVersion", 1);
        assert_eq!(p.int_or("setupVersion", 0), 1);
        assert_eq!(speech_model(&p), "parakeet-v3");
        p.set("speechModel", "gone");
        assert_eq!(speech_model(&p), "parakeet-v3");
        assert_eq!(local_model_idle_unload(&p), 0);
        p.set("localModelIdleUnload", 900);
        assert_eq!(local_model_idle_unload(&p), 900);
        assert_eq!(meeting_language(&p), "automatic");
        assert_eq!(summary_server(&p), "local");
        assert_eq!(p.string("summaryServerURL"), None);
        assert_eq!(p.string("summaryServerModel"), None);
        assert_eq!(purpose(&p), "both");
        assert!(!bool_pref(&p, "rewriteEnabled"));
        assert_eq!(p.string("rewriteEndpoint"), None);
        assert_eq!(rewrite_mode(&p), "clean");
        assert_eq!(rewrite_timeout(&p), 20);
        p.set("rewriteTimeoutSeconds", 99);
        assert_eq!(rewrite_timeout(&p), 60);
        p.set("rewriteTimeoutSeconds", 1);
        assert_eq!(rewrite_timeout(&p), 5);
        assert!(!insecure_override(&p, "http://a:80"));
        assert!(!bool_pref(&p, "contextEnabled") && !bool_pref(&p, "contextRewriteEnabled") && !bool_pref(&p, "contextStyleEnabled"));
        assert_eq!(remote_state(&p), "off");
        p.set("remote.state", "wat");
        assert_eq!(remote_state(&p), "off");
        assert_eq!(remote_notice(&p), None);
        assert_eq!(p.int_or("remote.consentVersion", 0), 0);
        assert_eq!(fallback_threshold(&p), 1500);
        assert!(!p.bool_or("remote.enabled", false) && !p.bool_or("server.only", false));
        assert!(!use_for_everything(&p));
        assert!(use_for_everything(&approved()));
        for k in ["server.override.dictation", "server.override.rewrite", "server.override.summaries", "server.override.meetings"] {
            assert_eq!(override_of(&p, k), "server");
        }
        p.set("server.override.dictation", "custom");
        p.set("server.override.meetings", "custom");
        p.set("server.override.rewrite", "custom");
        assert_eq!(override_of(&p, "server.override.dictation"), "server");
        assert_eq!(override_of(&p, "server.override.meetings"), "server");
        assert_eq!(override_of(&p, "server.override.rewrite"), "custom");
        assert_eq!(loopback_endpoint(), "http://127.0.0.1:8080");
        assert!(ALWAYS_ON_MEETING_FLAGS);
        p.set("settings.meetingLanguage", "czech");
        for k in RETIRED_KEYS {
            p.set(k, true);
        }
        migrate(&mut p);
        assert_eq!(p.string("settings.meetingLanguage").as_deref(), Some("automatic"));
        assert!(RETIRED_KEYS.iter().all(|k| !p.contains(k)));
        assert_eq!((whisper_language("automatic"), whisper_language("slovak"), whisper_language("english")), ("auto", "sk", "en"));
    }

    // parity: SET-102 SET-111 SET-112 SET-113 SET-241 SET-414
    #[test]
    fn routing_truth_table() {
        let mut p = Prefs::memory();
        assert_eq!(routing(&p).model_place(Service::Dictation), None);
        p.set("server.capabilities", Capabilities { ops: ["dictation_start", "rewrite", "analysis", "meeting_job"].iter().map(|s| s.to_string()).collect(), meeting_jobs: ["transcribe".to_string()].into() });
        p.set("remote.enabled", true);
        p.set("remote.serverURL", "https://a.com");
        p.set("remote.state", "approved");
        p.set("remote.consentVersion", 1);
        assert!(routes_to_server(&p));
        p.set("remote.consentVersion", 2);
        let r = routing(&p);
        assert_eq!(r.placement(), "Everything on your server");
        assert_eq!(r.model_place(Service::Dictation), Some("On this Mac (used if the server is unreachable)"));
        assert_eq!(r.model_place(Service::Rewrite), Some("On your server"));
        assert!(r.local_rewrite_model_unneeded());
        p.set("server.override.rewrite", "thisMac");
        p.set("server.override.summaries", "custom");
        p.set("summaryServer", "remote");
        p.set("summaryServerURL", "http://h:8000/v1");
        p.set("summaryServerModel", "m");
        assert_eq!(routing(&p).placement(), "On your server: Dictation, Meetings · On this Mac: Rewriting · On your custom server: Summaries");
        assert_eq!(routing(&p).rewrite_endpoint("https://x"), loopback_endpoint());
        p.remove("server.capabilities");
        p.remove("server.override.rewrite");
        p.remove("server.override.summaries");
        assert_eq!(routing(&p).placement(), "On your server: Dictation, Rewriting · Not offered by this server: Summaries, Meetings");
        p.set("server.only", true);
        assert_eq!(routing(&p).place(Service::Summaries), "Unavailable");
        assert_eq!(routing(&p).model_place(Service::Dictation), Some("On your server"));
        p.set("server.capabilities", Capabilities { ops: ["analysis".to_string()].into(), meeting_jobs: BTreeSet::new() });
        p.set("remote.consentVersion", 1);
        assert_eq!(routing(&p).place(Service::Summaries), "Needs consent");
        p.remove("server.only");
        p.set("server.useForEverything", false);
        p.set("remote.consentVersion", 2);
        assert_eq!(routing(&p).path(Service::Rewrite), Path::Server);
        assert!(!routing(&p).switch_applies());
        p.set("remote.state", "pending");
        assert!(!routing(&p).routes);
        assert_eq!(routing(&p).model_place(Service::Rewrite), None);
    }

    // parity: SET-043 SET-044 SET-045 SET-046 SET-047 SET-048 SET-049 SET-050 SET-051 SET-052 SET-081 SET-082 SET-095 SET-096 SET-097 SET-098 SET-068
    #[test]
    fn remote_status_answers_and_reset() {
        let mut p = Prefs::memory();
        assert_eq!(remote_status(&p, false), None);
        p.set("remote.enabled", true);
        assert_eq!(remote_status(&p, false), Some("Checking the server…"));
        assert_eq!(remote_status(&p, true), Some("Compare the fingerprint"));
        for (state, text) in [("pinned", "Sign in to finish"), ("pending", "Waiting for approval"), ("approved", "Approved"), ("rejected", "Rejected"), ("revoked", "Removed from the server"), ("pin_mismatch", "Server identity changed")] {
            p.set("remote.state", state);
            assert_eq!(remote_status(&p, false), Some(text));
        }
        p.set("remote.state", "pinned");
        p.set("remote.notice", "sign_in_again");
        assert_eq!(remote_status(&p, false), Some("Sign in again"));
        p.set("remote.notice", "update_required");
        assert_eq!(remote_status(&p, false), Some("Update LocalFlow or the server"));
        p.remove("remote.notice");

        assert_eq!(apply_server_answer(&mut p, "revoked"), vec!["access-token", "refresh-token"]);
        assert_eq!(remote_state(&p), "revoked");
        p.set("remote.state", "rejected");
        assert_eq!(apply_server_answer(&mut p, "not_approved"), vec!["access-token"]);
        assert_eq!(remote_state(&p), "rejected");
        p.set("remote.state", "approved");
        apply_server_answer(&mut p, "not_approved");
        assert_eq!(remote_state(&p), "pending");
        assert_eq!(apply_server_answer(&mut p, "unauthorized"), vec!["access-token", "refresh-token"]);
        assert_eq!((remote_state(&p), remote_notice(&p)), ("pinned", Some("sign_in_again")));
        p.remove("remote.notice");
        apply_server_answer(&mut p, "unsupported_version");
        assert_eq!(remote_notice(&p), Some("update_required"));
        assert_eq!(apply_server_answer(&mut p, "token_expired"), vec!["access-token"]);
        assert_eq!(apply_server_answer(&mut p, "pin_mismatch"), vec!["access-token"]);
        assert_eq!(remote_state(&p), "pin_mismatch");
        assert_eq!(apply_server_answer(&mut p, "device_key_lost"), vec!["access-token", "refresh-token", "device-key"]);

        assert_eq!(consent_text(&p), CONSENT_TEXT);
        p.set("server.only", true);
        assert_eq!(consent_text(&p), MEETING_CONSENT_TEXT);
        p.set("server.useForEverything", true);
        p.set("server.override.rewrite", "custom");
        reset_remote(&mut p);
        assert!(!p.bool_or("remote.enabled", true));
        assert!(!p.contains("remote.serverURL") && !p.contains("remote.state"));
        assert!(p.bool_or("server.only", false) && p.contains("server.useForEverything") && p.contains("server.override.rewrite"));
        p.remove("server.only");
        p.set("setup.purpose", "meetings");
        assert_eq!(consent_text(&p), MEETING_CONSENT_TEXT);
    }

    // parity: SET-253 SET-262
    #[test]
    fn download_sizes_are_the_manifests() {
        for choice in ["parakeet-v3", "parakeet-ultra"] {
            let path = format!("{}/../../apps/macos/LocalFlow/Resources/Models/{choice}.json", env!("CARGO_MANIFEST_DIR"));
            let manifest: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
            let files = manifest["files"].as_array().unwrap();
            let sum: u64 = files.iter().map(|f| f["size"].as_u64().or(f["bytes"].as_u64()).unwrap()).sum();
            assert_eq!(speech_download_bytes(choice), sum, "{choice}");
        }
        assert_eq!(Alternate::not_installed(other_speech_model("parakeet-v3")).name(), "Parakeet Ultra");
    }

    // parity: SET-026
    #[test]
    fn error_copy_shortcuts() {
        assert_eq!(describe(&Failure::AccessibilityRequired), "Allow Accessibility to record and prioritize shortcuts.");
        assert_eq!(describe(&Failure::InputMonitoringDenied), "Allow Input Monitoring to use the dictation shortcut.");
        assert_eq!(describe(&Failure::InvalidBinding), "That shortcut is unavailable. Try another key combination.");
        assert_eq!(describe(&Failure::Conflict), "That shortcut is already registered. Try another combination.");
        assert_eq!(describe(&Failure::ShortcutUnavailable), "The keyboard shortcut could not start. Check permissions and try again.");
    }

    // parity: SET-027
    #[test]
    fn error_copy_busy_and_model() {
        assert_eq!(describe(&Failure::Busy), "Another dictation or model operation is still running. Wait for it to finish.");
        assert_eq!(describe(&Failure::ModelUnavailable), "The speech model is unavailable. Verify the local model in Settings.");
    }

    // parity: SET-028
    #[test]
    fn error_copy_server_only() {
        assert_eq!(describe(&Failure::ServerOnly), "Server only is on, but this Mac can't use your server. Check Settings › Server.");
    }

    // parity: SET-029
    #[test]
    fn error_copy_fallback() {
        assert_eq!(describe(&Failure::Other("Unavailable".into(), 0)), "Error type Unavailable, code 0.");
        assert_eq!(describe(&Failure::Cancelled), "The operation was cancelled.");
    }

    // parity: SET-030 SET-031 SET-033 SET-248 SET-254 SET-261 SET-262 SET-271 SET-275 SET-279
    #[test]
    fn snapshot_readiness_copy() {
        let mut s = Snapshot::default();
        assert_eq!((s.status.as_str(), s.speech_model), ("Checking local prerequisites…", "parakeet-ultra"));
        assert_eq!(s.shortcut.title(), "fn / Globe");
        assert_eq!((Permission::Unknown.label(), Permission::Denied.label(), Permission::Granted.label()), ("Not determined", "Not allowed", "Allowed"));
        assert_eq!(s.model_readiness(), "Not installed");
        s.model_installed = true;
        assert_eq!(s.model_readiness(), "Unloaded");
        for (r, t) in [(Runtime::Preparing, "Preparing…"), (Runtime::Releasing, "Unloading…"), (Runtime::Ready, "Ready")] {
            s.runtime = r;
            assert_eq!(s.model_readiness(), t);
        }
        assert_eq!(s.meeting_readiness(), "Not installed · 1.63 GB");
        assert_eq!(s.boost_readiness(), "Not installed · 103 MB");
        assert_eq!(s.speaker_readiness(), "Not installed");
        s.meeting_installing = true;
        s.speaker_installing = true;
        s.boost_installing = true;
        assert_eq!((s.meeting_readiness(), s.speaker_readiness(), s.boost_readiness()), ("Installing…", "Installing…", "Installing…"));
        s.meeting_installing = false;
        s.speaker_installing = false;
        s.boost_installing = false;
        s.meeting_installed = true;
        s.speaker_installed = true;
        s.boost_installed = true;
        assert_eq!((s.meeting_readiness(), s.speaker_readiness(), s.boost_readiness()), ("Ready", "Ready", "Ready"));
        assert!(speech_attribution("parakeet-v3").starts_with("NVIDIA parakeet-tdt-0.6b-v3"));
        assert!(speech_attribution("parakeet-ultra").starts_with("Moondream"));
        let mut a = Alternate { choice: "parakeet-ultra", installed: false, installing: false, completed: 0, total: 0, bytes: 2_500_000_000 };
        assert_eq!((a.role(), a.readiness().as_str()), ("Default for new setups", "Not installed · 2.5 GB"));
        a.installing = true;
        assert_eq!(a.readiness(), "Downloading…");
        a.installing = false;
        a.installed = true;
        a.choice = "parakeet-v3";
        assert_eq!((a.role(), a.readiness().as_str()), ("Alternative dictation model", "Installed"));

        let mut s = Snapshot::default();
        assert_eq!(s.meeting_blocked_reason(), Some("Allow Microphone access to record."));
        assert_eq!(s.test_blocked_reason().as_deref(), Some("Finish downloading speech recognition first."));
        s.model_installed = true;
        assert_eq!(s.test_blocked_reason().as_deref(), Some("Allow Microphone access to record."));
        s.microphone = Permission::Granted;
        assert_eq!(s.meeting_blocked_reason(), Some("Local storage is not ready. Check Settings before recording."));
        assert_eq!(s.test_blocked_reason().as_deref(), Some("Allow Input Monitoring to use the shortcut."));
        s.input_monitoring = Permission::Granted;
        s.shortcut.enabled = false;
        assert_eq!(s.test_blocked_reason().as_deref(), Some("Enable a dictation shortcut."));
        s.shortcut.enabled = true;
        assert_eq!(s.test_blocked_reason().as_deref(), Some("Starting the dictation shortcut…"));
        s.shortcut.kind = "key_combination".into();
        assert_eq!(s.test_blocked_reason().as_deref(), Some("Allow Accessibility for this shortcut, or choose a modifier key."));
        s.shortcut_ready = true;
        s.installing = true;
        assert_eq!(s.test_blocked_reason().as_deref(), Some("Wait for the model operation to finish."));
        s.installing = false;
        s.busy = true;
        assert_eq!(s.test_blocked_reason().as_deref(), Some("Wait for the current dictation to finish."));
        s.busy = false;
        assert_eq!(s.test_blocked_reason().as_deref(), Some("Local storage is not ready. Check Settings before recording."));
        s.storage_available = true;
        assert_eq!(s.test_blocked_reason(), None);
    }

    // parity: SET-157 SET-158 SET-159 SET-160 SET-161 SET-162 SET-165 SET-298 SET-415
    #[test]
    fn shortcut_rules_and_capture() {
        let mut p = Prefs::memory();
        assert_eq!(Shortcut::load(&p).title(), "fn / Globe");
        assert_eq!(Shortcut::right_control().title(), "Right Control");
        let combo = Shortcut { kind: "key_combination".into(), key_code: 49, modifiers: CMD | SHIFT, ..Default::default() };
        assert_eq!(combo.title(), "⇧ ⌘ Space");
        assert!(combo.includes_shift());
        assert_eq!(bypass_note(&combo), "Shift bypass is unavailable because Shift is in your shortcut.");
        assert_eq!(bypass_note(&Shortcut::default()), "Hold Shift on release to skip rewriting once.");
        assert_eq!(Shortcut { enabled: false, ..combo.clone() }.title(), "Disabled");
        assert_eq!(Shortcut { kind: "key_combination".into(), key_code: 122, modifiers: 0, ..Default::default() }.title(), "F1");
        assert_eq!(Shortcut { kind: "modifier_only".into(), modifiers: FN | OPTION, ..Default::default() }.title(), "⌥ fn");
        for (c, t) in [(36, "Return"), (48, "Tab"), (51, "⌫"), (53, "Esc"), (76, "Enter"), (78, "−"), (92, "9"), (116, "Page Up"), (117, "⌦"), (123, "←"), (90, "F20"), (0, "Key 0")] {
            assert_eq!(key_title(c), t);
        }
        // validation
        assert!(Shortcut { kind: "key_combination".into(), key_code: 0, modifiers: 0, ..Default::default() }.is_valid());
        assert!(!Shortcut { kind: "key_combination".into(), key_code: 53, modifiers: 0, ..Default::default() }.is_valid());
        assert!(Shortcut { kind: "key_combination".into(), key_code: 53, modifiers: CMD, ..Default::default() }.is_valid());
        assert!(!Shortcut { kind: "key_combination".into(), key_code: 56, modifiers: CMD, ..Default::default() }.is_valid());
        assert!(!Shortcut { kind: "key_combination".into(), key_code: 128, modifiers: CMD, ..Default::default() }.is_valid());
        assert!(!Shortcut { kind: "modifier_only".into(), modifiers: 0, ..Default::default() }.is_valid());
        assert!(!Shortcut { version: 2, ..Default::default() }.is_valid());
        assert!(!Shortcut { device_modifiers: Some(1), ..Default::default() }.is_valid());
        assert!(!Shortcut { kind: "modifier_only".into(), modifiers: CMD, device_modifiers: Some(0x1), ..Default::default() }.is_valid());
        // storage: invalid reads as default, JSON field names match Swift.
        p.set("shortcut", serde_json::json!({"version":1,"kind":"modifier_only","enabled":true,"keyCode":49,"modifiers":0}));
        assert_eq!(Shortcut::load(&p).kind, "fn_globe");
        Shortcut::right_control().save(&mut p);
        let raw: Value = p.get("shortcut").unwrap();
        assert_eq!(raw["keyCode"], 49);
        assert_eq!(raw["deviceModifiers"], 0x2000);
        assert_eq!(Shortcut::load(&p), Shortcut::right_control());
        // Implicit Fn: F-keys and navigation keys ignore the flag.
        assert_eq!(modifiers_from(FLAG_FN, Some(122)), 0);
        assert_eq!(modifiers_from(FLAG_FN, Some(123)), 0);
        assert_eq!(modifiers_from(FLAG_FN, Some(0)), FN);
        // Capture
        let mut c = CaptureState::default();
        assert_eq!(c.receive(KeyEvent::Down, 53, FLAG_COMMAND), Capture::Cancelled);
        assert_eq!(c.receive(KeyEvent::Down, 0, 0), Capture::Pending);
        let mut c = CaptureState::default();
        assert_eq!(c.receive(KeyEvent::Flags, 59, FLAG_COMMAND | 0x8), Capture::Pending);
        assert_eq!(c.receive(KeyEvent::Down, 49, FLAG_COMMAND | 0x8), Capture::Pending);
        assert_eq!(c.receive(KeyEvent::Up, 49, FLAG_COMMAND | 0x8), Capture::Pending);
        let Capture::Captured(s) = c.receive(KeyEvent::Flags, 59, 0) else { panic!() };
        assert_eq!((s.kind.as_str(), s.key_code, s.modifiers, s.device_modifiers), ("key_combination", 49, CMD, Some(0x8)));
        let mut c = CaptureState::default();
        c.receive(KeyEvent::Flags, 62, FLAG_CONTROL | 0x2000);
        let Capture::Captured(s) = c.receive(KeyEvent::Flags, 62, 0) else { panic!() };
        assert_eq!(s, Shortcut { kind: "modifier_only".into(), modifiers: CONTROL, device_modifiers: Some(0x2000), ..Default::default() });
        let mut c = CaptureState::default();
        c.receive(KeyEvent::Flags, 63, FLAG_FN);
        let Capture::Captured(s) = c.receive(KeyEvent::Flags, 63, 0) else { panic!() };
        assert_eq!(s.kind, "fn_globe");
    }

    // parity: SET-210 SET-216 SET-219 SET-221 SET-223 SET-225 SET-233 SET-238 SET-400 SET-401
    #[test]
    fn exclusions_and_kinds() {
        let mut p = Prefs::memory();
        let all = exclusions(&p);
        assert_eq!(all.len(), 10);
        assert!(all.contains(&BUNDLE_ID.to_string()));
        assert!(!p.contains("contextExcludedBundleIDs"));
        assert!(all.windows(2).all(|w| w[0] < w[1]));
        assert!(add_exclusion(&mut p, " com.example.App "));
        assert_eq!(exclusions(&p).len(), 11);
        assert!(p.contains("contextExcludedBundleIDs"));
        assert!(add_exclusion(&mut p, "com.example.App"));
        assert_eq!(exclusions(&p).len(), 11);
        assert!(!add_exclusion(&mut p, "has space"));
        assert!(!add_exclusion(&mut p, ""));
        assert!(!add_exclusion(&mut p, &"a".repeat(256)));
        remove_exclusion(&mut p, BUNDLE_ID);
        assert!(exclusions(&p).contains(&BUNDLE_ID.to_string()));
        remove_exclusion(&mut p, "com.example.App");
        assert_eq!(exclusions(&p).len(), 10);
        p.set("contextExcludedBundleIDs", (0..400).map(|i| format!("a{i}")).collect::<Vec<_>>());
        assert_eq!(exclusions(&p).len(), 200);
        assert!(!add_exclusion(&mut p, "zzz.new"));
        assert_eq!(effective_kind(&p, "com.apple.mail"), "email");
        assert_eq!(effective_kind(&p, "com.jetbrains.rider"), "code");
        assert_eq!(effective_kind(&p, "x.y"), "other");
        assert!(set_kind(&mut p, " com.apple.mail ", Some("document")));
        assert_eq!(effective_kind(&p, "com.apple.mail"), "document");
        assert!(set_kind(&mut p, "com.apple.mail", None));
        assert!(overrides(&p).is_empty());
        p.set("contextCategoryOverrides", serde_json::json!({"a.b":"email","c.d":"nonsense"}));
        assert_eq!(overrides(&p).len(), 1);
        assert_eq!(BUILT_IN.len(), 32);
        assert_eq!(natural_cmp("App 2", "app 10"), std::cmp::Ordering::Less);
        assert_eq!(app_count(1), "1 app");
        assert_eq!(app_count(10), "10 apps");
    }

    fn input(id: u32, uid: &str, name: &str, kind: &str) -> ConnectedInput {
        ConnectedInput { device_id: id, uid: uid.into(), model_uid: Some("m".into()), name: name.into(), kind: kind.into(), alive: true }
    }

    // parity: SET-179 SET-180 SET-181 SET-182 SET-183 SET-184 SET-185 SET-187 SET-188 SET-190 SET-192 SET-193 SET-195 SET-196 SET-197 SET-198 SET-416
    #[test]
    fn microphone_list_rules() {
        let mut p = Prefs::memory();
        assert_eq!(load_inputs(&p), vec![InputEntry::system_default()]);
        p.set(INPUTS_KEY, serde_json::json!({"version":9,"entries":[]}));
        assert_eq!(load_inputs(&p), vec![InputEntry::system_default()]);
        let built = input(1, "AAAA-1111", "MacBook Mic", "builtIn");
        let usb = input(2, "BBBB-2222", "Blue", "usb");
        let snap = InputSnapshot { inputs: vec![built.clone(), usb.clone()], default_input: Some(1), clamshell: false };
        let mut entries = load_inputs(&p);
        let list = mic_list(&entries, &snap);
        assert_eq!(list.add.len(), 2);
        assert_eq!(list.add_disabled, None);
        entries = add_input(&entries, &built, "id-1".into(), 0.).unwrap();
        entries = add_input(&entries, &usb, "id-2".into(), 0.).unwrap();
        assert_eq!(add_input(&entries, &usb, "id-3".into(), 0.), Err("duplicate"));
        assert_eq!(entries.last().unwrap().kind, "systemDefault");
        assert_eq!(entries[0].id, "id-1");
        let list = mic_list(&entries, &snap);
        assert_eq!(list.add_disabled, Some("All connected microphones are listed"));
        assert_eq!(list.rows[0].detail(), "Built-in");
        assert_eq!(list.rows[2].detail(), "Currently: MacBook Mic");
        assert_eq!(list.rows[1].a11y_label(), "Blue, USB, 2 of 3");
        // Clamshell: built-in unavailable.
        let closed = InputSnapshot { clamshell: true, ..snap.clone() };
        assert_eq!(mic_list(&entries, &closed).rows[0].detail(), "Built-in · Not connected");
        assert_eq!(mic_list(&entries, &closed).rows[0].a11y_label(), "MacBook Mic, Built-in, 1 of 3, not connected");
        // Nothing connected, no default.
        let none = InputSnapshot::default();
        assert_eq!(mic_list(&entries, &none).rows[2].detail(), "Currently: none");
        // Move and validation.
        let moved = move_input(&entries, "id-1", "id-2");
        assert_eq!(moved[1].id, "id-1");
        let moved = move_input(&moved, "id-1", "id-2");
        assert_eq!(moved[0].id, "id-1");
        assert_eq!(move_input(&entries, "id-1", "id-1"), entries);
        assert_eq!(move_input(&entries, "nope", "id-1"), entries);
        // Round-trips through prefs as Swift's shape; removing keeps default.
        save_inputs(&mut p, entries.clone());
        let raw: Value = p.get(INPUTS_KEY).unwrap();
        assert_eq!(raw["version"], 1);
        assert_eq!(raw["entries"][0]["modelUID"], "m");
        assert_eq!(load_inputs(&p), entries);
        // Duplicates dropped, one System default, capacity.
        let dup = validated_inputs(vec![entries[0].clone(), entries[0].clone(), InputEntry::system_default(), InputEntry::system_default()]);
        assert_eq!(dup.len(), 2);
        let many: Vec<InputEntry> = (0..40).map(|i| InputEntry { id: format!("{i}"), kind: "usb".into(), uid: Some(format!("u{i}")), model_uid: None, name: format!("n{i}"), last_seen_at: None }).collect();
        let cap = validated_inputs(many);
        assert_eq!(cap.len(), 32);
        assert!(cap.last().unwrap().is_system_default());
        assert_eq!(mic_list(&cap, &snap).add_disabled, Some("The list is full"));
        assert_eq!(add_input(&cap, &input(9, "z", "z", "usb"), "i".into(), 0.), Err("full"));
        assert_eq!(add_input(&entries, &input(9, "z", " ", "usb"), "i".into(), 0.), Err("invalid"));
        // Bluetooth note and duplicate name suffix.
        let bt = vec![
            InputEntry { id: "a".into(), kind: "bluetooth".into(), uid: Some("xxxx3F2A".into()), model_uid: None, name: "AirPods".into(), last_seen_at: None },
            InputEntry { id: "b".into(), kind: "bluetooth".into(), uid: Some("yyyy9999".into()), model_uid: None, name: "AirPods".into(), last_seen_at: None },
            InputEntry::system_default(),
        ];
        let list = mic_list(&bt, &InputSnapshot::default());
        assert_eq!(list.rows[0].title(), "AirPods · 3F2A");
        assert!(list.rows[0].detail().contains("Uses call-quality audio"));
        // M3: renamed UID, unique key matches and takes the new UID.
        let stale = vec![InputEntry { id: "a".into(), kind: "usb".into(), uid: Some("old".into()), model_uid: Some("m".into()), name: "Blue".into(), last_seen_at: Some(0.) }, InputEntry::system_default()];
        let reconciled = reconcile_inputs(&stale, &snap, 100.);
        assert_eq!(reconciled[0].uid.as_deref(), Some("BBBB-2222"));
        assert!(inputs_meaningfully_changed(&stale, &reconciled));
        let same = reconcile_inputs(&reconciled, &snap, 130.);
        assert!(!inputs_meaningfully_changed(&reconciled, &same));
        // Two entries with one key: no match.
        let two = vec![
            InputEntry { id: "a".into(), kind: "usb".into(), uid: Some("o1".into()), model_uid: Some("m".into()), name: "Blue".into(), last_seen_at: None },
            InputEntry { id: "b".into(), kind: "usb".into(), uid: Some("o2".into()), model_uid: Some("m".into()), name: "Blue".into(), last_seen_at: None },
        ];
        assert_eq!(match_inputs(&two, &[usb]), vec![None, None]);
    }

    // parity: SET-234 SET-235 SET-294 SET-299 SET-300 SET-301 SET-305 SET-321 SET-327 SET-332 SET-333
    #[test]
    fn rewrite_settings_copy() {
        let mut p = Prefs::memory();
        let s = RewriteSettings::capture(&p, |_| false);
        assert_eq!(s.blocked_reason(), Some("Enter a valid http:// or https:// endpoint first."));
        p.set("rewriteEndpoint", "http://10.0.0.5:8080");
        let s = RewriteSettings::capture(&p, |_| false);
        assert_eq!(s.blocked_reason(), Some("Allow the unencrypted connection to this server first, or use https://."));
        set_insecure_override(&mut p, "http://10.0.0.5:8080", true);
        let s = RewriteSettings::capture(&p, |_| false);
        assert_eq!(s.blocked_reason(), Some("Set a credential for this server first."));
        assert_eq!(s.warning().unwrap(), "Transcripts and the credential travel unencrypted to 10.0.0.5. Authentication does not encrypt them. Use this only on a network you trust.");
        assert_eq!(s.preflight(), Some(Connection::MissingCredential));
        let s = RewriteSettings::capture(&p, |_| true);
        assert_eq!(s.blocked_reason(), None);
        assert_eq!(s.preflight(), None);
        p.set("rewriteEndpoint", "http://127.0.0.1:8080");
        let s = RewriteSettings::capture(&p, |_| false);
        assert_eq!((s.blocked_reason(), s.is_unencrypted_remote()), (None, false));
        for mode in ["exact", "clean", "polished", "concise"] {
            assert!(!mode_definition(mode).is_empty());
        }
        for (c, t) in [
            (Connection::Connected, "Connected."),
            (Connection::AuthenticationFailed, "The server rejected the credential."),
            (Connection::Unreachable, "Could not reach the server."),
            (Connection::ServiceUnavailable, "This endpoint does not provide the LocalFlow rewrite service."),
            (Connection::BackendUnavailable, "The rewrite model is not available on the server."),
            (Connection::IncompatibleVersion, "The server does not support rewrite protocol version 1."),
            (Connection::MissingCredential, "Set a credential for this server first."),
            (Connection::InsecureBlocked, "Allow the unencrypted connection to this server first, or use https://."),
        ] {
            assert_eq!(c.status_text(), t);
            assert!(!c.category().is_empty());
        }
        let mut h = Health { service: "other".into(), ..Default::default() };
        assert_eq!(h.evaluate(), Connection::ServiceUnavailable);
        h.service = "localflow-rewrite".into();
        assert_eq!(h.evaluate(), Connection::IncompatibleVersion);
        h.protocol_versions = vec![1, 2];
        assert_eq!(h.evaluate(), Connection::BackendUnavailable);
        h.backend = Some(HealthBackend { state: "ready".into(), kind: None, model: Some("q".into()) });
        h.prompt_versions = [("clean".to_string(), 3), ("other".to_string(), 1)].into();
        assert_eq!(h.evaluate(), Connection::Connected);
        assert_eq!(h.identity_text(), "Server: Unknown Unknown\nBackend: Unknown · q\nPrompts: clean: 3\nShield: Unknown\nProtocol: 1, 2");
        assert_eq!(credential_message(Some(CredentialError::Empty)), "Enter a credential first.");
        assert_eq!(credential_message(Some(CredentialError::TooLarge)), "The credential must be no more than 4,096 bytes.");
        assert_eq!(credential_message(Some(CredentialError::InvalidCharacters)), "Remove surrounding whitespace and line breaks.");
        assert_eq!(credential_message(None), "Could not access the credential in Keychain.");
        assert_eq!(context_rewrite_blocked(false, true), Some("Turn on Use app context first."));
        assert_eq!(context_rewrite_blocked(true, false), Some("Turn on rewriting first."));
        assert_eq!(context_rewrite_blocked(true, true), None);
    }

    // parity: SET-059 SET-071 SET-072
    #[test]
    fn identity_validation_and_fingerprint() {
        assert_eq!(hex_of(&sha256(b"abc")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        let key = vec![7u8; 32];
        let fp = fingerprint_of(&key);
        assert_eq!(fp.len(), 39);
        assert_eq!(fp.split('-').count(), 8);
        let encoded = {
            const A: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
            let mut out = String::new();
            for c in key.chunks(3) {
                let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
                for i in 0..=c.len() {
                    out.push(A[((n >> (18 - 6 * i)) & 63) as usize] as char);
                }
            }
            out
        };
        assert_eq!(base64url_decode(&encoded).unwrap(), key);
        let good = Identity { schema_version: 1, server: serde_json::json!({}), protocol_versions: vec![1], suite: IDENTITY_SUITE.into(), server_key: encoded, fingerprint: fp };
        assert_eq!(good.validated_key().unwrap(), key);
        assert_eq!(Identity { fingerprint: "0".into(), ..good.clone() }.validated_key(), None);
        assert_eq!(Identity { schema_version: 2, ..good.clone() }.validated_key(), None);
        assert_eq!(Identity { protocol_versions: vec![2], ..good.clone() }.validated_key(), None);
        assert_eq!(Identity { suite: "x".into(), ..good.clone() }.validated_key(), None);
        assert_eq!(Identity { server_key: "AAAA".into(), ..good }.validated_key(), None);
    }

    fn speaker(db: &Db, id: &str, name: &str) {
        db.conn.execute("INSERT INTO known_speakers (id, display_name, is_local_user, recognition_enabled, created_at, updated_at, revision) VALUES (?1,?2,0,1,1,1,0)", params![id, name]).unwrap();
    }
    fn sample(db: &Db, id: &str, speaker: &str, ms: i64, quality: &str) {
        db.conn
            .execute(
                "INSERT INTO voice_samples (id, known_speaker_id, engine, model_id, model_revision, model_manifest_hash, dimension, pipeline_version, vector, quality_label, quality_score, speech_ms, track, start_ms, end_ms, consent, active, created_at) VALUES (?1,?2,'e','m','r',?3,1,'p',x'00000000',?4,0.5,?5,'microphone',0,1,'remember',1,?5)",
                params![id, speaker, "0".repeat(64), quality, ms],
            )
            .unwrap();
    }

    // parity: SET-358 SET-359 SET-360 SET-361 SET-362 SET-363 SET-364 SET-365 SET-366 SET-367 SET-368 SET-369 SET-370 SET-371 SET-372 SET-421
    #[test]
    fn known_speakers_model() {
        let db = Db::memory();
        speaker(&db, "b", "Bea");
        speaker(&db, "a", "Ann");
        sample(&db, "s1", "a", 1400, "good");
        sample(&db, "s2", "a", 2600, "fair");
        let mut m = KnownSpeakersModel::default();
        m.load(&db);
        assert_eq!(m.rows.iter().map(|r| r.name.as_str()).collect::<Vec<_>>(), ["Ann", "Bea"]);
        assert_eq!(m.rows[0].sample_count_text(), "2 voice samples");
        assert_eq!(m.rows[1].sample_count_text(), "0 voice samples");
        assert!(m.rows[1].needs_reenrollment());
        m.toggle_samples(&db, "a");
        let s = m.samples["a"].clone();
        assert_eq!(s.len(), 2);
        assert_eq!((s[1].duration_text().as_str(), s[1].quality_text()), ("1 s", "Good"));
        assert_eq!((s[0].duration_text().as_str(), s[0].quality_text()), ("3 s", "Fair"));
        assert!(s[0].provenance_unavailable);
        assert_eq!(s[0].source_text("12 Sep 2026", "F"), "Source meeting deleted · 12 Sep 2026");
        assert_eq!(VoiceSample { provenance_unavailable: false, source_title: None, ..s[0].clone() }.source_text("D", "Fallback"), "Fallback · D");
        m.toggle_samples(&db, "b");
        assert_eq!(m.expanded.as_deref(), Some("b"));
        m.toggle_samples(&db, "b");
        assert_eq!(m.expanded, None);
        assert_eq!(rename_error(" "), Some("Enter a name."));
        assert_eq!(rename_error(&"x".repeat(81)), Some("Use 80 characters or fewer."));
        assert_eq!(rename_error("a\u{7}b"), Some("Remove the control character."));
        assert_eq!(rename_error("Ok"), None);
        m.begin_rename("a");
        assert_eq!(m.rename_draft, "Ann");
        m.cancel_rename();
        assert_eq!(m.renaming, None);
        m.begin_rename("a");
        m.rename_draft = "  ".into();
        m.commit_rename(&db, 2);
        assert_eq!(m.renaming.as_deref(), Some("a"));
        m.rename_draft = "Ann".into();
        m.commit_rename(&db, 2);
        assert_eq!(m.rows[0].revision, 0);
        m.begin_rename("a");
        m.rename_draft = "Anna".into();
        m.commit_rename(&db, 2);
        assert_eq!((m.rows[0].name.as_str(), m.rows[0].revision), ("Anna", 1));
        m.set_recognition(&db, "a", false, 3);
        assert!(!m.rows[0].recognition);
        // Stale revision: notice and reload.
        db.conn.execute("UPDATE known_speakers SET revision=9 WHERE id='a'", []).unwrap();
        m.set_recognition(&db, "a", true, 4);
        assert_eq!(m.notice.as_deref(), Some("Known speakers changed elsewhere; the list was reloaded."));
        assert_eq!(m.rows[0].revision, 9);
        assert_eq!(rename_speaker(&db, "a", " ", 9, 1), Err(EditError::Invalid));
        assert_eq!(edit_notice(&EditError::Invalid), "That name can't be used.");
        assert_eq!(edit_notice(&EditError::Other), "The change could not be saved.");
        m.remove_sample(&db, "s1");
        assert_eq!(m.notice, None);
        assert_eq!(m.rows[0].active_samples, 1);
        m.remove_sample(&db, "gone");
        assert_eq!(m.notice.as_deref(), Some(REMOVE_SAMPLE_NOTICE));
        assert_eq!(delete_confirmation("Bea"), "Delete Bea? Voice samples are removed and future meetings will no longer recognize this voice. Past meetings keep the name.");
        m.request_delete("a");
        m.cancel_delete();
        assert_eq!(m.pending_delete, None);
        m.toggle_samples(&db, "a");
        m.request_delete("a");
        m.confirm_delete(&db);
        assert_eq!(m.rows.len(), 1);
        assert_eq!(m.expanded, None);
        let left: i64 = db.conn.query_row("SELECT count(*) FROM voice_samples", [], |r| r.get(0)).unwrap();
        assert_eq!(left, 0);
    }

    // parity: SET-348
    #[test]
    fn summary_headers_follow_the_routing() {
        let mut p = Prefs::memory();
        assert!(summary_headers(&p, None, false).is_empty());
        p.set("summaryServer", "remote");
        p.set("summaryServerURL", " http://h:8000/v1 ");
        assert!(summary_headers(&p, None, false).is_empty());
        p.set("summaryServerModel", "m");
        assert_eq!(summary_headers(&p, None, false), vec![("X-LocalFlow-Primary-URL", "http://h:8000/v1".to_string()), ("X-LocalFlow-Primary-Model", "m".to_string())]);
        assert_eq!(summary_headers(&p, Some("k"), true).len(), 4);
        assert_eq!(custom_summaries_host(&p).as_deref(), Some("h"));
    }

    // parity: SET-406
    #[test]
    fn consent_version_gates_dictation_at_one_and_the_rest_at_two() {
        let mut p = Prefs::memory();
        p.set("remote.enabled", true);
        p.set("remote.serverURL", "https://flow.example.com");
        p.set("remote.state", "approved");
        assert_eq!(CONSENT_VERSION, 2);
        for (version, dictation, current) in [(None, false, false), (Some(1), true, false), (Some(2), true, true)] {
            if let Some(v) = version {
                p.set("remote.consentVersion", v);
            }
            assert_eq!((routes_to_server(&p), consent_current(&p)), (dictation, current), "{version:?}");
        }
    }

    // parity: SET-374
    #[test]
    fn automatic_enrollment_follows_the_binding() {
        let db = Db::memory();
        assert!(prepare_automatic_enrollment(&db, "https://a", "f").unwrap(), "no binding enrolls");
        let bind = |enabled: i64| {
            db.conn.execute("INSERT OR REPLACE INTO usage_reporting_state(id,binding,enabled) VALUES(1,?1,?2)", rusqlite::params![r#"{"origin":"https://a","credentialFingerprint":"f"}"#, enabled]).unwrap();
        };
        bind(0);
        assert!(!prepare_automatic_enrollment(&db, "https://b", "f").unwrap(), "an inactive binding stays off");
        bind(1);
        assert!(!prepare_automatic_enrollment(&db, "https://a", "f").unwrap(), "the same binding does nothing");
        db.conn.execute("INSERT INTO usage_reporting_completions(id,day) VALUES('00000000-0000-0000-0000-000000000000','2026-10-31')", []).unwrap();
        assert!(prepare_automatic_enrollment(&db, "https://a", "new-key").unwrap(), "a changed key enrolls again");
        let left: i64 = db.conn.query_row("SELECT count(*) FROM usage_reporting_completions", [], |r| r.get(0)).unwrap();
        assert_eq!(left, 0, "and wipes");
        bind(1);
        assert!(prepare_automatic_enrollment(&db, "https://b", "f").unwrap(), "a changed server enrolls again");
    }

    // parity: SET-376 SET-375
    #[test]
    fn usage_notices_and_backoff_are_kept() {
        assert_eq!(USAGE_NOTICES.len(), 10);
        assert_eq!((usage_backoff(0), usage_backoff(30), usage_backoff(3000)), (30, 60, 3600));
    }

    // parity: SET-118
    #[test]
    fn channel_url_and_ping_need_pin_and_token() {
        assert_eq!(channel_url("https://flow.example.com:8443/"), "wss://flow.example.com:8443/v1/remote/channel");
        assert_eq!(channel_url("http://127.0.0.1:9"), "ws://127.0.0.1:9/v1/remote/channel");
        assert_eq!(base64url_decode(&base64url_encode(b"ab")).as_deref(), Some(&b"ab"[..]));
        assert_eq!(base64url_decode(&base64url_encode(&[255, 0, 3, 9])).as_deref(), Some(&[255, 0, 3, 9][..]));
        // `sessionInputs` nil: nothing connects, so a closed port would not even be tried.
        assert_eq!(ping("http://127.0.0.1:9", None, Some("t")), None);
        assert_eq!(ping("http://127.0.0.1:9", Some("AAAA"), None), None);
    }

    // parity: SET-045 SET-071
    #[cfg(unix)]
    #[test]
    fn real_flowd_identity_is_validated() {
        let f = super::test_flowd::Flowd::start();
        let identity = fetch_identity(&f.remote).expect("identity");
        assert_eq!(identity.fingerprint, f.fingerprint, "what the admin tool printed");
        assert_eq!(identity.validated_key().unwrap().len(), 32);
        assert!(fetch_identity(&f.down).is_err(), "closed port");
        assert!(fetch_identity(&f.rewrite).is_err(), "a server with no identity route");
    }

    // parity: SET-118 SET-119
    #[cfg(unix)]
    #[test]
    fn real_flowd_channel_round_trip() {
        let f = super::test_flowd::Flowd::start();
        let identity = fetch_identity(&f.remote).unwrap();
        let key = identity.validated_key().unwrap();
        assert!(channel_round_trip(&f.remote, &key, None).is_ok(), "enroll reaches ready");
        let (_, offered) = ping(&f.remote, Some(&identity.server_key), Some(&f.access_token)).expect("an approved device's session reaches ready");
        assert!(offered.is_some(), "ready carries the capabilities");
        assert_eq!(ping(&f.remote, Some(&identity.server_key), Some("not-a-token")), None);
        assert!(matches!(channel_round_trip(&f.remote, &key, Some("not-a-token")), Err(ChannelError::Server(_))), "a bad token is refused in the channel");
        assert_eq!(channel_round_trip(&f.remote, &[7u8; 32], None), Err(ChannelError::Unreachable), "a hello sealed to another key is closed");
        assert_eq!(channel_round_trip(&f.down, &key, None), Err(ChannelError::Unreachable));
    }

    // parity: SET-326 SET-327 SET-328 SET-332
    #[cfg(unix)]
    #[test]
    fn real_flowd_health_outcomes() {
        let f = super::test_flowd::Flowd::start();
        assert_eq!(rewrite_health(&f.rewrite, None), Err(Connection::AuthenticationFailed));
        assert_eq!(rewrite_health(&f.rewrite, Some("wrong")), Err(Connection::AuthenticationFailed));
        assert_eq!(rewrite_health(&f.down, None), Err(Connection::Unreachable));
        assert_eq!(rewrite_health(&f.remote, None), Err(Connection::ServiceUnavailable), "the remote listener has no rewrite route");
        let health = rewrite_health(&f.rewrite, Some(&f.token)).expect("health");
        assert_eq!(health.evaluate(), Connection::Connected);
        let identity = health.identity_text();
        for line in ["Server: flowd ", &format!("Backend: openai-compatible · {}", super::test_flowd::MODEL), "Prompts: ", "clean: ", "Shield: ", "Protocol: 1, 2"] {
            assert!(identity.contains(line), "{line} in {identity}");
        }
        assert_eq!(analysis_status_text(&f.rewrite, Some(&f.token)), format!("Meeting analysis: available (model {}).", super::test_flowd::MODEL));
        assert_eq!(analysis_status_text(&f.down, None), "Meeting analysis could not be checked.");
        assert_eq!(rewrite_health(&f.no_backend, Some(&f.token)).unwrap().evaluate(), Connection::BackendUnavailable);
        assert_eq!(analysis_status_text(&f.no_backend, Some(&f.token)), "This server does not offer meeting analysis.");
        assert_eq!(rewrite_health(&f.wrong_version, Some(&f.token)).unwrap().evaluate(), Connection::IncompatibleVersion);
    }
}
