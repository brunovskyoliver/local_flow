use std::fs::{File, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};

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

/// Swift's `AppInstanceLock`: `.instance.lock` in the data root, held exclusively for the app's
/// lifetime. The OS drops it when the process ends. A second owner gets an error, not a wait.
#[derive(Debug)]
pub struct InstanceLock(#[allow(dead_code)] File);

impl InstanceLock {
    pub fn acquire(directory: &Path) -> io::Result<InstanceLock> {
        let mut options = OpenOptions::new();
        options.create(true).truncate(false).read(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
            // `O_NOFOLLOW`, as Swift opens it.
            #[cfg(target_os = "macos")]
            options.custom_flags(0x0100);
        }
        let file = options.open(directory.join(".instance.lock"))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
        }
        file.try_lock().map_err(|e| match e {
            std::fs::TryLockError::WouldBlock => io::Error::new(io::ErrorKind::AddrInUse, "another LocalFlow owns this data folder"),
            std::fs::TryLockError::Error(e) => e,
        })?;
        Ok(InstanceLock(file))
    }
}

impl Paths {
    /// The launch steps before any store opens, in Swift's order: the data folder, private to this
    /// user, then the instance lock. Any failure lands in the launch failure.
    pub fn prepare(&self) -> io::Result<InstanceLock> {
        let mut folder = std::fs::DirBuilder::new();
        folder.recursive(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
            folder.mode(0o700);
            folder.create(&self.root)?;
            std::fs::set_permissions(&self.root, std::fs::Permissions::from_mode(0o700))?;
        }
        #[cfg(not(unix))]
        folder.create(&self.root)?;
        InstanceLock::acquire(&self.root)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("lf-paths-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    // A second owner is refused until the first lets go, in this process or another (flock is per open file).
    // parity: SHELL-007
    #[test]
    fn instance_lock_excludes_a_second_owner_until_release() {
        let root = temp("lock");
        let paths = Paths::new(&root);
        let first = paths.prepare().unwrap();
        assert_eq!(paths.prepare().unwrap_err().kind(), io::ErrorKind::AddrInUse);
        drop(first);
        let again = paths.prepare().unwrap();
        assert!(root.join(".instance.lock").is_file());
        drop(again);
        std::fs::remove_dir_all(root).unwrap();
    }

    // parity: SHELL-008
    #[cfg(unix)]
    #[test]
    fn data_root_and_lock_are_private_and_a_symlink_is_refused() {
        use std::os::unix::fs::PermissionsExt;
        let root = temp("private");
        std::fs::create_dir_all(&root).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o755)).unwrap();
        let lock = Paths::new(&root).prepare().unwrap();
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!((mode(&root), mode(&root.join(".instance.lock"))), (0o700, 0o600));
        drop(lock);
        std::fs::remove_file(root.join(".instance.lock")).unwrap();
        std::os::unix::fs::symlink(root.join("elsewhere"), root.join(".instance.lock")).unwrap();
        assert!(Paths::new(&root).prepare().is_err());
        assert!(!root.join("elsewhere").exists(), "the link's target isn't created");
        std::fs::remove_dir_all(&root).unwrap();
        // A root that can't be a folder fails the launch rather than running without a lock.
        std::fs::write(&root, b"").unwrap();
        assert!(Paths::new(&root).prepare().is_err());
        std::fs::remove_file(&root).unwrap();
    }

    #[test]
    fn layout_matches_localflow_paths() {
        let p = Paths::new("/r");
        assert_eq!(p.database(), PathBuf::from("/r/history.sqlite"));
        assert_eq!(p.temporary_audio(), PathBuf::from("/r/TemporaryAudio"));
        assert_eq!(p.pending_audio(), PathBuf::from("/r/PendingAudio"));
        assert_eq!(p.models(), PathBuf::from("/r/Models"));
    }
}
