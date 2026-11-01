//! One-time pairing tokens and links (Feature 027). A token stays in memory until redeemed; `Debug`
//! leaves the value out, and there's deliberately no `Display`.
use super::channel::ChannelError;
use super::enrollment::EnrollError;
use crate::settings::{base64url_decode, base64url_encode};

#[derive(Clone, PartialEq, Eq)]
pub struct PairingToken {
    pub value: String,
    /// The X25519 key of the server that issued the token.
    pub server_key: Vec<u8>,
}

impl std::fmt::Debug for PairingToken {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("PairingToken(redacted)")
    }
}

impl PairingToken {
    /// `lfp_` and the canonical base64url of the server's public key and 32 random bytes.
    pub fn parse(text: &str) -> Option<PairingToken> {
        let trimmed = text.trim();
        let encoded = trimmed.strip_prefix("lfp_")?;
        let raw = base64url_decode(encoded)?;
        (raw.len() == 64 && base64url_encode(&raw) == encoded).then(|| PairingToken { value: trimmed.to_string(), server_key: raw[..32].to_vec() })
    }
}

fn percent_decode(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = text.get(i + 1..i + 3)?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// `localflow://pair?address=<origin>#token=<token>` (`localflow-dev` in development builds). Opening
/// one fills in the form and spends nothing. Never log the URL.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PairingLink {
    /// As given, several joined by ", "; `address::origins` decides whether it's usable.
    pub address: Option<String>,
    pub token: PairingToken,
}

impl PairingLink {
    /// A link, opened or pasted whole.
    pub fn parse(text: &str) -> Option<PairingLink> {
        let (scheme, rest) = text.trim().split_once("://")?;
        if scheme != "localflow" && scheme != "localflow-dev" {
            return None;
        }
        let (rest, fragment) = rest.split_once('#')?;
        let (host, query) = rest.split_once('?').unwrap_or((rest, ""));
        if host != "pair" {
            return None;
        }
        let token = PairingToken::parse(fragment.strip_prefix("token=")?)?;
        let addresses = query.split('&').filter_map(|item| item.strip_prefix("address=")).map(percent_decode).collect::<Option<Vec<_>>>()?;
        Some(PairingLink { address: (!addresses.is_empty()).then(|| addresses.join(", ")), token })
    }
}

