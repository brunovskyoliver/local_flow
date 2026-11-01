//! Copies the Swift Mac app's data into this client's folder. The source is only read, so the Swift
//! app keeps working, even while it runs. Keychain items don't move: a device pairs again, and an
//! API key is entered again. Waiting dictations stay with Swift, or both apps would send them.
use crate::db::Db;
use crate::prefs::Prefs;
use serde_json::{Map, Value};
use std::path::Path;

const SKIPPED_TABLES: [&str; 2] = ["grdb_migrations", "pending_remote_dictations"];
const MARKER: &str = ".imported-from-swift";

#[derive(Debug, Default, PartialEq, Eq)]
pub struct Imported {
    pub transcriptions: i64,
    pub meetings: i64,
    pub files: u64,
}

impl Imported {
    pub fn summary(&self) -> String {
        format!("{} dictations and {} meetings are here.", self.transcriptions, self.meetings)
    }
}

/// Runs once per data folder, on first launch. `None` when there's nothing to do.
pub fn first_launch(db: &Db, prefs: &mut Prefs, swift_root: &Path, own_root: &Path, swift_prefs: Option<Map<String, Value>>) -> Option<Result<Imported, String>> {
    let marker = own_root.join(MARKER);
    if marker.exists() || !swift_root.join("history.sqlite").is_file() {
        return None;
    }
    let result = import(db, swift_root, own_root);
    if result.is_ok() {
        if let Some(values) = swift_prefs {
            prefs.merge_missing(keep_prefs(values));
        }
        let _ = std::fs::write(marker, b"");
    }
    Some(result)
}

/// Adds what this folder lacks: rows by primary key, files by name and size. Safe to run again; a row
/// both apps hold keeps this client's copy.
pub fn import(db: &Db, swift_root: &Path, own_root: &Path) -> Result<Imported, String> {
    let files = copy_files(&swift_root.join("Meetings"), &own_root.join("Meetings")).map_err(|e| e.to_string())?;
    let mut counts = merge_rows(db, &swift_root.join("history.sqlite")).map_err(|e| e.to_string())?;
    counts.files = files;
    Ok(counts)
}

/// `file:` URI for a read-only attach; a plain path has no way to say read-only.
fn read_only_uri(path: &Path) -> String {
    let mut uri = String::from("file:");
    for b in path.to_string_lossy().bytes() {
        match b {
            b'a'..=b'z' | b'A'..=b'Z' | b'0'..=b'9' | b'/' | b'.' | b'-' | b'_' => uri.push(b as char),
            _ => uri.push_str(&format!("%{b:02X}")),
        }
    }
    uri + "?mode=ro"
}

/// One transaction, so one consistent snapshot of the source, even in WAL mode with Swift writing, and
/// all or nothing here. Only columns both sides have: an older or newer Swift schema still imports.
fn merge_rows(db: &Db, source: &Path) -> rusqlite::Result<Imported> {
    let conn = &db.conn;
    conn.execute("ATTACH DATABASE ? AS swift", [read_only_uri(source)])?;
    let merged = (|| {
        conn.execute_batch("BEGIN IMMEDIATE; PRAGMA defer_foreign_keys = ON;")?;
        let copied = (|| {
            let names = |sql: &str, arg: &str| -> rusqlite::Result<Vec<String>> { conn.prepare(sql)?.query_map([arg], |r| r.get(0))?.collect() };
            let tables = names("SELECT name FROM main.sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name <> ?", SKIPPED_TABLES[0])?;
            for table in tables.iter().filter(|t| !SKIPPED_TABLES.contains(&t.as_str())) {
                let ours = names("SELECT name FROM pragma_table_info(?, 'main')", table)?;
                let theirs = names("SELECT name FROM pragma_table_info(?, 'swift')", table)?;
                let shared: Vec<String> = ours.iter().filter(|c| theirs.contains(c)).map(|c| format!("\"{}\"", c.replace('"', "\"\""))).collect();
                if shared.is_empty() {
                    continue;
                }
                let (quoted, columns) = (format!("\"{}\"", table.replace('"', "\"\"")), shared.join(","));
                conn.execute(&format!("INSERT OR IGNORE INTO main.{quoted} ({columns}) SELECT {columns} FROM swift.{quoted}"), [])?;
            }
            let count = |table: &str| conn.query_row(&format!("SELECT count(*) FROM main.{table}"), [], |r| r.get(0));
            Ok(Imported { transcriptions: count("transcriptions")?, meetings: count("meetings")?, files: 0 })
        })();
        match copied {
            Ok(counts) => conn.execute_batch("COMMIT").map(|_| counts),
            Err(e) => {
                let _ = conn.execute_batch("ROLLBACK");
                Err(e)
            }
        }
    })();
    if merged.is_err() {
        // A refused COMMIT leaves the transaction open.
        let _ = conn.execute_batch("ROLLBACK");
    }
    conn.execute_batch("DETACH DATABASE swift")?;
    merged
}

