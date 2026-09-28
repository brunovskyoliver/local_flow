# Enrollment and approval (T051), provisional run

Run on 2026-09-28. **Provisional:** the server ran on the owner's M5, not the Mac mini, behind a Cloudflare quick tunnel (`*.trycloudflare.com`, no account), with Google sign-in only. T051 stays open until it is repeated on the Mac mini with the permanent hostname. Steps 1–5 passed; step 6 was not run.

## Conditions

- Hardware: Mac17,2, Apple M5, 32 GB, macOS 27.0 (26A428). The client and server ran on the same Mac; traffic went out through the tunnel (edge `arn07`, QUIC) and back.
- Server: `scripts/install-remote-server.sh --dev --google-client-id <dev client>`, flowd 0.3.0, speech worker Parakeet TDT 0.6B v3 CoreML with the CTC 110M booster, server-owned MTPLX serving Qwen3.5 4B Speed on 127.0.0.1:18092.
- Client: `LocalFlow Dev.app` from branch `t3code/remote-dictation` (uncommitted), Google iOS OAuth client for `org.localflow.LocalFlow.dev`, no Sign in with Apple entitlement.
- Server identity fingerprint `60e4-4caa-76d1-2986-4727-bd5b-ea3d-a8cf`, identical from `flowd admin identity`, `/v1/remote/identity` through the tunnel, and the app's pinned value.

## Results

| Step | Expected | Observed |
| --- | --- | --- |
| 1 Consent | sheet names the server and the data sent | shown; owner confirmed |
| 2 Server address | fingerprint matches §3 | matches |
| 3 Sign in with Google | "Waiting for approval"; user and device pending | as expected; `flowd admin list`: user 1 google pending, device 1 "MacBook Pro" pending |
| 4 Dictate while pending | local recognition, label "Local", no error | `recognition_path=local`, no server failure; server log `op=refresh code=not_approved`; rewrite went to the local endpoint only |
| 5 Approve, dictate without restarting | "Server" | first dictation after approval: `local` (its background refresh returned `ok`; see note); second: `server`, 1 window of 192,000 samples, rewrite over the channel succeeded |
| 6 Turn off, credentials removed | Keychain empty, history intact | not run; the enrollment is kept for §5 |

Note on step 5: a pending device refreshes in the background at dictation start, and the result applies from the next dictation. Quickstart §4 step 5 now says so.

## Single-run timings (not SC measurements)

From the server log and the dev history for the one server dictation:

- Recognition after release: 1,496 ms for one 12.0 s window. The dictation was shorter than a 15 s window, so the whole clip was recognized after release, and the worker had just woken (`worker_runtime=active`).
- Rewrite over the channel: 1,125 ms in the client; server backend 973 ms, first token 629 ms. The server MTPLX shared the M5 with two other loaded 4B models.
- Whole server session: 14,836 ms including recording.

SC-001 and SC-002 still need T093 and T087 on the Mac mini.

## Defects found and fixed during this run

- **Crash on Google sign-in.** `SystemIdentitySignIn.googleSignIn` passed a completion closure that inherited `@MainActor`; AuthenticationServices calls it on an XPC queue, and the executor check trapped (`EXC_BREAKPOINT` in `_swift_task_checkIsolatedSwift`). The closure is now `@Sendable`, and a failed session logs its error domain and code only.
- **Installer.** It now passes the sign-in audiences, runs the server's own MTPLX with a generated key (handed to flowd by a wrapper, never through a plist), asks for model `localflow`, discards MTPLX stdout (it prints its key in a browser URL), waits out the `launchctl bootout` race, and never copies an installed worker onto itself.
