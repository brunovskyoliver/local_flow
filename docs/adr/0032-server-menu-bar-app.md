# 0032: LocalFlow Server, a menu bar app that manages the server

## Status

Proposed, 2026-10-01. Records an exception to "one native macOS app" (AGENTS.md, ADR 0001, ADR 0029).

## Context

The LocalFlow server on the Mac mini is two launch agents (`org.localflow.LocalFlow.remote` for flowd, `.remote.mtplx` for the rewrite model), a data directory and a log. Today the owner manages it over SSH: `launchctl`, `tail`, `curl` against the health endpoints, and `flowd admin`. `flowd admin` needs the identity key in the login Keychain, which is locked over SSH, so approving a device means running the command in the GUI session. The mini also runs oMLX, which has its own dashboard; flowd has none.

## Decision

A second macOS app, **LocalFlow Server** (`apps/macos/LocalFlowServer`, target `LocalFlowServer`, bundle ID `org.localflow.LocalFlow.server`), in the existing Xcode project. It runs on the server Mac as a menu bar extra with one window.

It may:

- read `launchctl print` for the two agents, flowd's loopback health endpoints (127.0.0.1:8091) and oMLX's `/v1/models` (127.0.0.1:8443);
- read flowd's log (`flowd.log`, `flowd.log.1`) and keep request counts, durations, result codes and the answering model per day in its own SQLite file (GRDB, already a project dependency), ingested by file offset and inode;
- read per-process memory (`proc_pid_rusage`), uptime and swap;
- run `launchctl kickstart -k`, `bootout` and `bootstrap` for those two labels only, and `flowd admin` list, audit, approve, reject and revoke, through `Process` with absolute paths and no shell;
- edit `ProgramArguments` of the two agents' plists to change the rewrite model or the summaries backend, keeping the previous plist and restoring it if the agent is not healthy within 60 s;
- write `<data-dir>/analysis-api-key` (0600) from oMLX's settings when the owner chooses oMLX for summaries.

It may not:

- load models, run inference, or open any listener;
- read, display, store or log audio, transcripts, prompts or results; it shows only flowd's content-free `key=value` lines;
- display, log or store API keys or tokens (it reads oMLX's key into memory to list models and copies it to the 0600 key file flowd already reads);
- touch the client app's agents (`org.localflow.LocalFlow[.dev].flowd`, `.mtplx`) or the client app's behaviour;
- rebuild oMLX's dashboard; it links to it.

The app shares no code with the client app. LocalFlowCore holds client storage and speech code; the server app needs neither.

## Constitution check

- **1 Native client**: Swift, SwiftUI and AppKit only (`MenuBarExtra`, `Window`). No web view, no embedded web server, no Python or Node.
- **2 Memory**: the log view keeps at most 5,000 lines; the stats file drops rows older than 90 days. Resident size is not yet measured.
- **3, 8 Model lifecycle, server isolation**: flowd stays the server and the only owner of its workers. The app observes and restarts agents; it owns no runtime.
- **5 Privacy**: see "may not". The stats file holds service, duration, code and model id per request.
- **7 Persistence**: SQLite through GRDB with one migration.
- **14 Scope**: one window, five tabs, no plugin system. The loopback admin API in flowd (live counters, switching the summaries backend without a restart) comes only after the log-based app works, and stays 127.0.0.1-only, behind a bearer token from a 0600 file, never on the remote listener.
- **15 Server access**: approval and revocation still go through the same `flowd admin` code paths and audit rows.

## Consequences

- The repository has two macOS apps. AGENTS.md's "one native macOS app" refers to the client; this ADR is the exception.
- The app is built on a Mac with Xcode and copied to the server; the mini has only Command Line Tools. It is ad-hoc signed until an App ID is registered.
- A change to flowd's log format can break the parser; unknown lines are shown raw and are not counted.

## Alternatives considered

- **Keep SSH and scripts**: the Keychain lock makes `flowd admin` awkward, and there is no live view.
- **A web dashboard served by flowd**: the constitution forbids embedded UI web servers, and it would put an admin surface on a process that serves remote users.
- **A settings pane in the client app**: the client runs on the owner's laptop, not on the server, and must not gain server-admin powers.
