//! The Swift migrator owns the schema until cutover. This opens its database and refuses one
//! with migrations this build doesn't know, rather than risking a write against a newer schema.
use rusqlite::Connection;
use std::path::Path;

pub const SCHEMA: &str = include_str!("../schema/history-schema.sql");

pub fn known_migrations() -> Vec<&'static str> {
    SCHEMA
        .lines()
        .filter_map(|l| l.strip_prefix("INSERT INTO \"grdb_migrations\" VALUES ('")?.strip_suffix("');"))
        .collect()
}

#[derive(Debug)]
pub enum DbError {
    Sql(rusqlite::Error),
    /// The database was written by a newer app.
    UnknownMigration(String),
    /// Older than the Swift app this build matches, or not a LocalFlow database.
    MissingMigration(String),
}

impl std::fmt::Display for DbError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            DbError::Sql(e) => write!(f, "{e}"),
            DbError::UnknownMigration(m) => write!(f, "database has unknown migration {m}"),
            DbError::MissingMigration(m) => write!(f, "database lacks migration {m}"),
        }
    }
}
impl std::error::Error for DbError {}
impl From<rusqlite::Error> for DbError {
    fn from(e: rusqlite::Error) -> Self {
        DbError::Sql(e)
    }
}

pub struct Db {
    pub conn: Connection,
}

fn configure(conn: &Connection) -> Result<(), rusqlite::Error> {
    conn.execute_batch("PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;")
}

impl Db {
    pub fn open(path: &Path) -> Result<Db, DbError> {
        let conn = Connection::open(path)?;
        configure(&conn)?;
        let mut stmt = conn.prepare("SELECT identifier FROM grdb_migrations")?;
        let found: Vec<String> = stmt.query_map([], |r| r.get(0))?.collect::<Result<_, _>>()?;
        drop(stmt);
        let known = known_migrations();
        if let Some(m) = found.iter().find(|m| !known.contains(&m.as_str())) {
            return Err(DbError::UnknownMigration(m.clone()));
        }
        if let Some(m) = known.iter().find(|m| !found.iter().any(|f| f == *m)) {
            return Err(DbError::MissingMigration(m.to_string()));
        }
        Ok(Db { conn })
    }

    /// Creates the file from the Swift-made schema when it doesn't exist yet.
    pub fn open_or_create(path: &Path) -> Result<Db, DbError> {
        if !path.exists() {
            if let Some(dir) = path.parent() {
                let _ = std::fs::create_dir_all(dir);
            }
            let conn = Connection::open(path)?;
            create(&conn)?;
        }
        Db::open(path)
    }

    /// An in-memory database with the real schema, for tests.
    pub fn memory() -> Db {
        let conn = Connection::open_in_memory().expect("in-memory sqlite");
        configure(&conn).expect("pragmas");
        create(&conn).expect("schema loads");
        Db { conn }
    }
}

fn create(conn: &Connection) -> Result<(), rusqlite::Error> {
    conn.execute_batch("PRAGMA foreign_keys = OFF; BEGIN;")?;
    conn.execute_batch(SCHEMA)?;
    conn.execute_batch("COMMIT; PRAGMA foreign_keys = ON;")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schema_has_every_swift_migration_and_refuses_unknown_ones() {
        let db = Db::memory();
        let n: i64 = db.conn.query_row("SELECT count(*) FROM grdb_migrations", [], |r| r.get(0)).unwrap();
        assert_eq!(n as usize, known_migrations().len());
        assert!(known_migrations().contains(&"usage-reporting-v21"));
        let dir = std::env::temp_dir().join(format!("flow-db-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("h.sqlite");
        let made = Db::open_or_create(&path).unwrap();
        made.conn.execute("INSERT INTO grdb_migrations VALUES ('from-the-future')", []).unwrap();
        drop(made);
        assert!(matches!(Db::open(&path), Err(DbError::UnknownMigration(_))));
        std::fs::remove_dir_all(dir).unwrap();
    }
}
