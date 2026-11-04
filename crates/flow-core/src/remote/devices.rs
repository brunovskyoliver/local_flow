//! Device invites and "Your devices" (ADR 0039, specs/028-server-users-and-rewrite-warmup/contracts/device-invites.md).
//! Each operation runs on a session channel from the pool. Tokens, codes, keys and bindings are
//! never logged; `Invite`'s `Debug` leaves the token out.
use super::channel::{ChannelError, ServerMessage};
use super::pairing::PairingToken;
use super::pool::{Pool, Role};
use crate::settings::{base64url_decode, base64url_encode, sha256};
use serde_json::{Value, json};

pub const CODE_LABEL: &[u8] = b"localflow-v1-device-code";
pub const CONFIRM_LABEL: &[u8] = b"localflow-v1-device-confirm";

/// The 6-digit code both devices show: the first 4 bytes of SHA-256(label ‖ inviter key ‖ new key ‖
/// pair binding), big-endian, mod 1,000,000, with leading zeros.
pub fn device_code(inviter_key: &[u8], new_key: &[u8], pair_binding: &[u8]) -> String {
    let digest = sha256(&[CODE_LABEL, inviter_key, new_key, pair_binding].concat());
    format!("{:06}", u32::from_be_bytes([digest[0], digest[1], digest[2], digest[3]]) % 1_000_000)
}

/// `123 456`, as both screens show it.
pub fn grouped(code: &str) -> String {
    format!("{} {}", &code[..3], &code[3..])
}

/// What `device_confirm` signs: label ‖ the inviting device's session binding ‖ invite ID (8 bytes
/// big-endian) ‖ new key ‖ pair binding.
pub fn confirm_input(session_binding: &[u8], invite_id: i64, new_key: &[u8], pair_binding: &[u8]) -> Vec<u8> {
    [CONFIRM_LABEL, session_binding, &invite_id.to_be_bytes(), new_key, pair_binding].concat()
}

/// `localflow://pair?address=…&address=…#token=…`, the current address first.
pub fn invite_link(token: &PairingToken, addresses: &[String]) -> String {
    let encode = |s: &str| s.bytes().map(|b| if b.is_ascii_alphanumeric() || b"-._~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") }).collect::<String>();
    let query = addresses.iter().map(|a| format!("address={}", encode(a))).collect::<Vec<_>>().join("&");
    format!("localflow://pair?{query}#token={}", token.value)
}

#[derive(Clone, PartialEq, Eq)]
pub struct Invite {
    pub id: i64,
    pub token: PairingToken,
    pub expires_at: String,
}
impl std::fmt::Debug for Invite {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Invite({}, redacted)", self.id)
    }
}

/// What the inviting device needs for the code and the confirmation.
#[derive(Clone, PartialEq, Eq)]
pub struct PendingInvite {
    pub invite_id: i64,
    pub device_key: Vec<u8>,
    pub pair_binding: Vec<u8>,
    pub confirm_by: String,
}
impl std::fmt::Debug for PendingInvite {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "PendingInvite({}, redacted)", self.invite_id)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AccountDevice {
    pub id: i64,
    pub name: String,
    pub kind: Option<String>,
    /// `pending` or `approved`.
    pub state: String,
    pub enrolled_at: String,
    pub last_seen_at: Option<String>,
    pub connected: bool,
    pub this_device: bool,
    /// Only on a pending device that redeemed this device's invite.
    pub invite: Option<PendingInvite>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DevicesError {
    Channel(ChannelError),
    /// This device's key didn't sign.
    DeviceKey,
}
impl From<ChannelError> for DevicesError {
    fn from(e: ChannelError) -> Self {
        DevicesError::Channel(e)
    }
}
impl DevicesError {
    /// The server doesn't serve these operations: the controls hide.
    pub fn not_offered(&self) -> bool {
        matches!(self, DevicesError::Channel(ChannelError::Server(code)) if code == "not_offered")
    }
}

pub fn failure_message(error: &DevicesError) -> &'static str {
    match error {
        DevicesError::DeviceKey => "This device's key isn't available. Pair it again.",
        DevicesError::Channel(ChannelError::Server(code)) => match code.as_str() {
            "busy" => "Too many open invites. Try again later.",
            "not_approved" => "This device isn't approved yet.",
            "unauthorized" => "The server refused. Only the device that made the invite can confirm it.",
            "pairing_token_invalid" => "This invite has expired or was already used. Make a new one.",
            "not_offered" => "Update the LocalFlow server to add devices from here.",
            _ => "The server could not be reached. Try again.",
        },
        _ => "The server could not be reached. Try again.",
    }
}

