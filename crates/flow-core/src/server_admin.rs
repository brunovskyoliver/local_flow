//! The Users page's model (Feature 028 T044): `flowd admin list --json`, `audit --json`,
//! `token list --json` and the loopback status's `channels`, merged into users with their devices
//! nested. Structured reads only (FR-018); a flowd too old for `--json` is "needs updating".
use crate::history::{days_from_civil, month_short, region_date};
use serde::Deserialize;
use serde_json::Value;
use std::collections::{HashMap, HashSet};

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct AdminList {
    pub schema_version: i64,
    pub users: Vec<UserRow>,
    #[serde(default)]
    pub truncated: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct UserRow {
    pub id: i64,
    pub provider: String,
    pub display: Option<String>,
    pub state: String,
    pub created_at: String,
    pub devices: Vec<DeviceRow>,
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct DeviceRow {
    pub id: i64,
    pub name: String,
    pub kind: Option<String>,
    pub state: String,
    pub enrolled_at: String,
    pub last_seen_at: Option<String>,
    #[serde(default)]
    pub invited_by: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct AuditRow {
    pub at: String,
    pub actor: String,
    pub action: String,
    pub target: Option<String>,
    pub outcome: String,
}

/// A `token list --json` row. `user_id` 0 is a token for a new person.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct TokenRow {
    pub id: i64,
    pub label: String,
    pub state: String,
    pub user_id: i64,
    pub expires_at: String,
}

/// Why the page has nothing to show.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ReadError {
    /// flowd exited 1 without JSON: it predates `--json` (research R10).
    NeedsUpdate,
    /// `list --json` with a `schema_version` other than 1.
    Unsupported(i64),
    /// Any other failure, with stderr's first line.
    Failed(String),
}

impl ReadError {
    pub fn text(&self) -> String {
        match self {
            ReadError::NeedsUpdate => "This server needs updating before LocalFlow can show its users. Turn server mode off and on to update it.".into(),
            ReadError::Unsupported(v) => format!("This server reports users in a newer format ({v}). Update LocalFlow."),
            ReadError::Failed(reason) => format!("Couldn't read the server's users: {reason}"),
        }
    }
}

/// One `flowd admin … --json` run: exit status, stdout and stderr.
fn decode<T: for<'de> Deserialize<'de>>(status: i32, output: &str, error: &str) -> Result<T, ReadError> {
    if status == 0 {
        return serde_json::from_str(output.trim()).map_err(|_| ReadError::Failed("unreadable output".into()));
    }
    if status == 1 && output.trim().is_empty() {
        return Err(ReadError::NeedsUpdate);
    }
    Err(ReadError::Failed(error.lines().next().map(String::from).unwrap_or_else(|| format!("exit {status}"))))
}

pub fn decode_list(status: i32, output: &str, error: &str) -> Result<AdminList, ReadError> {
    // The version first, so a newer shape is refused as such rather than as unreadable.
    if status == 0
        && let Some(v) = serde_json::from_str::<Value>(output.trim()).ok().and_then(|v| v.get("schema_version")?.as_i64())
        && v != 1
    {
        return Err(ReadError::Unsupported(v));
    }
    decode(status, output, error)
}

pub fn decode_audit(status: i32, output: &str, error: &str) -> Result<Vec<AuditRow>, ReadError> {
    decode(status, output, error)
}

pub fn decode_tokens(status: i32, output: &str, error: &str) -> Result<Vec<TokenRow>, ReadError> {
    decode(status, output, error)
}

/// Device IDs with an open authenticated channel, from `GET /v1/admin/status`. `channels` is null
/// without a remote listener, which means nobody is connected.
pub fn connected(status: &Value) -> HashSet<i64> {
    status["channels"]["devices"].as_array().into_iter().flatten().filter_map(|d| d["device_id"].as_i64()).collect()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    User,
    Device,
}

impl Kind {
    pub fn word(self) -> &'static str {
        match self {
            Kind::User => "user",
            Kind::Device => "device",
        }
    }
}

