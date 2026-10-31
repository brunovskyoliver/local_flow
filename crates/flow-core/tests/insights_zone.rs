//! Its own test binary: it re-runs itself under another TZ, which flow-core's library code must not do.
#![allow(missing_docs)]
use flow_core::db::Db;
use flow_core::insights::load;

// parity: INS-101
/// SQLite reads the zone at process start, so the zone-dependent half runs in a child test.
#[test]
fn hours_bucket_by_local_time() {
    const ZONE: &str = "JST-9";
    if std::env::var("TZ").as_deref() != Ok(ZONE) {
        let exe = std::env::current_exe().unwrap();
        let status = std::process::Command::new(exe).args(["--exact", "hours_bucket_by_local_time"]).env("TZ", ZONE).stdout(std::process::Stdio::null()).status().unwrap();
        assert!(status.success());
        return;
    }
    let db = Db::memory();
    // 2026-01-15 00:30 UTC is 09:30 in this zone; a UTC bucket would say hour 0.
    let at = 1_768_437_000_000_i64;
    let row = |id: &str, text: &str, bundle: Option<&str>, at: i64| {
        db.conn.execute("INSERT INTO transcriptions (id,text,created_at,delivery_state,recovery_state,quality,stop_reason,target_bundle_id) VALUES (?,?,?,'not_attempted','needs_review','complete','key_release',?)", rusqlite::params![format!("00000000-0000-4000-8000-{id:0>12}"), text, at, bundle]).unwrap();
    };
    row("1", "one two three", Some("com.apple.mail"), at);
    row("2", "four five", Some("com.apple.mail"), at + 60_000);
    row("3", "six", Some(""), at + 120_000);
    row("4", "seven", None, at + 3_600_000);
    let i = load(&db).unwrap();
    assert_eq!(i.hours[9], 6, "words of the three rows at 09:xx");
    assert_eq!(i.hour_dictations[9], 3, "each counts once");
    assert_eq!((i.hours[0], i.hour_dictations[0]), (0, 0), "not the UTC hour");
    assert_eq!((i.hours[10], i.hour_dictations[10]), (1, 1));
    assert_eq!(i.hour_apps[9].get("com.apple.mail"), Some(&5), "words per bundle");
    assert_eq!(i.hour_apps[9].len(), 1, "an empty bundle adds none");
    assert!(i.hour_apps[10].is_empty(), "nor does a missing one");
}
