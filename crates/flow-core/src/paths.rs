use std::path::PathBuf;

/// Where data lives. Until the Mac cutover (Feature 028) the default is a folder of its own, so
/// this build can never open the production or `LocalFlow Dev` data.
#[derive(Clone, Debug)]
pub struct Paths {
    pub root: PathBuf,
}

impl Paths {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Paths { root: root.into() }
    }
    /// `LOCALFLOW_DATA_ROOT`, otherwise the platform's app data folder under `LocalFlow GPUI Dev`.
    pub fn resolve(platform_app_data: PathBuf) -> Self {
        match std::env::var_os("LOCALFLOW_DATA_ROOT") {
            Some(root) if !root.is_empty() => Paths::new(root),
            _ => Paths::new(platform_app_data.join("LocalFlow GPUI Dev")),
        }
    }
    pub fn database(&self) -> PathBuf {
        self.root.join("history.sqlite")
    }
    pub fn preferences(&self) -> PathBuf {
        self.root.join("preferences.json")
    }
    pub fn pending_audio(&self) -> PathBuf {
        self.root.join("PendingAudio")
    }
    pub fn temporary_audio(&self) -> PathBuf {
        self.root.join("TemporaryAudio")
    }
    pub fn models(&self) -> PathBuf {
        self.root.join("Models")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layout_matches_localflow_paths() {
        let p = Paths::new("/r");
        assert_eq!(p.database(), PathBuf::from("/r/history.sqlite"));
        assert_eq!(p.temporary_audio(), PathBuf::from("/r/TemporaryAudio"));
        assert_eq!(p.pending_audio(), PathBuf::from("/r/PendingAudio"));
        assert_eq!(p.models(), PathBuf::from("/r/Models"));
    }
}
