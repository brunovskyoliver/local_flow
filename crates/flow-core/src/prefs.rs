//! `UserDefaults` keys, in a JSON file of the same names. Writes go to a temporary file and are
//! renamed, so a crash can't leave half a file.
use serde::{Serialize, de::DeserializeOwned};
use serde_json::{Map, Value};
use std::path::PathBuf;

pub struct Prefs {
    path: Option<PathBuf>,
    values: Map<String, Value>,
}

impl Prefs {
    /// A corrupt file reads as empty, as `UserDefaults` does for a missing value; the file is
    /// kept aside rather than overwritten.
    pub fn open(path: PathBuf) -> Self {
        let values = match std::fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_else(|_| {
                let _ = std::fs::rename(&path, path.with_extension("corrupt.json"));
                Map::new()
            }),
            Err(_) => Map::new(),
        };
        Prefs { path: Some(path), values }
    }
    /// In memory, for tests.
    pub fn memory() -> Self {
        Prefs { path: None, values: Map::new() }
    }
    pub fn get<T: DeserializeOwned>(&self, key: &str) -> Option<T> {
        self.values.get(key).and_then(|v| serde_json::from_value(v.clone()).ok())
    }
    pub fn string(&self, key: &str) -> Option<String> {
        self.get(key)
    }
    pub fn bool_or(&self, key: &str, default: bool) -> bool {
        self.get(key).unwrap_or(default)
    }
    pub fn int_or(&self, key: &str, default: i64) -> i64 {
        self.get(key).unwrap_or(default)
    }
    pub fn contains(&self, key: &str) -> bool {
        self.values.contains_key(key)
    }
    pub fn set<T: Serialize>(&mut self, key: &str, value: T) {
        self.values.insert(key.into(), serde_json::to_value(value).expect("preference serializes"));
        self.save();
    }
    pub fn remove(&mut self, key: &str) {
        self.values.remove(key);
        self.save();
    }
    fn save(&self) {
        let Some(path) = &self.path else { return };
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let tmp = path.with_extension("tmp");
        if std::fs::write(&tmp, serde_json::to_vec_pretty(&self.values).expect("map serializes")).is_ok() {
            let _ = std::fs::rename(&tmp, path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn persists_and_survives_corruption() {
        let dir = std::env::temp_dir().join(format!("flow-prefs-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("p.json");
        let mut p = Prefs::open(path.clone());
        p.set("appearance", "dark");
        assert_eq!(Prefs::open(path.clone()).string("appearance").as_deref(), Some("dark"));
        std::fs::write(&path, b"{not json").unwrap();
        assert_eq!(Prefs::open(path.clone()).string("appearance"), None);
        assert!(path.with_extension("corrupt.json").exists());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
