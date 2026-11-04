//! FR-012a: which addresses a client may use, per `RemoteDictationSettings`.
use std::net::{Ipv4Addr, Ipv6Addr};

/// Which kind of network an address found on the server belongs to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ServerAddressKind {
    Lan,
    Tailscale,
}

fn is_private(b: [u8; 4]) -> bool {
    b[0] == 127 || b[0] == 10 || (b[0] == 172 && b[1] & 0xf0 == 16) || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254) || (b[0] == 100 && b[1] & 0xc0 == 64)
}

fn v6_allows_http(b: [u8; 16]) -> bool {
    if b[..10].iter().all(|x| *x == 0) && b[10] == 0xff && b[11] == 0xff {
        return is_private([b[12], b[13], b[14], b[15]]);
    }
    Ipv6Addr::from(b) == Ipv6Addr::LOCALHOST || b[0] & 0xfe == 0xfc || (b[0] == 0xfe && b[1] & 0xc0 == 0x80)
}

/// What `inet_aton` would read as an address though it isn't a dotted quad: `2130706433`, `0x7f.1`,
/// `127.1`. Digits that overflow count too: they're refused, never treated as a name.
fn numeric_address(name: &str) -> bool {
    let parts: Vec<&str> = name.split('.').collect();
    parts.len() <= 4
        && parts.iter().all(|p| match p.strip_prefix("0x") {
            Some(hex) => hex.chars().all(|c| c.is_ascii_hexdigit()),
            None => !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()),
        })
}

/// `allowsPlainHTTP`: `host` is lowercase, an IPv6 literal without brackets or its zone.
fn allows_plain_http(host: &str, bracketed: bool) -> bool {
    if bracketed {
        return host.parse::<Ipv6Addr>().is_ok_and(|a| v6_allows_http(a.octets()));
    }
    if let Ok(a) = host.parse::<Ipv4Addr>() {
        return is_private(a.octets());
    }
    if numeric_address(host) {
        return false;
    }
    let labels: Vec<&str> = host.split('.').collect();
    if !labels.iter().all(|l| !l.is_empty() && l.bytes().all(|c| c == b'-' || c.is_ascii_lowercase() || c.is_ascii_digit())) {
        return false;
    }
    labels.len() == 1 || labels.last() == Some(&"local") || (labels.len() > 2 && labels[labels.len() - 2..] == ["ts", "net"])
}

/// An origin with no path, query, fragment or credentials; `None` otherwise. `https://` on any host,
/// `http://` only where FR-012a says.
// ponytail: an ASCII host only, where Foundation would apply IDNA and percent-decoding. Refusing is
// the safe side: a non-ASCII name has to be typed as punycode.
pub fn origin(text: &str) -> Option<String> {
    let (scheme, rest) = text.trim().split_once("://")?;
    if scheme != "https" && scheme != "http" {
        return None;
    }
    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let (authority, tail) = rest.split_at(end);
    if (!tail.is_empty() && tail != "/") || authority.contains('@') {
        return None;
    }
    let (host, bracketed, port) = if let Some(inner) = authority.strip_prefix('[') {
        let (h, after) = inner.split_once(']')?;
        let port = if after.is_empty() { None } else { Some(after.strip_prefix(':')?) };
        (h, true, port)
    } else {
        match authority.rsplit_once(':') {
            Some((h, p)) => (h, false, Some(p)),
            None => (authority, false, None),
        }
    };
    let port = match port {
        None | Some("") => None,
        Some(p) => Some(p.parse::<u16>().ok()?),
    };
    let host = host.to_ascii_lowercase();
    if host.is_empty() {
        return None;
    }
    let literal = if bracketed {
        let (address, zone) = match host.split_once('%') {
            Some((a, z)) => (a, Some(z.strip_prefix("25")?)),
            None => (host.as_str(), None),
        };
        if zone.is_some_and(|z| z.is_empty() || !z.bytes().all(|c| c.is_ascii_alphanumeric() || b"-._~".contains(&c))) {
            return None;
        }
        address.parse::<Ipv6Addr>().ok()?;
        address
    } else {
        if !host.bytes().all(|c| c.is_ascii_alphanumeric() || b"-._~".contains(&c)) {
            return None;
        }
        host.as_str()
    };
    if scheme == "http" && !allows_plain_http(literal, bracketed) {
        return None;
    }
    let shown = if bracketed { format!("[{host}]") } else { host.clone() };
    Some(match port {
        Some(p) => format!("{scheme}://{shown}:{p}"),
        None => format!("{scheme}://{shown}"),
    })
}

