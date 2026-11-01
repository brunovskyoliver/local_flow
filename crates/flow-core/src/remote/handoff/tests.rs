use super::super::enrollment::Enrollment;
use super::super::transfer::{Entry, exchange};
use super::*;
use crate::prefs::Prefs;

const ID: &str = "6F3A1C52-8D47-4E19-9B21-0C7E5A2D4F10";
const OTHER: &str = "1B2C3D4E-0000-4000-8000-000000000001";
const SEED: &str = include_str!("../../../../../fixtures/handoff/meeting-seed.sql");
const PROCESSED: &str = include_str!("../../../../../fixtures/handoff/processed.sql");
const SWIFT_BUNDLE: &str = include_str!("../../../../../fixtures/handoff/swift-bundle.sql");
const SWIFT_MERGED: &str = include_str!("../../../../../fixtures/handoff/swift-merged.sql");

struct Rig {
    dir: PathBuf,
    database: PathBuf,
    root: PathBuf,
}
impl Drop for Rig {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn sql(text: &str, id: &str) -> String {
    text.replace("{ID}", id).replace("{OTHER}", OTHER)
}

fn rig_for(tag: &str, id: &str) -> Rig {
    let unique = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    let dir = std::env::temp_dir().join(format!("flow-handoff-{tag}-{}-{unique}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let (database, root) = (dir.join("db.sqlite"), dir.join("Meetings"));
    let db = Db::open_or_create(&database).unwrap();
    db.conn.execute_batch(&sql(SEED, id)).unwrap();
    std::fs::create_dir_all(root.join(id)).unwrap();
    std::fs::write(root.join(id).join("mic-0001.aac"), vec![1; 100_000]).unwrap();
    std::fs::write(root.join(id).join("system-0001.aac"), vec![2; 100_001]).unwrap();
    Rig { dir, database, root }
}
fn rig(tag: &str) -> Rig {
    rig_for(tag, ID)
}

impl Rig {
    fn db(&self) -> Db {
        Db::open(&self.database).unwrap()
    }
    fn one(&self, query: &str) -> String {
        self.db().conn.query_row(query, [], |r| Ok(format!("{:?}", r.get_ref(0)?))).unwrap()
    }
    fn audio_intact(&self, id: &str) -> bool {
        std::fs::metadata(self.root.join(id).join("mic-0001.aac")).is_ok_and(|m| m.len() == 100_000) && std::fs::metadata(self.root.join(id).join("system-0001.aac")).is_ok_and(|m| m.len() == 100_001)
    }
    fn handoff(&self, call: impl Fn(&Request) -> Result<Reply, Failure> + Send + Sync + 'static) -> Handoff {
        let mut h = Handoff::new(call, &self.database, &self.root);
        h.upload_retry = Duration::ZERO;
        h
    }
    fn staged(&self, id: &str) -> bool {
        self.dir.join("Handoff").join(id).join("bundle.sqlite").exists()
    }
}

/// The same text `HandoffBundleCrossCheckTests.dump` makes.
fn dump(conn: &Connection) -> String {
    let strings = |q: &str| -> Vec<String> { conn.prepare(q).unwrap().query_map([], |r| r.get(0)).unwrap().map(Result::unwrap).collect() };
    let mut out = String::new();
    for sql in strings("SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY type DESC, name") {
        out += &format!("{sql};\n");
    }
    for table in strings("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name") {
        let literals = column_names(conn, &table, "main").unwrap().iter().map(|c| format!("quote(\"{c}\")")).collect::<Vec<_>>().join(" || ', ' || ");
        for values in strings(&format!("SELECT {literals} FROM \"{table}\" ORDER BY 1")) {
            out += &format!("INSERT INTO \"{table}\" VALUES ({values});\n");
        }
    }
    out
}

fn assert_same(rust: &str, swift: &str, what: &str) {
    let (mut r, mut s): (Vec<_>, Vec<_>) = (rust.lines().collect(), swift.lines().collect());
    // Whole-text compare with a readable failure: which lines only one side has.
    r.retain(|l| !swift.lines().any(|o| o == *l));
    s.retain(|l| !rust.lines().any(|o| o == *l));
    assert!(r.is_empty() && s.is_empty(), "{what}\nonly Rust: {r:#?}\nonly Swift: {s:#?}");
    assert_eq!(rust, swift, "{what}: same lines in a different order");
}

// The bundle has to be what `MeetingHandoff.export` makes, table by table and column by column.
#[test]
fn the_bundle_is_the_one_swift_makes_for_the_same_meeting() {
    let r = rig("bundle");
    let bundle = r.dir.join("Handoff").join(ID).join("bundle.sqlite");
    let h = r.handoff(|_| Err(Failure::Refused));
    assert_eq!(h.export(ID, &bundle, "automatic"), Ok(true));
    let conn = Connection::open(&bundle).unwrap();
    assert_same(&dump(&conn), SWIFT_BUNDLE, "bundle.sqlite");
    assert!(!dump(&conn).contains(OTHER), "another meeting never travels");
    assert!(!bundle.with_file_name("staging.sqlite").exists());
}

// A Swift-made bundle, processed, merges here into the database Swift's own merge makes.
#[test]
fn merging_a_swift_made_bundle_gives_the_database_swifts_merge_gives() {
    let r = rig("merge");
    let result = r.dir.join("result.sqlite");
    let conn = Connection::open(&result).unwrap();
    conn.execute_batch(&format!("PRAGMA foreign_keys=OFF;{SWIFT_BUNDLE}{}", sql(PROCESSED, ID))).unwrap();
    drop(conn);
    let h = r.handoff(|_| Err(Failure::Refused));
    assert_eq!(h.merge(ID, &result), Ok(true));
    assert_same(&dump(&r.db().conn), SWIFT_MERGED, "merged database");
    assert_eq!(r.one("SELECT text_bytes FROM transcript_usage"), "Integer(93)", "70 kept, 5 replaced by 23");
    }

#[test]
fn a_result_that_isnt_final_merges_nothing() {
    let r = rig("notfinal");
    let result = r.dir.join("result.sqlite");
    drop(Db::open_or_create(&result).unwrap());
    let before = dump(&r.db().conn);
    let h = r.handoff(|_| Err(Failure::Refused));
    assert_eq!(h.merge(ID, &result), Err(Failure::Refused));
    assert_eq!(dump(&r.db().conn), before);
}

#[test]
fn a_running_or_labeled_meeting_isnt_exported() {
    let r = rig("eligible");
    let bundle = r.dir.join("b").join("bundle.sqlite");
    let h = r.handoff(|_| Err(Failure::Refused));
    r.db().conn.execute("UPDATE meetings SET state='recording' WHERE id=?1", [ID]).unwrap();
    assert_eq!(h.export(ID, &bundle, "automatic"), Ok(false));
    r.db().conn.execute("UPDATE meetings SET state='completed' WHERE id=?1", [ID]).unwrap();
    r.db().conn.execute_batch(&sql("INSERT INTO diarization_runs(id,meeting_id,transcript_pass_id,state,\"trigger\",in_room,engine,model_id,model_revision,model_manifest_hash,pipeline_version,created_at) VALUES('R','{ID}','p','running','automatic',0,'e','m','r','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','p',1);INSERT INTO meeting_diarization(meeting_id,current_run_id,updated_at) VALUES('{ID}','R',1);", ID)).unwrap();
    assert_eq!(h.export(ID, &bundle, "automatic"), Ok(false));
    assert!(!bundle.exists());
}

#[test]
fn stored_paths_stay_inside_the_root() {
    let root = Path::new("/r");
    assert_eq!(resolve(root, "a/b.aac"), Some(PathBuf::from("/r/a/b.aac")));
    let long = "a".repeat(256);
    for bad in ["", "/etc/passwd", "../x", "a/../b", "a/./b", "a//b", "a\0b", "a\\b", long.as_str()] {
        assert_eq!(resolve(root, bad), None, "{bad:?}");
    }
}

#[test]
fn waits_back_off_to_ten_minutes_and_an_answer_resets_them() {
    let (mut w, t) = (Waits::default(), Instant::now());
    assert!(w.due("a", t));
    for (attempt, seconds) in [30, 60, 120, 240, 480, 600, 600].into_iter().enumerate() {
        w.wait("a", None, t);
        assert!(!w.due("a", t + Duration::from_secs(seconds - 1)), "attempt {attempt}");
        assert!(w.due("a", t + Duration::from_secs(seconds)), "attempt {attempt}");
    }
    w.wait("a", Some(PROGRESS_EVERY), t);
    assert!(w.due("a", t + PROGRESS_EVERY));
    w.wait("a", None, t);
    assert!(!w.due("a", t + Duration::from_secs(29)), "a fixed interval resets the backoff");
    w.reachable(t);
    assert!(w.due("a", t));
    w.wait("a", None, t);
    w.remove("a");
    assert!(w.due("a", t));
}

fn prefs(pairs: &[(&str, &str)]) -> Prefs {
    let mut p = Prefs::memory();
    for (k, v) in pairs {
        p.set(k, *v);
    }
    p
}

#[test]
fn the_route_follows_the_servers_offer_and_the_settings() {
    assert_eq!(route(&prefs(&[])), Route::Off);
    assert_eq!(route(&prefs(&[("remote.state", "pending")])), Route::Wait);
    let mut only = prefs(&[]);
    only.set("server.only", true);
    assert_eq!(route(&only), Route::Wait);
}

/// A scripted server for what a real one can't be made to say on demand.
#[derive(Default)]
struct Fake {
    state: Mutex<Option<State>>,
    error: Mutex<Option<Failure>>,
    actions: Mutex<Vec<(Action, Option<String>)>>,
}
impl Fake {
    fn call(self: &Arc<Self>) -> impl Fn(&Request) -> Result<Reply, Failure> + Send + Sync + 'static {
        let fake = self.clone();
        move |r: &Request| {
            fake.actions.lock().unwrap().push((r.action, r.name.clone()));
            if let Some(e) = fake.error.lock().unwrap().clone() {
                return Err(e);
            }
            let state = *fake.state.lock().unwrap();
            match r.action {
                Action::List => Ok(Reply { meetings: Some(state.map(|state| Entry { meeting: ID.to_lowercase(), state, progress: Some(25), mine: true, copy: false, released: false }).into_iter().collect()), ..Reply::default() }),
                Action::Put => {
                    // Everything landed already: the server answers with the offset it was given.
                    let end = r.offset.unwrap() + r.data.as_ref().map_or(0, |d| d.len() as u64);
                    Ok(Reply { state: Some(State::Receiving), offset: Some(end), ..Reply::default() })
                }
                Action::Get => Err(Failure::Refused),
                _ => Ok(Reply { state: Some(State::Queued), ..Reply::default() }),
            }
        }
    }
    fn did(&self, action: Action) -> usize {
        self.actions.lock().unwrap().iter().filter(|a| a.0 == action).count()
    }
}

#[test]
fn the_step_machine_reads_the_servers_state_like_swifts() {
    let r = rig("states");
    let fake = Arc::new(Fake::default());
    let h = r.handoff(fake.call());
    // Not eligible and nothing staged: nothing is said to the server.
    assert_eq!(h.step(ID, false, "automatic"), Step::NotHandedOff);
    assert!(fake.actions.lock().unwrap().is_empty());
    // Missing: uploads the finalized segments only, the bundle last, then starts.
    assert_eq!(h.step(ID, true, "automatic"), Step::Waiting("queued".into()));
    assert_eq!(fake.did(Action::Start), 1);
    let names: Vec<String> = fake.actions.lock().unwrap().iter().filter_map(|a| a.1.clone()).collect();
    assert!(names.contains(&"mic-0001.aac".to_string()) && names.contains(&"system-0001.aac".to_string()));
    assert!(!names.contains(&"system-0002.aac".to_string()), "an unrecoverable segment stays home");
    assert_eq!(names.last().unwrap(), "bundle.sqlite");
    // A staged bundle continues even when no longer eligible.
    *fake.state.lock().unwrap() = Some(State::Queued);
    assert_eq!(h.step(ID, false, "automatic"), Step::Waiting("queued".into()));
    *fake.state.lock().unwrap() = Some(State::Processing);
    assert_eq!(h.step(ID, false, "automatic"), Step::Processing(Some(0.25)));
    // Failed: the server copy and the bundle go; the audio stays.
    *fake.state.lock().unwrap() = Some(State::Failed);
    assert_eq!(h.step(ID, false, "automatic"), Step::NotHandedOff);
    assert_eq!(fake.did(Action::Delete), 1);
    assert!(!r.staged(ID) && r.audio_intact(ID));
}

#[test]
fn errors_decide_between_waiting_forgetting_and_abandoning() {
    let r = rig("errors");
    let fake = Arc::new(Fake::default());
    let h = r.handoff(fake.call());
    for (failure, code) in [(Failure::Waiting("busy".into()), "busy"), (Failure::Waiting("unreachable".into()), "unreachable"), (Failure::ChecksumMismatch, "checksum_mismatch"), (Failure::Local, "unreachable")] {
        *fake.error.lock().unwrap() = Some(failure);
        assert_eq!(h.step(ID, true, "automatic"), Step::Waiting(code.into()));
        assert!(r.staged(ID), "stays staged for the retry");
    }
    *fake.error.lock().unwrap() = Some(Failure::NotOffered);
    assert_eq!(h.step(ID, true, "automatic"), Step::NotHandedOff);
    assert!(!r.staged(ID));
    assert_eq!(fake.did(Action::Delete), 0, "not offered: nobody to tell");

    *fake.error.lock().unwrap() = None;
    assert_eq!(h.step(ID, true, "automatic"), Step::Waiting("queued".into()));
    *fake.error.lock().unwrap() = Some(Failure::Refused);
    assert_eq!(h.step(ID, true, "automatic"), Step::NotHandedOff);
    assert!(!r.staged(ID) && r.audio_intact(ID));
    assert_eq!(fake.did(Action::Delete), 1);
}

#[test]
fn run_locally_and_a_deleted_meeting_abandon_the_server_copy() {
    let r = rig("local");
    let fake = Arc::new(Fake::default());
    let h = r.handoff(fake.call());
    h.step(ID, true, "automatic");
    r.db().conn.execute("UPDATE meetings SET run_locally=1 WHERE id=?1", [ID]).unwrap();
    assert_eq!(h.step(ID, false, "automatic"), Step::NotHandedOff);
    assert_eq!(fake.did(Action::Delete), 1);
    assert!(!r.staged(ID));
    r.db().conn.execute("UPDATE meetings SET run_locally=0 WHERE id=?1", [ID]).unwrap();
    h.step(ID, true, "automatic");
    h.meeting_will_delete(ID);
    assert_eq!(fake.did(Action::Delete), 2);
    assert!(!r.staged(ID));
    h.meeting_will_delete(ID);
    assert_eq!(fake.did(Action::Delete), 2, "nothing staged: nothing to delete");
}

fn plan(route: Route) -> Plan {
    Plan { route, offers: false, language: "automatic".into() }
}

#[test]
fn the_queue_waits_retries_and_gives_a_refused_meeting_back_to_retry() {
    let r = rig("queue");
    let fake = Arc::new(Fake::default());
    let mut q = Queue::new(Arc::new(r.handoff(fake.call())));
    let t = Instant::now();
    // Not routable yet: the row waits and nothing is sent.
    let tick = q.tick(&plan(Route::Wait), t).unwrap();
    assert!(tick.waiting.contains(ID));
    assert!(fake.actions.lock().unwrap().is_empty());
    // An unreachable server: stays waiting, with a backoff between tries.
    *fake.error.lock().unwrap() = Some(Failure::Waiting("unreachable".into()));
    assert!(q.tick(&plan(Route::Hand), t).unwrap().waiting.contains(ID));
    let tries = fake.did(Action::List);
    assert_eq!(tries, 1);
    q.tick(&plan(Route::Hand), t + Duration::from_secs(29)).unwrap();
    assert_eq!(fake.did(Action::List), tries, "not before its time");
    q.tick(&plan(Route::Hand), t + Duration::from_secs(30)).unwrap();
    assert_eq!(fake.did(Action::List), tries + 1);
    // Refused: the row fails with Retry, the audio stays, and Retry queues it again.
    *fake.error.lock().unwrap() = Some(Failure::Refused);
    let tick = q.tick(&plan(Route::Hand), t + Duration::from_secs(600)).unwrap();
    assert!(tick.changed && !tick.waiting.contains(ID));
    assert_eq!(r.one(&format!("SELECT failure_detail IS NOT NULL AND state='failed' FROM meeting_transcriptions WHERE meeting_id='{ID}'")), "Integer(1)");
    assert!(r.audio_intact(ID));
    assert_eq!(request_again(&r.db(), ID).unwrap(), 1);
    assert_eq!(pending(&r.db()).unwrap(), [ID]);
}

#[test]
fn with_no_server_route_a_pending_meeting_says_failed_but_a_staged_one_finishes() {
    let r = rig("off");
    let fake = Arc::new(Fake::default());
    let mut q = Queue::new(Arc::new(r.handoff(fake.call())));
    let t = Instant::now();
    q.tick(&plan(Route::Hand), t).unwrap();
    assert!(r.staged(ID));
    *fake.state.lock().unwrap() = Some(State::Queued);
    let tick = q.tick(&plan(Route::Off), t + Duration::from_secs(30)).unwrap();
    assert!(tick.waiting.contains(ID), "in flight whatever the route says");
    assert_eq!(r.one(&format!("SELECT state='pending' FROM meeting_transcriptions WHERE meeting_id='{ID}'")), "Integer(1)");

    let r = rig("off2");
    let mut q = Queue::new(Arc::new(r.handoff(fake.call())));
    let tick = q.tick(&plan(Route::Off), t).unwrap();
    assert!(tick.changed && tick.waiting.is_empty());
    assert_eq!(r.one(&format!("SELECT state='failed' FROM meeting_transcriptions WHERE meeting_id='{ID}'")), "Integer(1)");
}

/// T024: the real server on loopback, with the fake processor in the test overlay.
#[cfg(unix)]
mod flowd {
    use super::super::super::enrollment::flowd_tests::{client, token};
    use super::*;
    use crate::remote::enrollment::RemoteSettings;
    use crate::remote::pool::Pool;
    use crate::settings::test_flowd::Flowd;

    fn paired(f: &Arc<Flowd>) -> (Arc<Enrollment>, Arc<Pool>) {
        let (e, _) = client(f, &f.remote);
        e.pair(&token(f)).expect("pairs");
        let e = Arc::new(e);
        let pool = Arc::new(Enrollment::pool(&e));
        (e, pool)
    }

    fn call(pool: &Arc<Pool>) -> impl Fn(&Request) -> Result<Reply, Failure> + Send + Sync + 'static {
        let pool = pool.clone();
        move |r: &Request| exchange(&pool, r)
    }

    /// Steps until the meeting leaves the server's queue, recording what it passed through.
    fn run(h: &Handoff, id: &str) -> (Step, bool) {
        let by = Instant::now() + Duration::from_secs(30);
        let mut saw_progress = false;
        loop {
            match h.step(id, true, "automatic") {
                Step::Waiting(code) if code == "queued" => {}
                Step::Processing(p) => saw_progress |= p == Some(0.4),
                other => return (other, saw_progress),
            }
            assert!(Instant::now() < by, "stuck");
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    fn server_list(pool: &Pool) -> Vec<Entry> {
        exchange(pool, &Request::new(Action::List, None)).unwrap().meetings.unwrap()
    }

    #[test]
    fn a_meeting_goes_to_the_server_and_comes_back_merged_with_its_audio_kept() {
        let f = Arc::new(Flowd::start());
        let (e, pool) = paired(&f);
        assert!(e.capabilities().unwrap().ops.contains("handoff"), "a processor makes flowd offer it");
        let r = rig("e2e");
        let h = r.handoff(call(&pool));
        assert_eq!(run(&h, ID), (Step::Merged { labeled: true }, true));
        assert_eq!(r.one(&format!("SELECT state='final' AND segment_count=2 AND inference_path='server' FROM meeting_transcriptions WHERE meeting_id='{ID}'")), "Integer(1)");
        assert_eq!(r.one("SELECT count(*) FROM transcript_segments WHERE finality='final'"), "Integer(2)");
        assert_eq!(r.one(&format!("SELECT accepted_run_id IS NOT NULL FROM meeting_analysis WHERE meeting_id='{ID}'")), "Integer(1)");
        assert_eq!(r.one("SELECT text_bytes FROM transcript_usage"), "Integer(93)");
        assert!(r.audio_intact(ID), "the audio is the record");
        assert!(!r.dir.join("Handoff").join(ID).exists(), "nothing staged is left");
        assert!(server_list(&pool).is_empty(), "the server copy is deleted");
    }

    #[test]
    fn an_interrupted_upload_resumes_where_the_server_got_to() {
        let f = Arc::new(Flowd::start());
        let (_e, pool) = paired(&f);
        let r = rig("resume");
        let puts = Arc::new(Mutex::new(Vec::<(String, u64)>::new()));
        let budget = Arc::new(Mutex::new(3usize));
        let inner = call(&pool);
        let (p, b) = (puts.clone(), budget.clone());
        let h = r.handoff(move |req: &Request| {
            if req.action == Action::Put {
                let mut left = b.lock().unwrap();
                if *left == 0 {
                    return Err(Failure::Waiting("unreachable".into()));
                }
                *left -= 1;
                if req.data.is_some() {
                    p.lock().unwrap().push((req.name.clone().unwrap(), req.offset.unwrap()));
                }
            }
            inner(req)
        });
        assert_eq!(h.step(ID, true, "automatic"), Step::Waiting("unreachable".into()));
        assert!(r.staged(ID));
        let sent = puts.lock().unwrap().last().cloned().unwrap();
        *budget.lock().unwrap() = usize::MAX;
        puts.lock().unwrap().clear();
        assert_eq!(h.step(ID, true, "automatic"), Step::Waiting("queued".into()));
        assert_eq!(puts.lock().unwrap()[0], (sent.0, sent.1 + 48_000), "the next chunk, not the file again");
        assert_eq!(run(&h, ID).0, Step::Merged { labeled: true });
        assert!(r.audio_intact(ID));
    }

    #[test]
    fn offline_keeps_everything_and_finishes_when_the_server_is_back() {
        let f = Arc::new(Flowd::start());
        let (e, pool) = paired(&f);
        let r = rig("offline");
        let h = r.handoff(call(&pool));
        let online = e.settings();
        pool.close_parked();
        e.load(RemoteSettings { origin: Some(f.down.clone()), ..online.clone() });
        assert_eq!(h.step(ID, true, "automatic"), Step::Waiting("unreachable".into()));
        assert!(r.audio_intact(ID) && r.staged(ID));
        assert_eq!(r.one(&format!("SELECT state='pending' FROM meeting_transcriptions WHERE meeting_id='{ID}'")), "Integer(1)");
        e.load(online);
        assert_eq!(run(&h, ID).0, Step::Merged { labeled: true });
    }

    #[test]
    fn a_failed_worker_leaves_the_audio_and_no_server_copy() {
        let f = Arc::new(Flowd::start());
        let (_e, pool) = paired(&f);
        let r = rig("worker");
        r.db().conn.execute("UPDATE meetings SET title='worker fails' WHERE id=?1", [ID]).unwrap();
        let mut q = Queue::new(Arc::new(r.handoff(call(&pool))));
        let (mut t, by) = (Instant::now(), Instant::now() + Duration::from_secs(30));
        loop {
            let tick = q.tick(&plan(Route::Hand), t).unwrap();
            if !tick.waiting.contains(ID) {
                break;
            }
            assert!(Instant::now() < by, "stuck");
            t += Duration::from_secs(700);
            std::thread::sleep(Duration::from_millis(50));
        }
        assert_eq!(r.one(&format!("SELECT state='failed' FROM meeting_transcriptions WHERE meeting_id='{ID}'")), "Integer(1)");
        assert!(r.audio_intact(ID) && !r.staged(ID));
        assert!(server_list(&pool).is_empty());
    }

    #[test]
    fn a_refused_start_keeps_the_audio_and_drops_the_upload() {
        let f = Arc::new(Flowd::start());
        let (_e, pool) = paired(&f);
        let r = rig("refused");
        // No finished segment, so no AAC reaches the server and `start` is refused.
        r.db().conn.execute("UPDATE meeting_segments SET state='unrecoverable', failure_reason='file_missing'", []).unwrap();
        let h = r.handoff(call(&pool));
        assert_eq!(h.step(ID, true, "automatic"), Step::NotHandedOff);
        assert!(r.audio_intact(ID) && !r.staged(ID));
        assert!(server_list(&pool).is_empty());
    }

    #[test]
    fn a_revoked_device_keeps_waiting_with_its_audio_and_says_so() {
        let f = Arc::new(Flowd::start());
        let (e, pool) = paired(&f);
        let r = rig("revoked");
        let h = r.handoff(call(&pool));
        assert_eq!(h.step(ID, true, "automatic"), Step::Waiting("queued".into()));
        f.revoke_newest_device();
        let by = Instant::now() + Duration::from_secs(10);
        let _ = e.refresh_now();
        pool.close_parked();
        while e.settings().state != "revoked" && Instant::now() < by {
            let _ = e.refresh_now();
            std::thread::sleep(Duration::from_millis(50));
        }
        assert_eq!(e.settings().state, "revoked");
        assert!(matches!(h.step(ID, true, "automatic"), Step::Waiting(_)));
        assert!(r.audio_intact(ID) && r.staged(ID));
    }

    #[test]
    fn deleting_the_meeting_removes_the_server_copy() {
        let f = Arc::new(Flowd::start());
        let (_e, pool) = paired(&f);
        let r = rig("delete");
        let h = r.handoff(call(&pool));
        assert_eq!(h.step(ID, true, "automatic"), Step::Waiting("queued".into()));
        assert_eq!(server_list(&pool).len(), 1);
        h.meeting_will_delete(ID);
        assert!(server_list(&pool).is_empty());
        assert!(!r.staged(ID));
    }

    #[test]
    fn a_phone_meeting_reaches_this_device_once() {
        let f = Arc::new(Flowd::start());
        let (_e, pool) = paired(&f);
        let phone = rig("phone");
        let inner = call(&pool);
        let h = phone.handoff(move |r: &Request| {
            let mut r = r.clone();
            r.copy = matches!(r.action, Action::Put | Action::Start);
            // The phone keeps its copy here so the test can release before anything is deleted.
            if r.action == Action::Delete {
                return Ok(Reply { state: Some(State::Missing), ..Reply::default() });
            }
            inner(&r)
        });
        let mac = rig_for("mac", "2C3D4E5F-0000-4000-8000-000000000002");
        mac.db().conn.execute_batch("UPDATE transcript_usage SET text_bytes=0, segment_rows=0").unwrap();
        assert_eq!(run(&h, ID).0, Step::Merged { labeled: true });
        let released = exchange(&pool, &Request::new(Action::Release, Some(ID)));
        assert!(released.is_ok(), "{released:?}");
        let importer = mac.handoff(call(&pool));
        assert!(importer.import_phone_meetings().is_empty(), "this device's own upload isn't an import");
        f.hand_to_another_device(ID);
        assert_eq!(importer.import_phone_meetings(), [(ID.to_string(), true)]);
        assert!(mac.audio_intact(ID), "every finished segment arrived");
        assert_eq!(mac.one(&format!("SELECT origin='iphone' AND run_locally=0 FROM meetings WHERE id='{ID}'")), "Integer(1)");
        assert_eq!(mac.one("SELECT text_bytes FROM transcript_usage"), "Integer(23)");
        assert!(server_list(&pool).is_empty(), "the server copy goes once it's here");
        assert!(importer.import_phone_meetings().is_empty());
    }
}