/// What the page asks flowd to do; the platform's `ServerAdmin::act` turns it into arguments.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Action {
    Approve(Kind, i64),
    /// Users only: devices have no rejected state.
    Reject(i64),
    Revoke(Kind, i64),
    Rename(Kind, i64, String),
    CreateUser(String),
    RevokeToken(i64),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct User {
    pub id: i64,
    pub name: String,
    /// "Apple", "Google" or "Token".
    pub sign_in: &'static str,
    pub state: String,
    pub created: String,
    pub devices: Vec<Device>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Device {
    pub id: i64,
    pub name: String,
    pub kind: &'static str,
    pub state: String,
    pub added: String,
    pub last_seen: String,
    pub connected: bool,
    /// The name of the device whose invite this one redeemed.
    pub invited_by: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Token {
    pub id: i64,
    pub label: String,
    /// The user's name, or `None` for a new person.
    pub target: Option<String>,
    pub expires: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Model {
    pub users: Vec<User>,
    pub tokens: Vec<Token>,
    pub audit: Vec<AuditRow>,
    pub truncated: bool,
}

pub fn kind_label(kind: Option<&str>) -> &'static str {
    match kind {
        Some("mac") => "Mac",
        Some("windows") => "Windows PC",
        Some("iphone") => "iPhone",
        _ => "Unknown",
    }
}

fn sign_in(provider: &str) -> &'static str {
    match provider {
        "apple" => "Apple",
        "google" => "Google",
        _ => "Token",
    }
}

/// A user's name: the display name, or "User <id>".
pub fn user_name(id: i64, display: Option<&str>) -> String {
    display.filter(|d| !d.is_empty()).map(String::from).unwrap_or_else(|| format!("User {id}"))
}

/// Milliseconds since the epoch for flowd's `2026-11-03T09:12:44Z`.
pub fn parse_time(text: &str) -> Option<i64> {
    let b = text.as_bytes();
    if b.len() != 20 || b[19] != b'Z' {
        return None;
    }
    let n = |r: std::ops::Range<usize>| text.get(r)?.parse::<i64>().ok();
    let days = days_from_civil(n(0..4)?, n(5..7)?, n(8..10)?);
    Some(((days * 24 + n(11..13)?) * 60 + n(14..16)?) * 60_000 + n(17..19)? * 1000)
}

/// "3 Nov 2026, 10:01" in the region's format; the UTC text as given when unreadable.
pub fn when(text: &str) -> String {
    let Some(ms) = parse_time(text) else { return text.to_string() };
    region_date(ms, "yMMMdjmm", false).unwrap_or_else(|| {
        let (y, m, d) = crate::history::civil_from_days(ms.div_euclid(86_400_000));
        let minutes = ms.rem_euclid(86_400_000) / 60_000;
        format!("{d} {} {y}, {:02}:{:02} UTC", month_short(m), minutes / 60, minutes % 60)
    })
}

/// Merges the reads into the page. Tokens are the live, unexpired ones at `now` (ms).
pub fn merge(list: AdminList, connected: &HashSet<i64>, tokens: Vec<TokenRow>, audit: Vec<AuditRow>, now: i64) -> Model {
    let names: HashMap<i64, String> = list.users.iter().flat_map(|u| &u.devices).map(|d| (d.id, d.name.clone())).collect();
    let users: Vec<User> = list
        .users
        .into_iter()
        .map(|u| User {
            id: u.id,
            name: user_name(u.id, u.display.as_deref()),
            sign_in: sign_in(&u.provider),
            state: u.state,
            created: when(&u.created_at),
            devices: u
                .devices
                .into_iter()
                .map(|d| Device {
                    id: d.id,
                    kind: kind_label(d.kind.as_deref()),
                    state: d.state,
                    added: when(&d.enrolled_at),
                    last_seen: d.last_seen_at.as_deref().map(when).unwrap_or_else(|| "Never".into()),
                    connected: connected.contains(&d.id),
                    invited_by: d.invited_by.map(|id| names.get(&id).cloned().unwrap_or_else(|| format!("device {id}"))),
                    name: d.name,
                })
                .collect(),
        })
        .collect();
    let user_names: HashMap<i64, String> = users.iter().map(|u| (u.id, u.name.clone())).collect();
    let tokens = tokens
        .into_iter()
        .filter(|t| t.state == "live" && parse_time(&t.expires_at).is_some_and(|e| e > now))
        .map(|t| Token { id: t.id, target: (t.user_id != 0).then(|| user_names.get(&t.user_id).cloned().unwrap_or_else(|| format!("User {}", t.user_id))), expires: when(&t.expires_at), label: t.label })
        .collect();
    Model { users, tokens, audit, truncated: list.truncated }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Captured from flowd's own `--json` output (T038) with two users, three devices (one invited)
    // and three tokens.
    const LIST: &str = include_str!("../../../fixtures/server-admin/list.json");
    const AUDIT: &str = include_str!("../../../fixtures/server-admin/audit.json");
    const TOKENS: &str = include_str!("../../../fixtures/server-admin/tokens.json");

    #[test]
    fn merges_flowds_output_into_users_with_devices() {
        let status = serde_json::json!({"version": "1", "channels": {"open": 2, "devices": [{"device_id": 1, "channels": 2}]}});
        let now = parse_time("2026-11-04T12:00:00Z").unwrap();
        let model = merge(decode_list(0, LIST, "").unwrap(), &connected(&status), decode_tokens(0, TOKENS, "").unwrap(), decode_audit(0, AUDIT, "").unwrap(), now);
        assert!(!model.truncated);
        let [ana, other] = &model.users[..] else { panic!("{model:?}") };
        assert_eq!((ana.name.as_str(), ana.sign_in, ana.state.as_str()), ("Ana B", "Token", "approved"));
        assert_eq!((other.name.as_str(), other.sign_in, other.state.as_str()), ("User 2", "Apple", "pending"));
        let [mac, phone] = &ana.devices[..] else { panic!() };
        assert_eq!((mac.kind, mac.connected, mac.last_seen.as_str(), mac.invited_by.as_deref()), ("Mac", true, "3 Nov 2026, 10:01 UTC", None));
        assert_eq!((phone.kind, phone.connected, phone.last_seen.as_str(), phone.invited_by.as_deref()), ("iPhone", false, "Never", Some("Ana's MacBook")));
        assert_eq!((other.devices[0].kind, other.devices[0].state.as_str()), ("Unknown", "revoked"));
        // The invite awaiting confirmation isn't live; the two admin tokens are, one for a new person.
        let targets: Vec<_> = model.tokens.iter().map(|t| (t.label.as_str(), t.target.as_deref())).collect();
        assert_eq!(targets, [("Ben", None), ("For Ana", Some("Ana B"))]);
        assert_eq!(model.tokens[0].expires, "3 Dec 2026, 10:00 UTC");
        assert_eq!(model.audit[0].action, "rename");
        // Past their expiry the tokens are gone.
        let later = parse_time("2027-01-01T00:00:00Z").unwrap();
        assert!(merge(decode_list(0, LIST, "").unwrap(), &HashSet::new(), decode_tokens(0, TOKENS, "").unwrap(), vec![], later).tokens.is_empty());
    }

    #[test]
    fn an_old_server_a_newer_schema_and_failures() {
        assert_eq!(decode_list(1, "", "flowd: usage: flowd admin …"), Err(ReadError::NeedsUpdate));
        assert_eq!(decode_audit(1, "\n", "usage"), Err(ReadError::NeedsUpdate));
        assert_eq!(decode_list(0, r#"{"schema_version":2,"users":[],"truncated":false}"#, ""), Err(ReadError::Unsupported(2)));
        assert_eq!(decode_list(3, "", "database is locked\nmore"), Err(ReadError::Failed("database is locked".into())));
        assert_eq!(decode_list(0, "user 1 …", ""), Err(ReadError::Failed("unreadable output".into())), "text is never parsed");
        let cut = decode_list(0, r#"{"schema_version":1,"users":[],"truncated":true}"#, "").unwrap();
        assert!(merge(cut, &HashSet::new(), vec![], vec![], 0).truncated);
    }

    #[test]
    fn channels_and_kinds() {
        assert!(connected(&serde_json::json!({"channels": null})).is_empty(), "no remote listener");
        assert!(connected(&serde_json::json!({"version": "old"})).is_empty(), "a flowd before channels");
        assert_eq!(connected(&serde_json::json!({"channels": {"open": 3, "devices": [{"device_id": 3, "channels": 1}, {"device_id": 5, "channels": 2}]}})), HashSet::from([3, 5]));
        assert_eq!([Some("mac"), Some("windows"), Some("iphone"), None, Some("tv")].map(kind_label), ["Mac", "Windows PC", "iPhone", "Unknown", "Unknown"]);
        assert_eq!(parse_time("1970-01-02T00:00:01Z"), Some(86_401_000));
        assert_eq!(parse_time("2026-11-03 09:12"), None);
        assert_eq!(when("soon"), "soon");
    }
}
