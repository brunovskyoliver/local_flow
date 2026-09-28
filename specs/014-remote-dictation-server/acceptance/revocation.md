# Revocation within one second (SC-007): server logic on loopback

**Scope.** This is a local loopback measurement of flowd's revocation logic. It is not an end-to-end measurement through Cloudflare Tunnel: no tunnel, no network and no macOS client were involved, and the clients were Go test clients on the same machine. It shows that the server side (the admin write, the 250 ms `data_version` poll, the snapshot reload, the sealed `error{code:"revoked"}` and the channel close) fits inside the SC-007 bound with room left for the tunnel. The end-to-end figure still needs quickstart on the Mac mini.

## Result

| Item | Value |
| --- | --- |
| Test | `TestRevocationAcceptance50` in `server/internal/remote/revocation_acceptance_test.go`, run with `go test -tags localflow_acceptance -run TestRevocationAcceptance50` from `server/`. The package's in-progress `dictation*`, `rewrite*` and `isolation*` files (User Story 1, another workstream) did not compile yet, so the run listed the package's other files explicitly |
| Trials | 50, alternating device revocation (25) and user revocation (25) |
| Within 1 s | 50 of 50 |
| Close latency, median | 126.6 ms |
| Close latency, maximum | 232.7 ms |
| Minimum | 2.6 ms |
| Date | 2026-09-27 22:45 CEST |
| Machine | Apple M5 (`sysctl -n machdep.cpu.brand_string`), 34,359,738,368 bytes = 32 GiB (`sysctl -n hw.memsize`), macOS 27.0 |
| Go | go1.26.0 darwin/arm64 |
| Tree | `t3code/remote-dictation` at `e39e86c` plus uncommitted Feature 014 work |

## What one trial does

1. A fresh `flowd serve` stand-in: the account store, the watcher polling `PRAGMA data_version` every 250 ms on a real `time.Ticker`, its callback wired to `Listener.Revoke`, and the listener on the system clock behind `httptest`.
2. User A has device A1 with two session channels, one idle and one mid-dictation (a `dictation_start` accepted, audio frames streaming every 10 ms), and device A2 with one channel. User B has one channel.
3. After a random delay of 0 to 250 ms, so the revocation lands at a uniformly random phase of the poll, a second store connection (standing in for `flowd admin`) revokes A1 (device trials) or A (user trials).
4. Latency runs from just before the admin call to the moment the last affected client reads the close. Every affected channel must first receive the sealed `error{code:"revoked"}`, and the streaming channel's error carries its `op`.
5. The trial then checks that B's channel still answers (and, in device trials, A2's), that A1's next refresh fails, and that A1 (and in user trials A2) is refused at hello with `revoked`.

The latency spread matches the design: up to one poll interval (250 ms) plus the reload and close, which take a few milliseconds on loopback.

## Also checked in the normal test run

- `TestRevocationClosesChannelsWithinOneSecond`: 3 trials of the above in every `go test ./...`.
- `TestRevocationClosesUnwritableChannel`: a client that stopped reading while an operation is blocked sending. The channel is dropped about 0.5 s after the admin call (poll plus the 300 ms grace for the sealed error), not after the 10 s write timeout.