/// Where an address found on this machine leads. `None` for loopback, link-local, public or not an IP.
pub fn server_address_kind(ip: &str) -> Option<ServerAddressKind> {
    // The MagicDNS name of this Mac's Tailscale address, which reverse lookup finds.
    if ip.ends_with(".ts.net") && allows_plain_http(ip, false) {
        return Some(ServerAddressKind::Tailscale);
    }
    if let Ok(a) = ip.parse::<Ipv4Addr>() {
        let b = a.octets();
        if !is_private(b) || b[0] == 127 || (b[0] == 169 && b[1] == 254) {
            return None;
        }
        return Some(if b[0] == 100 { ServerAddressKind::Tailscale } else { ServerAddressKind::Lan });
    }
    let b = ip.parse::<Ipv6Addr>().ok()?.octets();
    if !v6_allows_http(b) || b[0] & 0xfe != 0xfc {
        return None;
    }
    Some(if b[..6] == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] { ServerAddressKind::Tailscale } else { ServerAddressKind::Lan })
}

fn pieces(text: &str) -> impl Iterator<Item = &str> + Clone {
    text.split(|c: char| c == ',' || c.is_whitespace()).filter(|p| !p.is_empty())
}

/// Several addresses of one server, separated by commas or spaces: at most 8, each a valid `origin`,
/// without repeats. `None` when any isn't, or there are none.
pub fn origins(text: &str) -> Option<Vec<String>> {
    let mut out: Vec<String> = Vec::new();
    for piece in pieces(text) {
        let checked = origin(piece)?;
        if !out.contains(&checked) {
            out.push(checked);
        }
    }
    (!out.is_empty() && out.len() <= 8).then_some(out)
}

/// `address_notice` for a list: a refused address says so first, then any plain `http://`.
pub fn list_notice(text: &str) -> Option<&'static str> {
    pieces(text).filter(|p| origin(p).is_none()).find_map(address_notice).or_else(|| pieces(text).find_map(address_notice))
}