/// Adds each model the Swift app has and this folder lacks, under a temporary name until it's whole.
/// APFS clones share their blocks, so this takes no second copy of the space. Dot-names are locks,
/// fingerprints and the Swift app's unfinished downloads. The worker still hashes what lands here.
pub fn clone_models(from: &Path, to: &Path) -> std::io::Result<u64> {
    let Ok(entries) = std::fs::read_dir(from) else { return Ok(0) };
    let mut cloned = 0;
    for entry in entries {
        let entry = entry?;
        let name = entry.file_name();
        let target = to.join(&name);
        if !entry.file_type()?.is_dir() || name.to_string_lossy().starts_with('.') || target.exists() {
            continue;
        }
        let stage = to.join(format!(".{}.cloning", name.to_string_lossy()));
        let _ = std::fs::remove_dir_all(&stage);
        copy_files(&entry.path(), &stage)?;
        std::fs::rename(&stage, &target)?;
        cloned += 1;
    }
    Ok(cloned)
}

/// `fs::copy` clones on APFS, so meeting audio takes no second copy of its space on the Mac's own disk.
fn copy_files(from: &Path, to: &Path) -> std::io::Result<u64> {
    let Ok(entries) = std::fs::read_dir(from) else { return Ok(0) };
    std::fs::create_dir_all(to)?;
    let mut copied = 0;
    for entry in entries {
        let entry = entry?;
        let (kind, target) = (entry.file_type()?, to.join(entry.file_name()));
        if kind.is_dir() {
            copied += copy_files(&entry.path(), &target)?;
        } else if kind.is_file() {
            let same = std::fs::metadata(&target).is_ok_and(|m| m.len() == entry.metadata().map_or(u64::MAX, |s| s.len()));
            if !same {
                // Through a temporary name: a crash can't leave half a file under the real one.
                let partial = target.with_extension("importing");
                std::fs::copy(entry.path(), &partial)?;
                std::fs::rename(&partial, &target)?;
                copied += 1;
            }
        }
    }
    Ok(copied)
}