/// One request and its reply of `reply_type` on the background channel. `build` gets the op and the
/// channel binding. `keep` false closes the channel afterwards, as after revoking this device.
fn exchange(pool: &Pool, reply_type: &str, keep: bool, build: impl FnOnce(i64, &[u8; 32]) -> Result<Value, DevicesError>) -> Result<Value, DevicesError> {
    let (mut channel, op) = pool.lease(Role::Background)?;
    let answer = build(op, &channel.binding()).and_then(|message| {
        channel.send(message)?;
        match channel.receive()? {
            ServerMessage::Other(object) if object["type"] == reply_type && object["op"] == op => Ok(object),
            ServerMessage::Error { code } => Err(ChannelError::Server(code).into()),
            _ => Err(ChannelError::Protocol.into()),
        }
    });
    pool.release(Role::Background, channel, (keep && answer.is_ok()).then_some(op + 1));
    answer
}

fn text(v: &Value) -> Option<String> {
    v.as_str().map(str::to_string)
}

/// A 10-minute, single-use invite for this device's own user.
pub fn invite(pool: &Pool) -> Result<Invite, DevicesError> {
    let reply = exchange(pool, "device_invite_reply", true, |op, _| Ok(json!({"type": "device_invite", "op": op})))?;
    let parsed = (|| Some(Invite { id: reply["invite_id"].as_i64()?, token: PairingToken::parse(reply["pairing_token"].as_str()?)?, expires_at: text(&reply["expires_at"])? }))();
    parsed.ok_or(ChannelError::Protocol.into())
}

fn parse_devices(reply: &Value) -> Result<Vec<AccountDevice>, DevicesError> {
    let device = |d: &Value| -> Option<AccountDevice> {
        let invite = match &d["invite"] {
            Value::Null => None,
            i => Some(PendingInvite {
                invite_id: i["invite_id"].as_i64()?,
                device_key: base64url_decode(i["device_key"].as_str()?).filter(|k| k.len() == 65)?,
                pair_binding: base64url_decode(i["pair_binding"].as_str()?).filter(|b| b.len() == 32)?,
                confirm_by: text(&i["confirm_by"])?,
            }),
        };
        Some(AccountDevice {
            id: d["id"].as_i64()?,
            name: text(&d["name"])?,
            kind: text(&d["kind"]),
            state: text(&d["state"]).filter(|s| s == "pending" || s == "approved")?,
            enrolled_at: text(&d["enrolled_at"])?,
            last_seen_at: text(&d["last_seen_at"]),
            connected: d["connected"].as_bool()?,
            this_device: d["this_device"].as_bool()?,
            invite,
        })
    };
    reply["devices"].as_array().and_then(|list| list.iter().map(device).collect()).ok_or(ChannelError::Protocol.into())
}

/// This user's devices, at most 100, by ID.
pub fn list(pool: &Pool) -> Result<Vec<AccountDevice>, DevicesError> {
    parse_devices(&exchange(pool, "account_devices_reply", true, |op, _| Ok(json!({"type": "account_devices", "op": op, "action": "list"})))?)
}

/// Removes one of this user's devices, this one included, and answers with the updated list.
/// Revoking this device closes its channel.
pub fn revoke(pool: &Pool, device_id: i64, this_device: bool) -> Result<Vec<AccountDevice>, DevicesError> {
    parse_devices(&exchange(pool, "account_devices_reply", !this_device, |op, _| Ok(json!({"type": "account_devices", "op": op, "action": "revoke", "device_id": device_id})))?)
}

/// Approves (`accept`) or removes the device that redeemed this device's invite. `sign` is this
/// device's key. True when the server approved it.
pub fn confirm(pool: &Pool, invite: &PendingInvite, accept: bool, sign: &dyn Fn(&[u8]) -> Option<Vec<u8>>) -> Result<bool, DevicesError> {
    let reply = exchange(pool, "device_confirm_reply", true, |op, binding| {
        let signature = sign(&confirm_input(binding, invite.invite_id, &invite.device_key, &invite.pair_binding)).ok_or(DevicesError::DeviceKey)?;
        Ok(json!({"type": "device_confirm", "op": op, "invite_id": invite.invite_id, "accept": accept, "signature": base64url_encode(&signature)}))
    })?;
    match reply["state"].as_str() {
        Some("approved") => Ok(true),
        Some("removed") => Ok(false),
        _ => Err(ChannelError::Protocol.into()),
    }
}

#[cfg(test)]
mod tests {
    use super::super::channel::{Channel, Purpose, Transports, unhex};
    use super::super::scripted::{Counters, Reply, Script};
    use super::*;
    use std::time::Duration;

    fn fixture(path: &str) -> Value {
        let path = format!("{}/../../fixtures/remote/{path}", env!("CARGO_MANIFEST_DIR"));
        serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
    }