/// What a server form says under the address: why `http://` is refused, or that it isn't TLS.
pub fn address_notice(text: &str) -> Option<&'static str> {
    if !text.trim().starts_with("http://") {
        return None;
    }
    Some(if origin(text).is_none() { "http:// works only for private and Tailscale addresses. Use https:// for this one." } else { "This connection is not TLS. Content stays encrypted between this device and the server." })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Swift's `testHTTPOriginRule` table, row for row. Each must round-trip through what's saved.
    #[test]
    fn http_origin_rule() {
        for text in [
            "http://127.0.0.1:8090", "http://127.255.0.1", "http://10.0.0.1", "http://172.16.0.1", "http://172.31.255.255", "http://192.168.1.20:8090", "http://169.254.1.1",
            "http://100.64.0.1", "http://100.127.255.255", "http://[::1]:8090", "http://[fe80::1]", "http://[febf::1]", "http://[fc00::1]", "http://[fd12:3456::1]",
            "http://[fd7a:115c:a1e0::1]:8090", "http://[::ffff:127.0.0.1]", "http://[::ffff:10.0.0.1]", "http://[::ffff:c0a8:114]", "http://[::ffff:100.64.0.1]", "http://localhost:8090",
            "http://mini", "http://mini-2", "http://mini.local", "http://a.b.local:8090", "http://mini.tail1234.ts.net", "http://mini.ts.net",
            "https://example.com", "https://8.8.8.8", "https://[2606:4700::1111]", "https://mini.local",
        ] {
            let saved = origin(text).unwrap_or_else(|| panic!("{text}"));
            assert_eq!(origin(&saved).as_ref(), Some(&saved), "{text}");
            assert!(super::super::channel::channel_url(&saved).is_some(), "{text}");
        }
        for text in ["http://MINI.LOCAL", "http://Mini", "http://MINI.TailNet.TS.Net", "http://[FE80::1]"] {
            assert!(origin(text).is_some(), "{text}");
        }
        for text in [
            "http://8.8.8.8", "http://1.1.1.1:8090", "http://172.15.0.1", "http://172.32.0.1", "http://192.169.0.1", "http://169.253.0.1", "http://100.63.255.255", "http://100.128.0.1",
            "http://0.0.0.0", "http://224.0.0.1", "http://255.255.255.255", "http://example.com", "http://evil.ts.net.example.com", "http://10.0.0.1.example.com", "http://mini.local.evil.com",
            "http://ts.net", "http://.ts.net", "http://.local", "http://local.", "http://mini.", "http://mini.local.", "http://xts.net", "http://evilts.net",
            "http://[::]", "http://[2606:4700::1111]", "http://[::ffff:8.8.8.8]", "http://[::ffff:808:808]", "http://[::8.8.8.8]", "http://[64:ff9b::808:808]",
            "http://[fe00::1]", "http://[fec0::1]", "http://[nonsense]", "http://[10.0.0.1]",
            "http://134744072", "http://2130706433", "http://0x08080808", "http://0x8.8.8.8", "http://8.8.8", "http://8.8", "http://010.0.0.1.", "http://127.1",
            "http://10.0.0.1%2eexample.com", "http://mini\u{3002}evil.com", "http://b\u{00fc}cher",
            "http://u:p@10.0.0.1", "http://10.0.0.1/path", "http://10.0.0.1?x=1", "http://10.0.0.1#f", "ftp://10.0.0.1", "ws://10.0.0.1", "10.0.0.1", "",
        ] {
            assert_eq!(origin(text), None, "{text}");
            assert_eq!(super::super::channel::channel_url(text), None, "a refused address gets no socket: {text}");
        }
    }

    #[test]
    fn normalizes() {
        assert_eq!(origin(" https://Server.Example.com:8443/ ").as_deref(), Some("https://server.example.com:8443"));
        assert_eq!(origin("http://MINI.local/").as_deref(), Some("http://mini.local"));
        assert_eq!(origin("https://a.example:99999"), None);
        assert_eq!(origin("https://a.example:x"), None);
        assert_eq!(origin("https://[::1]x"), None);
        assert_eq!(origin("https://[nonsense]"), None, "brackets hold an address on https too");
        assert_eq!(origin("https://a b.example"), None);
    }

    #[test]
    fn ipv6_zone_is_kept_and_checked() {
        let saved = origin("http://[fe80::1%25en0]:8090").unwrap();
        assert_eq!(saved, "http://[fe80::1%25en0]:8090");
        assert_eq!(origin(&saved), Some(saved));
        assert_eq!(origin("http://[2606:4700::1111%25en0]"), None);
        assert_eq!(origin("http://[fe80::1%en0]"), None, "a zone must be percent-encoded");
    }

    #[test]
    fn notice() {
        assert_eq!(address_notice(" http://10.0.0.1:8090 "), Some("This connection is not TLS. Content stays encrypted between this device and the server."));
        assert_eq!(address_notice("http://example.com"), Some("http:// works only for private and Tailscale addresses. Use https:// for this one."));
        assert_eq!(address_notice("https://example.com"), None);
        assert_eq!(address_notice(""), None);
    }

    #[test]
    fn several_addresses() {
        let list = |t: &str| origins(t).map(|o| o.join(" "));
        assert_eq!(list("https://A.example.com, http://100.64.0.1:8090\nhttps://a.example.com/ ,, https://b.example.com").as_deref(), Some("https://a.example.com http://100.64.0.1:8090 https://b.example.com"), "split, normalized, repeats dropped in order");
        assert_eq!(list("https://a.example.com"), Some("https://a.example.com".into()));
        for bad in ["", " , ", "https://a.example.com, http://8.8.8.8", "https://a.example.com, nope"] {
            assert_eq!(origins(bad), None, "{bad}");
        }
        let many = |n: usize| (0..n).map(|i| format!("https://s{i}.example.com")).collect::<Vec<_>>().join(",");
        assert_eq!(origins(&many(8)).map(|o| o.len()), Some(8));
        assert_eq!(origins(&many(9)), None);
    }

    #[test]
    fn a_list_shows_the_notice_of_any_piece() {
        const NOT_TLS: &str = "This connection is not TLS. Content stays encrypted between this device and the server.";
        assert_eq!(list_notice("https://a.example.com, http://100.64.0.1:8090"), Some(NOT_TLS));
        assert_eq!(list_notice("http://100.64.0.1, http://8.8.8.8"), address_notice("http://8.8.8.8"), "a refusal comes first");
        assert_eq!(list_notice("https://a.example.com, https://b.example.com"), None);
    }

    /// Swift's `ServerAddressKindTests`. Every address offered must be one `origin` accepts over http.
    #[test]
    fn address_kinds() {
        use ServerAddressKind::*;
        let table = [
            ("192.168.1.20", Some(Lan)), ("10.0.0.2", Some(Lan)), ("172.16.0.1", Some(Lan)), ("172.31.255.1", Some(Lan)), ("fd12:3456::1", Some(Lan)),
            ("100.64.0.1", Some(Tailscale)), ("100.127.255.254", Some(Tailscale)), ("fd7a:115c:a1e0::1", Some(Tailscale)),
            ("127.0.0.1", None), ("::1", None), ("169.254.1.1", None), ("fe80::1", None), ("100.63.255.255", None), ("100.128.0.1", None), ("172.32.0.1", None), ("8.8.8.8", None),
            ("2001:4860:4860::8888", None), ("mini.local", None), ("", None),
        ];
        for (ip, kind) in table {
            assert_eq!(server_address_kind(ip), kind, "{ip}");
            if kind.is_some() {
                let host = if ip.contains(':') { format!("[{ip}]") } else { ip.to_string() };
                assert!(origin(&format!("http://{host}:8090")).is_some(), "{ip}");
            }
        }
    }
}
