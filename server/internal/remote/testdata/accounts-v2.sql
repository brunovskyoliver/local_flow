-- The account store as a v2 flowd left it; frozen for the upgrade test (Feature 027 T021).
CREATE TABLE users (
  id INTEGER PRIMARY KEY,
  provider TEXT NOT NULL CHECK (provider IN ('apple', 'google')),
  subject TEXT NOT NULL CHECK (length(CAST(subject AS BLOB)) BETWEEN 1 AND 255),
  display TEXT CHECK (display IS NULL OR length(CAST(display AS BLOB)) <= 320),
  state TEXT NOT NULL CHECK (state IN ('pending', 'approved', 'rejected', 'revoked')),
  created_at INTEGER NOT NULL,
  changed_at INTEGER NOT NULL,
  UNIQUE (provider, subject)
);
CREATE TABLE devices (
  id INTEGER PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id),
  name TEXT NOT NULL CHECK (length(CAST(name AS BLOB)) BETWEEN 1 AND 64),
  public_key BLOB NOT NULL UNIQUE CHECK (length(public_key) = 65 AND substr(public_key, 1, 1) = x'04'),
  state TEXT NOT NULL CHECK (state IN ('pending', 'approved', 'revoked')),
  refresh_hash BLOB CHECK (refresh_hash IS NULL OR length(refresh_hash) = 32),
  previous_refresh_hash BLOB CHECK (previous_refresh_hash IS NULL OR length(previous_refresh_hash) = 32),
  refresh_expires_at INTEGER,
  access_hash BLOB CHECK (access_hash IS NULL OR length(access_hash) = 32),
  access_expires_at INTEGER,
  enrolled_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL,
  changed_at INTEGER NOT NULL
);
CREATE INDEX devices_user ON devices(user_id);
CREATE UNIQUE INDEX devices_refresh ON devices(refresh_hash) WHERE refresh_hash IS NOT NULL;
CREATE INDEX devices_previous_refresh ON devices(previous_refresh_hash) WHERE previous_refresh_hash IS NOT NULL;
CREATE TABLE audit (
  id INTEGER PRIMARY KEY,
  at INTEGER NOT NULL,
  actor TEXT NOT NULL CHECK (
    actor = 'system'
    OR (actor GLOB 'admin:?*' AND length(actor) <= 70)
    OR (actor GLOB 'user:[0-9]*' AND substr(actor, 6) NOT GLOB '*[^0-9]*')
    OR (actor GLOB 'device:[0-9]*' AND substr(actor, 8) NOT GLOB '*[^0-9]*')),
  action TEXT NOT NULL CHECK (action IN ('sign_in', 'enroll', 'approve', 'reject', 'revoke', 'refresh',
    'refresh_reuse', 'cross_user_attempt', 'rate_limited', 'pin_rejected')),
  target TEXT CHECK (target IS NULL
    OR (target GLOB 'user:[0-9]*' AND substr(target, 6) NOT GLOB '*[^0-9]*')
    OR (target GLOB 'device:[0-9]*' AND substr(target, 8) NOT GLOB '*[^0-9]*')),
  outcome TEXT NOT NULL CHECK (outcome IN ('ok', 'unauthorized', 'token_expired', 'not_approved', 'revoked',
    'busy', 'invalid_message', 'unsupported_version', 'limit_exceeded', 'worker_unavailable', 'internal'))
);
PRAGMA user_version = 1;
ALTER TABLE devices ADD COLUMN revoked_access_hash BLOB
  CHECK (revoked_access_hash IS NULL OR length(revoked_access_hash) = 32);
ALTER TABLE devices ADD COLUMN revoked_refresh_hash BLOB
  CHECK (revoked_refresh_hash IS NULL OR length(revoked_refresh_hash) = 32);
ALTER TABLE devices ADD COLUMN revoked_previous_refresh_hash BLOB
  CHECK (revoked_previous_refresh_hash IS NULL OR length(revoked_previous_refresh_hash) = 32);
CREATE INDEX devices_revoked_refresh ON devices(revoked_refresh_hash) WHERE revoked_refresh_hash IS NOT NULL;
CREATE INDEX devices_revoked_previous_refresh ON devices(revoked_previous_refresh_hash) WHERE revoked_previous_refresh_hash IS NOT NULL;
PRAGMA user_version = 2;