    /// `fixtures/remote/device-code.json`, shared with flowd and Swift.
    #[test]
    fn codes_and_the_confirm_input_match_the_fixture() {
        let v = fixture("device-code.json");
        let hex = |x: &Value| unhex(x.as_str().unwrap());
        for vector in v["vectors"].as_array().unwrap() {
            assert_eq!(device_code(&hex(&vector["inviter_key"]), &hex(&vector["new_key"]), &hex(&vector["pair_binding"])), vector["code"].as_str().unwrap());
        }
        let c = &v["confirm"];
        assert_eq!(confirm_input(&hex(&c["session_binding"]), c["invite_id"].as_i64().unwrap(), &hex(&c["new_key"]), &hex(&c["pair_binding"])), hex(&c["signature_input"]));
        assert_eq!(grouped("017360"), "017 360");
    }

    fn pool(replies: Vec<Reply>) -> (Pool, Counters) {
        let script = Script::new([vec![Reply::ready()], replies].concat());
        let counters = script.counters();
        let opener: super::super::pool::Opener = Box::new(move || {
            let mut channel = Channel::new(script.open("ws://x").map_err(|_| ChannelError::Unreachable)?, &script.public_key())?;
            channel.open(Purpose::Session, Some("lfa_x"))?;
            Ok(channel)
        });
        (Pool::new(opener, Box::new(|| Duration::ZERO)), counters)
    }

    fn reply(path: &str, op: i64) -> Reply {
        let mut v = fixture(&format!("messages/valid/{path}.json"));
        v["op"] = op.into();
        Reply::Json(v)
    }

    #[test]
    fn invite_list_confirm_and_revoke() {
        let (pool, counters) = pool(vec![reply("device_invite_reply", 1), reply("account_devices_reply", 2), reply("device_confirm_reply", 3), reply("account_devices_reply-empty", 4)]);
        let invite = invite(&pool).unwrap();
        assert_eq!((invite.id, invite.expires_at.as_str()), (12, "2026-11-03T10:20:00Z"));
        assert!(!format!("{invite:?}").contains("lfp_"), "Debug leaves the token out");
        let link = invite_link(&invite.token, &["https://a.example.com:8443".into(), "http://100.64.0.1:8090".into()]);
        let parsed = super::super::pairing::PairingLink::parse(&link).unwrap();
        assert_eq!((parsed.address.as_deref(), parsed.token), (Some("https://a.example.com:8443, http://100.64.0.1:8090"), invite.token.clone()));

        let devices = list(&pool).unwrap();
        assert_eq!(devices.len(), 2);
        assert!(devices[0].this_device && devices[0].kind.as_deref() == Some("mac") && devices[0].invite.is_none());
        let pending = devices[1].invite.clone().unwrap();
        assert_eq!((devices[1].kind.as_deref(), devices[1].last_seen_at.as_deref(), pending.invite_id), (None, None, 12));

        let binding = std::sync::Mutex::new(vec![]);
        let approved = confirm(&pool, &pending, true, &|input| {
            *binding.lock().unwrap() = input.to_vec();
            Some(vec![0x30, 6, 2, 1, 1, 2, 1, 1])
        })
        .unwrap();
        assert!(approved);
        let seen = counters.messages();
        let sent = seen.iter().find(|m| m["type"] == "device_confirm").unwrap();
        assert_eq!((sent["invite_id"].as_i64(), sent["accept"].as_bool()), (Some(12), Some(true)));
        assert_eq!(*binding.lock().unwrap(), confirm_input(&counters.binding(), 12, &pending.device_key, &pending.pair_binding), "signs this channel's binding");

        assert!(revoke(&pool, 9, false).unwrap().is_empty());
        let sent = counters.messages();
        let last = sent.last().unwrap();
        assert_eq!((last["action"].as_str(), last["device_id"].as_i64()), (Some("revoke"), Some(9)));
        assert_eq!(counters.opened(), 1, "one channel, ops in sequence");
    }

    #[test]
    fn refusals_and_a_key_that_wont_sign() {
        let (pool, counters) = pool(vec![Reply::error("not_offered"), Reply::ready(), Reply::error("busy"), Reply::ready()]);
        let e = list(&pool).unwrap_err();
        assert!(e.not_offered());
        assert_eq!(failure_message(&invite(&pool).unwrap_err()), "Too many open invites. Try again later.");
        let pending = PendingInvite { invite_id: 12, device_key: vec![4; 65], pair_binding: vec![3; 32], confirm_by: "x".into() };
        let before = counters.messages().len();
        assert_eq!(confirm(&pool, &pending, true, &|_| None), Err(DevicesError::DeviceKey));
        assert_eq!(counters.messages().len(), before + 1, "only the hello of a fresh channel; nothing unsigned went out");
    }

    #[test]
    fn revoking_this_device_closes_its_channel() {
        let (pool, counters) = pool(vec![reply("account_devices_reply-empty", 1)]);
        revoke(&pool, 3, true).unwrap();
        assert_eq!(counters.closed(), 1);
    }
}