/// The Swift app's settings, without the system's own keys or a server state only its Keychain items
/// back. The address stays so the pairing form opens filled in.
fn keep_prefs(values: Map<String, Value>) -> Map<String, Value> {
    values
        .into_iter()
        .filter(|(key, _)| {
            let system = ["NS", "Apple", "SU", "com.apple", "WebKit", "AK"].iter().any(|p| key.starts_with(p));
            let server_state = (key.starts_with("remote.") && key != "remote.serverURL" && key != "remote.fallbackThresholdMs") || key == "server.capabilities" || key.starts_with("serverMode.");
            !system && !server_state
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn dirs(name: &str) -> (PathBuf, PathBuf) {
        let base = std::env::temp_dir().join(format!("lf migration {name} {}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let (swift, own) = (base.join("Swift's 100%"), base.join("own"));
        std::fs::create_dir_all(&swift).unwrap();
        std::fs::create_dir_all(&own).unwrap();
        (swift, own)
    }

    fn add_dictation(conn: &rusqlite::Connection, id: &str) {
        conn.execute("INSERT INTO transcriptions (id,text,created_at,delivery_state,recovery_state,quality,stop_reason) VALUES (?,'hello',1,'confirmed','resolved','complete','key_release')", [id]).unwrap();
    }

    fn swift_db(root: &Path) -> Db {
        let db = Db::open_or_create(&root.join("history.sqlite")).unwrap();
        add_dictation(&db.conn, "a");
        db.conn.execute("INSERT INTO pending_remote_dictations (id,audio_file,sample_count,created_at,next_attempt_at) VALUES ('p','p.f32',1,1,1)", []).unwrap();
        db
    }

    #[test]
    fn copies_rows_and_files_leaves_the_source_alone_and_can_run_again() {
        let (swift, own) = dirs("copy");
        let source = swift_db(&swift);
        drop(source);
        std::fs::create_dir_all(swift.join("Meetings/m1")).unwrap();
        std::fs::write(swift.join("Meetings/m1/mic.aac"), b"audio").unwrap();
        let before = std::fs::read(swift.join("history.sqlite")).unwrap();
        let db = Db::open_or_create(&own.join("history.sqlite")).unwrap();
        let first = import(&db, &swift, &own).unwrap();
        assert_eq!((first.transcriptions, first.files), (1, 1));
        assert_eq!(std::fs::read(own.join("Meetings/m1/mic.aac")).unwrap(), b"audio");
        assert_eq!(std::fs::read(swift.join("history.sqlite")).unwrap(), before, "the source isn't written");
        let waiting: i64 = db.conn.query_row("SELECT count(*) FROM pending_remote_dictations", [], |r| r.get(0)).unwrap();
        assert_eq!(waiting, 0, "waiting audio stays with Swift");
        let second = import(&db, &swift, &own).unwrap();
        assert_eq!((second.transcriptions, second.files), (1, 0));
        std::fs::remove_dir_all(swift.parent().unwrap()).unwrap();
    }

    #[test]
    fn reads_a_live_wal_database_and_a_differing_schema() {
        let (swift, own) = dirs("wal");
        let source = swift_db(&swift);
        source.conn.query_row("PRAGMA journal_mode = WAL", [], |_| Ok(())).unwrap();
        add_dictation(&source.conn, "only-in-wal");
        source.conn.execute_batch("ALTER TABLE transcriptions DROP COLUMN server_failure; DROP TABLE pending_remote_dictations; INSERT INTO grdb_migrations VALUES ('from-the-future');").unwrap();
        source.conn.execute_batch("BEGIN; INSERT INTO transcriptions (id,text,created_at,delivery_state,recovery_state,quality,stop_reason) VALUES ('uncommitted','x',1,'confirmed','resolved','complete','key_release')").unwrap();
        let db = Db::open_or_create(&own.join("history.sqlite")).unwrap();
        assert_eq!(import(&db, &swift, &own).unwrap().transcriptions, 2, "committed rows, including those still in the WAL");
        drop(source);
        std::fs::remove_dir_all(swift.parent().unwrap()).unwrap();
    }

    #[test]
    fn clone_models_adds_finished_models_and_leaves_the_source() {
        let (swift, own) = dirs("clone");
        let (from, to) = (swift.join("Models"), own.join("Models"));
        std::fs::create_dir_all(from.join("m/Inner.mlmodelc")).unwrap();
        std::fs::create_dir_all(from.join(".m2.staging")).unwrap();
        std::fs::write(from.join("m/Inner.mlmodelc/weights"), b"abc").unwrap();
        std::fs::write(from.join(".m.import.lock"), b"").unwrap();
        // A crash left half a clone; the next launch starts it over.
        std::fs::create_dir_all(to.join(".m.cloning")).unwrap();
        std::fs::write(to.join(".m.cloning/stale"), b"x").unwrap();
        assert_eq!(clone_models(&from, &to).unwrap(), 1);
        assert_eq!(std::fs::read(to.join("m/Inner.mlmodelc/weights")).unwrap(), b"abc");
        let names: Vec<_> = std::fs::read_dir(&to).unwrap().map(|e| e.unwrap().file_name()).collect();
        assert_eq!(names, ["m"]);
        // What this app already has stays as it is.
        std::fs::write(to.join("m/own"), b"y").unwrap();
        assert_eq!(clone_models(&from, &to).unwrap(), 0);
        assert!(to.join("m/own").exists());
        assert!(from.join("m/Inner.mlmodelc/weights").exists());
    }

    #[test]
    fn first_launch_runs_once_and_keeps_what_it_should() {
        let (swift, own) = dirs("once");
        drop(swift_db(&swift));
        let db = Db::open_or_create(&own.join("history.sqlite")).unwrap();
        let mut prefs = Prefs::memory();
        prefs.set("appearance", "dark");
        let values: Map<String, Value> = serde_json::from_str(r#"{"appearance":"light","speechModel":"parakeet-v3","NSWindow Frame":"x","remote.state":"approved","remote.enabled":true,"remote.serverURL":"https://s","server.only":true}"#).unwrap();
        assert!(first_launch(&db, &mut prefs, &swift, &own, Some(values)).unwrap().is_ok());
        assert_eq!(prefs.string("appearance").as_deref(), Some("dark"), "this client's own value stays");
        assert_eq!(prefs.string("speechModel").as_deref(), Some("parakeet-v3"));
        assert_eq!(prefs.string("remote.serverURL").as_deref(), Some("https://s"));
        assert!(!prefs.contains("NSWindow Frame") && !prefs.contains("remote.state") && !prefs.contains("remote.enabled"));
        assert!(first_launch(&db, &mut prefs, &swift, &own, None).is_none(), "once");
        std::fs::remove_dir_all(swift.parent().unwrap()).unwrap();
    }

    #[test]
    fn a_broken_source_changes_nothing_and_retries_next_launch() {
        let (swift, own) = dirs("broken");
        std::fs::write(swift.join("history.sqlite"), b"not a database, not a database, not a database").unwrap();
        let db = Db::open_or_create(&own.join("history.sqlite")).unwrap();
        let mut prefs = Prefs::memory();
        assert!(first_launch(&db, &mut prefs, &swift, &own, None).unwrap().is_err());
        assert!(!own.join(MARKER).exists());
        add_dictation(&db.conn, "still-works");
        std::fs::remove_dir_all(swift.parent().unwrap()).unwrap();
    }
}
