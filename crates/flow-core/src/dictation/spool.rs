//! The bounded temporary audio of one dictation: `<root>/<id>/audio.f32`, 16 kHz mono f32, private to
//! the user. Removed on every exit and at launch; a waiting dictation moves it out first.
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

/// `RemoteProtocol.maximumSessionSamples`: 180 s.
pub const MAX_SAMPLES: usize = 2_880_000;

pub struct Spool {
    dir: PathBuf,
    path: PathBuf,
    file: File,
    samples: usize,
}

fn private_dir(path: &Path) -> io::Result<()> {
    fs::create_dir_all(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

/// Reads what the writer has flushed, from any thread.
pub struct Reader(File, PathBuf);

impl Reader {
    pub fn open(path: &Path) -> io::Result<Reader> {
        Ok(Reader(File::open(path)?, path.to_path_buf()))
    }
    /// A second handle with its own file position, for a thread that may outlive this one.
    pub fn reopen(&self) -> io::Result<Reader> {
        Reader::open(&self.1)
    }
    pub fn read(&mut self, start: usize, count: usize) -> io::Result<Vec<f32>> {
        self.0.seek(SeekFrom::Start(start as u64 * 4))?;
        let mut bytes = vec![0; count * 4];
        self.0.read_exact(&mut bytes)?;
        Ok(bytes.chunks_exact(4).map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]])).collect())
    }
}

impl Spool {
    pub fn create(root: &Path, id: &str) -> io::Result<Spool> {
        private_dir(root)?;
        let dir = root.join(id);
        private_dir(&dir)?;
        let path = dir.join("audio.f32");
        let mut options = OpenOptions::new();
        options.create_new(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        Ok(Spool { file: options.open(&path)?, dir, path, samples: 0 })
    }
    pub fn reader(&self) -> io::Result<Reader> {
        Reader::open(&self.path)
    }
    pub fn samples(&self) -> usize {
        self.samples
    }
    pub fn path(&self) -> &Path {
        &self.path
    }
    /// Writes up to the limit and returns how many fit. Each call reaches the file before it returns.
    pub fn append(&mut self, samples: &[f32]) -> io::Result<usize> {
        let n = samples.len().min(MAX_SAMPLES - self.samples);
        let bytes: Vec<u8> = samples[..n].iter().flat_map(|s| s.to_le_bytes()).collect();
        self.file.write_all(&bytes)?;
        self.samples += n;
        Ok(n)
    }
    pub fn remove(self) -> io::Result<()> {
        drop(self.file);
        fs::remove_dir_all(&self.dir)
    }
}

/// Launch: one app holds the data root (`InstanceLock`), so anything here is left from a crash.
pub fn remove_stale(root: &Path) -> io::Result<()> {
    match fs::remove_dir_all(root) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e),
        _ => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn root(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("flow-spool-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        root
    }

    #[test]
    fn writes_reads_bounds_and_removes() {
        let root = root("a");
        let mut spool = Spool::create(&root, "one").unwrap();
        assert_eq!(spool.append(&[0.25, -0.5, 1.]).unwrap(), 3);
        let mut reader = spool.reader().unwrap();
        assert_eq!(reader.read(1, 2).unwrap(), [-0.5, 1.]);
        assert!(reader.read(2, 2).is_err(), "not written yet");
        spool.samples = MAX_SAMPLES - 1;
        assert_eq!(spool.append(&[0.; 5]).unwrap(), 1, "stops at 180 s");
        assert_eq!(spool.append(&[0.; 5]).unwrap(), 0);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(fs::metadata(spool.path()).unwrap().permissions().mode() & 0o777, 0o600);
            assert_eq!(fs::metadata(root.join("one")).unwrap().permissions().mode() & 0o777, 0o700);
        }
        assert!(Spool::create(&root, "one").is_err(), "one spool per session");
        spool.remove().unwrap();
        assert!(!root.join("one").exists());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn launch_removes_what_a_crash_left() {
        let root = root("b");
        let spool = Spool::create(&root, "crashed").unwrap();
        drop(spool);
        remove_stale(&root).unwrap();
        assert!(!root.exists());
        remove_stale(&root).unwrap();
    }
}
