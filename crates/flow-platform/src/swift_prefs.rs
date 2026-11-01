//! Reads the Swift app's `UserDefaults` export. Swift keeps its JSON-encoded values, such as the
//! shortcut, as data; this client's preferences file holds them as JSON.
use serde_json::{Map, Value, json};

fn value(v: plist::Value) -> Option<Value> {
    Some(match v {
        plist::Value::String(s) => Value::String(s),
        plist::Value::Boolean(b) => json!(b),
        plist::Value::Integer(i) => json!(i.as_signed()?),
        plist::Value::Real(r) => json!(r),
        plist::Value::Array(a) => Value::Array(a.into_iter().filter_map(value).collect()),
        plist::Value::Dictionary(d) => Value::Object(d.into_iter().filter_map(|(k, v)| Some((k, value(v)?))).collect()),
        plist::Value::Data(d) => serde_json::from_slice(&d).ok()?,
        _ => return None,
    })
}

pub fn from_plist(bytes: &[u8]) -> Option<Map<String, Value>> {
    match value(plist::Value::from_reader(std::io::Cursor::new(bytes)).ok()?)? {
        Value::Object(map) => Some(map),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn converts_scalars_and_json_data_and_drops_the_rest() {
        // `{"version":1}` as base64.
        let xml = br#"<?xml version="1.0"?><plist version="1.0"><dict>
            <key>appearance</key><string>dark</string><key>keepModelReady</key><true/><key>n</key><integer>3</integer>
            <key>shortcut</key><data>eyJ2ZXJzaW9uIjoxfQ==</data><key>blob</key><data>AAEC</data><key>when</key><date>2026-01-01T00:00:00Z</date>
            <key>list</key><array><string>a</string></array></dict></plist>"#;
        let m = super::from_plist(xml).unwrap();
        assert_eq!(m["appearance"], "dark");
        assert_eq!(m["keepModelReady"], true);
        assert_eq!(m["n"], 3);
        assert_eq!(m["shortcut"]["version"], 1);
        assert_eq!(m["list"][0], "a");
        assert!(!m.contains_key("blob") && !m.contains_key("when"));
    }
}
