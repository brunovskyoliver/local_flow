# Prepare the owner usage dashboard

Feature 021 adds optional usage reporting from enrolled, opted-in Macs. `flowdash` is a separate Go process; it has no inference administration interface. No service has been hosted or published by this feature.

## Local build and fixture

From the repository root:

```sh
mkdir -p server/build
(cd server && go build -o build/flowdash ./cmd/flowdash)
(cd server && go test ./internal/usage ./internal/dashboard ./internal/observability ./internal/remote ./cmd/flowd)
```

For a disposable loopback browser fixture:

```sh
cd server
LOCALFLOW_DASHBOARD_FIXTURE=1 go test ./internal/dashboard -run '^TestBrowserFixture$' -v -count=1 -timeout=11m
```

Open the printed loopback URL. The test inserts a fixture session into a temporary database and exits after ten minutes; interrupt it earlier when finished. The production binary has no authentication bypass flag.

## Reviewable deployment prerequisites

Before deployment, choose an owner-operated host and HTTPS origin; configure a Google OAuth web client with that origin's `/callback` redirect; record the owner's exact Google subject and issuer `https://accounts.google.com`. The initial implementation supports Google browser login. Enrollment identity providers are unchanged. Login uses the existing signature/audience/nonce verifier plus an exact issuer and subject check, authorization-code PKCE and a one-use state cookie.

Use the secrets workflow to provision a private OAuth client-secret file and a separate installation-bound reporting credential, each mode 0600. The reporting credential must contain 32–512 bytes after surrounding whitespace is removed. Never place it in command-line arguments, source control, screenshots or chat. Use one installation UUID at both ends. The source's export credential authorizes only reporting ingestion and deletion-control polling, not owner login or inference administration.

The reviewed deployment command shape is:

```sh
server/build/flowdash \
  --database /absolute/private/path/reporting.sqlite \
  --listen 127.0.0.1:8094 \
  --tls-cert /absolute/private/path/cert.pem \
  --tls-key /absolute/private/path/key.pem \
  --base-url https://chosen-owner-host.example \
  --owner-subject OWNER_SUBJECT \
  --google-client-id GOOGLE_WEB_CLIENT_ID \
  --google-secret-file /absolute/private/path/google-secret \
  --installation-id INSTALLATION_UUID \
  --ingest-credential-file /absolute/private/path/reporting-credential
```

These uppercase labels describe configuration to supply, not usable credentials or a claim that hosting exists. The dashboard requires direct TLS. Do not put an untrusted TLS-terminating proxy in front of identity-linked reporting without a separate transport review. Session cookies are Secure, HttpOnly, SameSite=Lax, capped at ten sessions and eight hours. Anonymous users cannot see usage. Owner deletion requires a confirmation page and CSRF-protected POST.

On flowd, `--usage-export-config /absolute/private/path/usage-export.json` enables export. That file contains exactly these settings:

```json
{
  "endpoint": "https://chosen-owner-host.example/v1/ingest/usage",
  "allowed_host": "chosen-owner-host.example",
  "installation": "INSTALLATION_UUID",
  "credential_file": "/absolute/private/path/reporting-credential"
}
```

The endpoint must be HTTPS and its host must exactly match `allowed_host` (include the port if non-default). Redirects are refused. A malformed reporting database disables the usage capability only; malformed export configuration disables export only. Fixed, content-free log notices identify those conditions. Inference remains available. Omitting export configuration sends nothing to a dashboard.

## Data and failure behavior

Daily product totals include successfully saved dictations and successful captured audio duration, grouped by user and UTC day. Remote attempts and retries never inflate those totals. The dashboard paginates 100 user/day records and formats duration for people. Report freshness is separate from activity time. Partial coverage and pending deletion are visible.

Directory projection currently uses an installation-scoped opaque label such as `User 18b0e1a4`. It intentionally does not export the account store's display field because that field can contain an email. Custom name mapping is not implemented; distinguish users by their stable opaque label for now.

The exporter sends current consent/deletion controls before cumulative snapshots. One request runs at a time. Bodies and responses are capped at 64 KiB; snapshot batches contain at most 100 rows. Requests time out after 30 seconds, retrying after 30 seconds up to one hour. Conflicting/stale revisions are refused or ignored without adding counts twice.

Withdrawal, revocation and deletion propagate asynchronously. A report already in flight may land before its newer control. The client continues to show propagation pending until the dashboard acknowledges that control. Once applied, older epochs cannot recreate removed rows. Deleting a user's usage covers every retained epoch on every reporting device. Repeated delete requests do not advance the revision forever. Owner-originated deletion travels through a bounded reporting-only control queue; it never calls inference admin endpoints.

Source and dashboard cap reporting identity metadata at 100 users and 1,000 devices, including retained disabled slots; each user has at most ten slots. Aggregates are capped at 180,000 rows and the database at 128 MiB. Reserve another 129 MiB for SQLite's DELETE journal and filesystem overhead. Expired daily rows are purged at startup and hourly; queries exclude expired rows immediately. Disabled metadata slots retire after acknowledgment and the 90-day replay horizon. A reporting-capacity failure never rejects dictation or inference enrollment.

Backups are not implemented by this feature. Do not restore an old reporting database directly into service: restore the latest consent/deletion state first, apply retention, then resume ingestion. Retire backup copies within the declared retention policy. Production restore acceptance and hardware resource measurements remain separate gates.

## Optional private operational metrics

`flowd --metrics-listen 127.0.0.1:8095` enables `/metrics`; the default is disabled. Non-loopback addresses are refused. Metrics use fixed service labels, request/error counts, duration buckets, worker readiness, and bounded queue observations. They contain no user or device labels. They are operational observations, not exact usage accounting. Speech queue gauges are sampled every two seconds; request counts/durations derive from existing content-free completion log lines and inherit that format's limitations.

An owner-operated OpenTelemetry Collector may scrape locally:

```yaml
receivers:
  prometheus:
    config:
      scrape_configs:
        - job_name: localflow
          scrape_interval: 15s
          static_configs:
            - targets: ["127.0.0.1:8095"]
processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 64
    spike_limit_mib: 16
  batch:
    send_batch_size: 128
    send_batch_max_size: 256
exporters:
  debug:
    verbosity: basic
service:
  pipelines:
    metrics:
      receivers: [prometheus]
      processors: [memory_limiter, batch]
      exporters: [debug]
```

This is a local preparation example, not an installed collector or a remote exporter. Choose an owner-controlled destination separately. Collector failure has no effect on dictation. No OTel SDK or external analytics SDK is added to the clients or server.
