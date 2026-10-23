# Research decisions

Date: 2026-10-23. Source thread: `6afdfca4-73fd-4ddb-9754-022c2f400e45`.

- Decision: extend Feature 012, rather than add another field reader. Each new Mac dictation already captures fresh context. Existing irrelevant-context quality failures mean the actual rewrite model must be evaluated again. Alternatives: whole-field replacement or unbounded capture, rejected because the user chose new-text-only continuation. See [context research](research-context.md).
- Decision: Sparkle plus public GitHub release archives and a stable HTTPS feed. Existing release automation/Homebrew remain useful, but lack in-app updates and production notarization. A manual bootstrap is unavoidable for builds without an updater. See [updates research](research-updates.md), including current primary-source documentation and license review.
- Decision: durable opted-in usage aggregates, separate from operational metrics. Local activity is visible only from consented enrolled clients; server traffic cannot stand in for local usage. A separately hosted Go dashboard with SQLite avoids adding a platform database or embedded native web server. See [usage research](research-usage.md).
- Decision: use optional external collector scraping content-free operational counters. Avoid an analytics SDK in the app/server under constitution principle 5. Traces and a general Grafana deployment are deferred; owner usage and basic reliability views are the initial deliverable.

All three product clarifications were answered in this thread. Production credentials, owner login identity and host availability remain deployment prerequisites, not invented configuration values. Implementation must verify proposed Sparkle resource cap enforcement before enabling checks. No new benchmarks were performed.

Planning resolution: contracts/usage.md supersedes the usage research batch/row limits and epoch alternatives. Final design uses 100 rows/64 KiB, one combined local/remote row per day, monotonic device control epochs plus random grant IDs, 1,000 fixed coalesced control slots, all-epoch deletion and a bounded directory projection. Client attempt counts were removed; the server reliability view owns them.
