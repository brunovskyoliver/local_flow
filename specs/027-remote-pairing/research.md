# Research: Feature 027

T3 Code facts come from a source read of `pingdotgg/t3code` at `15fe2832` (nothing was run). LocalFlow facts come from this branch.

## R1. Token format

**Decision**: `lfp_` + base64url of 32-byte server public key ‖ 32 random bytes, 86 characters after the prefix. One-time. The stored form is SHA-256 of the full string, using the existing `HashToken`.
**Rationale**: Holding the token authenticates the server with no manual comparison and no trust in the route. 256 random bits make guessing irrelevant, so rate limits protect resources, not secrecy.
**Rejected**: T3 Code's 12-character code (typable, but about 60 bits, and needs no key because T3 has no pinning); a long-lived bearer (owner chose A; principle 15 forbids it).

## R2. Delivering a token

**Decision**: Text token alone, or an app link `localflow://pair?address=<origin>#token=<token>` (`localflow-dev` for development builds), also shown as a QR code from Core Image's `CIQRCodeGenerator`. iOS scans with the system Camera, which opens the link, so the app needs no camera permission or scanner.
**Rationale**: The fragment is T3 Code's pattern, and platform APIs need no dependency. The link spends nothing until the user confirms host and consent, also from T3 Code.

## R3. Redemption protocol

**Decision**: A new `pair` operation under the existing `enroll` hello purpose, signed with `localflow-v1-pair` ‖ binding by the device key, answered with the existing `enrolled` message. The client compares `/v1/remote/identity` with the token's key first, for a clear message, and in any case seals the hello to the token's key, so a wrong server can't read the token.
**Rationale**: Reuses the channel, limits, refresh lineage and revocation. An old server rejects the unknown message, which the client reports as "update the server" with the token unspent. `/v1/remote/identity` doesn't change.
**Lost replies**: The token row keeps the redeeming key. The same key retrying before expiry gets a new refresh lineage for its device; another key is refused.
**Errors**: One new code, `pairing_token_invalid`, for unknown, expired, used and revoked tokens. It occurs only on the `pair` operation, so old clients and the Rust client never see it.

## R4. Identity without OIDC

**Decision**: `users.provider` gains `token`; `subject` is `token:<token id>`; `display` is the label. Approval is implied by issuing, and the token row plus audit rows record who issued it. Sign-in paths don't change.

## R5. Database migration v3

**Decision**: Before migrating a v2 database, write `VACUUM INTO flowd-remote.pre-v3.sqlite` (0600). In one transaction, rebuild `users` and `audit` to widen their CHECK constraints, using `PRAGMA defer_foreign_keys=ON`, and create `pairing_tokens`.
**Rationale**: SQLite can't alter a CHECK. The copy gives a way back, because an older flowd refuses a newer schema (`ErrSchemaTooNew`). A fixture test proves that refresh and session work afterwards.

## R6. Binding and threat model

| Threat | Mitigation |
|---|---|
| Open port scanned | Only `identity` and `channel` routes are served; existing anonymous-channel, per-client and server-wide limits; `busy` on overload |
| Network or proxy reads traffic | HPKE channel to the pinned key, for token, audio and text. Metadata (timing, size, server public key) stays visible on `http://` and to any proxy |
| Wrong server at the address | Hello sealed to the token's key; the server can't open it; close 4001 → mismatch; token never exposed |
| Stolen unused token | One-time, expiry, revocable, audit row; the real holder sees it refused and tells the owner, who revokes the device |
| Stolen used token | Worthless |
| Stolen refresh token | Device-key signature is already required; reuse revokes the device |
| Database stolen | Hashes only; the identity key stays in Keychain |
| Spoofed `Cf-Connecting-Ip` | R7 |
| Admin reached remotely | No admin routes on the remote listener; main and admin stay on loopback; tokens carry no scope |

Default for new server mode: `0.0.0.0:8090`. `--remote-listen` accepts any IP literal, and existing plists keep theirs. `http://` follows FR-012a. No certificates are generated, because TLS adds nothing the channel doesn't already give beyond metadata. A proxy or Tailscale Serve provides it when wanted.

## R7. Client address behind proxies