/// What the pairing form says about a failed `pair` or `update_address`.
pub fn failure_message(error: &EnrollError) -> &'static str {
    match error {
        EnrollError::WrongServer => "This address reaches a different server. Check the address or ask for a new token.",
        EnrollError::UpdateRequired => "Update the LocalFlow server to pair with a token. The token was not used.",
        EnrollError::InvalidIdentity => "The server did not answer with a LocalFlow identity. Check the address.",
        EnrollError::UnusableRoute => "This address isn't a usable LocalFlow route: it answers, but a proxy may be blocking WebSockets or changing paths.",
        EnrollError::DeviceKeyUnavailable => "This device can't create a device key.",
        EnrollError::Channel(ChannelError::Server(code)) => match code.as_str() {
            "pairing_token_invalid" => "This token has expired, been used or been revoked. Ask for a new one.",
            "revoked" | "not_approved" => "The server removed this device or its account. Ask the server's owner.",
            "unauthorized" => "The server knows this device under another account. Ask the server's owner.",
            "busy" => "The server is busy. Try again in a minute.",
            _ => "The server could not be reached. Try again.",
        },
        _ => "The server could not be reached. Try again.",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn token() -> String {
        format!("lfp_{}", base64url_encode(&[[0x11u8; 32], [0x22u8; 32]].concat()))
    }

    #[test]
    fn parses_the_server_key_and_trims_pasted_space() {
        let t = token();
        let parsed = PairingToken::parse(&format!(" {t}\n")).unwrap();
        assert_eq!(parsed.value, t);
        assert_eq!(parsed.server_key, [0x11; 32]);
    }

    #[test]
    fn refuses_anything_else() {
        let t = token();
        let cut = &t[..t.len() - 1];
        for bad in ["".to_string(), "lfp_".to_string(), t[4..].to_string(), cut.to_string(), format!("{t}A"), format!("lfr_{}", &t[4..]), format!("{cut}!"), format!("{cut}h"), format!("lfp_{}", base64url_encode(&[0x11; 32]))] {
            assert!(PairingToken::parse(&bad).is_none(), "{bad}");
        }
    }

    #[test]
    fn debug_leaves_the_value_out() {
        let parsed = PairingLink::parse(&format!("localflow://pair#token={}", token())).unwrap();
        assert!(!format!("{parsed:?}").contains("lfp_"));
        assert!(!format!("{:?}", parsed.token).contains("lfp_"));
    }

    #[test]
    fn links() {
        let t = token();
        for scheme in ["localflow", "localflow-dev"] {
            let link = PairingLink::parse(&format!("{scheme}://pair?address=https%3A%2F%2Fmini.example.com%3A8443#token={t}")).unwrap();
            assert_eq!(link.address.as_deref(), Some("https://mini.example.com:8443"));
            assert_eq!(link.token.value, t);
        }
        assert_eq!(PairingLink::parse(&format!("localflow://pair#token={t}")).unwrap().address, None);
        for text in ["localflow://settings".to_string(), "localflow://pair".to_string(), format!("localflow://pair?token={t}"), "localflow://pair#token=nope".to_string(), format!("localflow://session/start#token={t}"), format!("https://pair#token={t}"), format!("localflow://pair/x#token={t}")] {
            assert!(PairingLink::parse(&text).is_none(), "{text}");
        }
    }

    #[test]
    fn a_link_with_several_addresses() {
        let t = token();
        let link = PairingLink::parse(&format!("localflow://pair?address=https%3A%2F%2Fa.example.com&x=1&address=http%3A%2F%2F100.64.0.1%3A8090#token={t}")).unwrap();
        assert_eq!(link.address.as_deref(), Some("https://a.example.com, http://100.64.0.1:8090"));
        assert_eq!(super::super::address::origins(&link.address.unwrap()).map(|o| o.len()), Some(2));
        assert!(PairingLink::parse(&format!("localflow://pair?address=https%3A%2F%2Fa.example.com&address=%zz#token={t}")).is_none(), "a bad one fails the parse");
    }

    #[test]
    fn a_pasted_link() {
        let t = token();
        let link = PairingLink::parse(&format!(" localflow://pair?address=http%3A%2F%2Fmini.local#token={t}\n")).unwrap();
        assert_eq!(link.address.as_deref(), Some("http://mini.local"));
        assert_eq!(link.token.value, t);
        assert!(PairingLink::parse(&t).is_none());
        assert!(PairingLink::parse("not a link").is_none());
    }

    /// `fixtures/remote/pairing-vectors.json`, shared with flowd's TestPairingVectors.
    #[test]
    fn vectors() {
        let v: serde_json::Value = serde_json::from_str(include_str!("../../../../fixtures/remote/pairing-vectors.json")).unwrap();
        let s = |k: &str| v[k].as_str().unwrap().to_string();
        let hex = |k: &str| super::super::channel::unhex(&s(k));
        assert_eq!(super::super::enrollment::signature_input(b"localflow-v1-pair", &hex("binding"), &[]), hex("signature_input"));
        let parsed = PairingToken::parse(&s("token")).unwrap();
        assert_eq!(parsed.server_key, hex("server_public_key"));
        assert_eq!(s("token"), format!("lfp_{}", base64url_encode(&[hex("server_public_key"), hex("token_random")].concat())));
        assert_eq!(hex("signature")[0], 0x30, "DER, as device keys produce through raw_signature_to_der");
    }

    #[test]
    fn the_messages() {
        let server = |c: &str| EnrollError::Channel(ChannelError::Server(c.into()));
        assert_eq!(failure_message(&server("pairing_token_invalid")), "This token has expired, been used or been revoked. Ask for a new one.");
        assert_eq!(failure_message(&server("revoked")), "The server removed this device or its account. Ask the server's owner.");
        assert_eq!(failure_message(&server("not_approved")), "The server removed this device or its account. Ask the server's owner.");
        assert_eq!(failure_message(&server("unauthorized")), "The server knows this device under another account. Ask the server's owner.");
        assert_eq!(failure_message(&server("busy")), "The server is busy. Try again in a minute.");
        assert_eq!(failure_message(&server("internal")), "The server could not be reached. Try again.");
        assert_eq!(failure_message(&EnrollError::Channel(ChannelError::Timeout)), "The server could not be reached. Try again.");
        assert_eq!(failure_message(&EnrollError::WrongServer), "This address reaches a different server. Check the address or ask for a new token.");
        assert_eq!(failure_message(&EnrollError::UpdateRequired), "Update the LocalFlow server to pair with a token. The token was not used.");
        assert_eq!(failure_message(&EnrollError::InvalidIdentity), "The server did not answer with a LocalFlow identity. Check the address.");
        assert_eq!(failure_message(&EnrollError::UnusableRoute), "This address isn't a usable LocalFlow route: it answers, but a proxy may be blocking WebSockets or changing paths.");
        assert_eq!(failure_message(&EnrollError::DeviceKeyUnavailable), "This device can't create a device key.");
    }
}