**Decision**: Headers count only when the socket peer is loopback: `Cf-Connecting-Ip`, then the rightmost `X-Forwarded-For` entry. Otherwise the peer address is used.
**Ceiling**: A proxy on another host shares one bucket, 10 account hellos per minute. A `--trusted-proxy` flag can follow if that bites. A client behind a local proxy that doesn't overwrite these headers could choose its bucket; the server-wide cap of 60 per minute still holds.

## R8. Server mode on a Mac

**Decision**: Move what `scripts/install-remote-server.sh` does for agents into a `ServerModeController` in the app: copy helpers to `<data-dir>/bin`, `flowd admin init`, write the same `org.localflow.LocalFlow.remote` plist and bootstrap it. LocalFlow Server then manages it without change. `.dev` labels, ports 18090–18092 and the dev Keychain service are used in development builds. The app bundles `flowd-speech` with its FluidAudio resource bundle next to the existing `flowd` and Whisper helper in `Contents/Helpers`.
**Models**: Speech and meeting models download only after the owner confirms the download; until then the view lists those services as unavailable. An existing agent is adopted, not rewritten. Rewriting uses the existing `.remote.mtplx` agent when the app's LocalAI runtime exists, and is otherwise listed as unavailable.
**Ceiling**: The owner's local model and the server's model are separate runtimes on one Mac, by principle 3's single-owner rule. Memory for both is measured, not estimated.

## R9. App Transport Security and networking

The Mac app already sets `NSAllowsArbitraryLoads`. iOS has no ATS exception or Local Network text, so it gets `NSAllowsLocalNetworking`, a `ts.net` exception domain and `NSLocalNetworkUsageDescription`. **Not verified yet**: whether `ws://` to a private IP literal works under those keys on iOS. Task T032 tests this in the Simulator and records the result. If it is blocked, iOS stays `https://`-only for that address class and the spec records the exception.

**Result (T032, 2026-10-31).** `apps/ios/LocalFlowPhoneTests/TransportSecurityTests.swift`, run as an XCTest hosted by the app on the "iPhone 18 Pro" Simulator (iOS Simulator networking is the Mac's own stack).

Shown, with the ATS keys above in the test host's Info.plist:

- A `ws://` round trip of real binary frames through `URLSessionRemoteTransport` to a WebSocket listener in the test process, on `127.0.0.1` and on `localhost`.
- ATS verdicts from `http://` and `ws://` probes to port 9, where nothing listens. Control `ats-control.invalid`: -1022 for both, so ATS was on and blocking.
- Not blocked by ATS: `127.0.0.1` and `[::1]` (-1004 cannot connect), the Mac's own RFC 1918 address, 172.20.10.2 on this run (-1004), a `.local` name (-1001 timeout), a single-label name (-1003 host not found). The test skips the address row when the machine has no private IPv4 address.

These errors show that ATS let the request out. They don't show a server answering. The private-address probe never reached a listener, because binding one would raise a firewall prompt, so no WebSocket has completed on an RFC 1918 address. A loopback result doesn't prove RFC 1918 behaviour.

Not shown:

- Any real iPhone. The Simulator doesn't enforce Local Network privacy, so neither the prompt for `NSLocalNetworkUsageDescription` nor a device's behaviour after a refusal has been seen.
- `*.ts.net`: only the plist key is asserted. A live probe needs an external DNS lookup.
- `100.64.0.0/10`, `fd7a:115c:a1e0::/48`, other `fc00::/7` and `fe80::/10` literals, and the `10/8` and `192.168/16` ranges: no probe, because dialling them could send packets off this machine. Whether `NSAllowsLocalNetworking` covers Tailscale literals on iOS is open; a `ts.net` name is the covered route until a device test says otherwise.

Nothing above blocked a class, so the spec has no iOS exception so far. If a device test blocks one, iOS stays https-only for that class and the spec records it.

## R10. What T3 Code does differently on purpose

Kept from T3 Code: one-time code, fragment-carrying link, QR, confirmation before spending, device list, 0700/0600 secrets. Not copied: plaintext pairing codes, no pairing rate limit in the files read, identity check by unauthenticated environment ID, scopes, relay, route lists (owner chose one address).
