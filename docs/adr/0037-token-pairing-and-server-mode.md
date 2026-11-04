# 0037: Token pairing, any route, and server mode in the client app

## Status

Accepted by the owner, 2026-10-31 (Feature 027, gate 2). Amends the constitution to 5.0.0, ADR 0028 and ADR 0032. Hardware acceptance and resource measurements are still to be collected.

## Context

A LocalFlow server can only be reached through Sign in with Apple or Google followed by `flowd admin approve`, on a listener bound to loopback and published by a tunnel. A server therefore depends on a provider's sign-in configuration and on app builds that carry it, and each new device needs an administrator at the server Mac after it enrolls. Setting a server up takes `scripts/install-remote-server.sh` and SSH.

The owner wants any Mac install to become a server from the app, to hand each person or device a token, and to connect over whatever route exists: LAN, Tailscale or a proxy. T3 Code does something similar with a one-time code and a link; research R10 lists what is kept from it and what isn't.

Constitution principle 15 allows identity only from an OIDC provider. ADR 0032 says the client "must not gain server-admin powers".

## Decision

- **One-time pairing tokens.** The administrator creates a token with `flowd admin token create`. It is `lfp_` plus base64url of the server's 32-byte public key and 32 random bytes. The server stores only the SHA-256 of the full string, shows the value once, and lets a token live for 1 hour, 24 hours (the default) or 7 days. At most 100 unexpired tokens can wait to be redeemed.
- **Redeeming is approval.** A client seals a `pair` message to the key in the token, on the existing `enroll` hello. Redeeming binds a device key, creates a token user or adds a device to an existing user, and returns the existing refresh token, all in one transaction. From then on the device is like any other: short-lived access tokens, a rotating refresh token, the same revocation. A `token` user has no external identity; `subject` is `token:<id>` and the token row and audit rows record who issued it.
- **Holding the token authenticates the server.** No fingerprint is compared by hand and no route is trusted. A server with another key can't open the hello, so it never reads the token.
- **Any route.** `--remote-listen` accepts any IP literal. `http://` is allowed only on private addresses and names (spec FR-012a), where the client says that the connection is not TLS while content stays encrypted. No certificates are generated. Existing installs keep their bind until the owner opens them.
- **Server mode in the client app.** The Mac app can install and start the same `org.localflow.LocalFlow.remote` launch agent that the script installs, and holds a tokens view. flowd stays a separate process under launchd. Every change goes through `flowd admin`. LocalFlow Server gains a Pairing tab with the same operations. Local dictation never depends on that agent.
- **Sign-in stays.** Apple and Google identities, pending approval and enrolled devices work as before.

## Threat model

| Threat | Mitigation |
| --- | --- |
| Open port scanned | Only the identity and channel routes are served, with the existing anonymous-channel, per-client and server-wide limits; `busy` on overload |
| Network or proxy reads traffic | The HPKE channel to the pinned key carries the token, audio and text. Timing, sizes and the server public key stay visible on `http://` and to any proxy |
| Wrong server at the address | The hello is sealed to the token's key, the server can't open it and closes with 4001, and the client reports a mismatch. The token is never exposed |
| Stolen unused token | One-time, expiring and revocable, with an audit row. The real holder sees it refused and tells the owner, who revokes the device |
| Stolen used token | Worthless, unless it comes with the device key that redeemed it |
| Stolen refresh token | The device-key signature is already required; reuse revokes the device |
| Database stolen | Hashes only; the identity key stays in Keychain |
| Spoofed forwarding headers | Only the rightmost `X-Forwarded-For` from a loopback peer counts; `Cf-Connecting-Ip` is not read (research R7) |
| Attempts on one channel, audit flooding | A refused enrollment or pairing closes its channel; unknown tokens and bad signatures write no audit row |
| Administration reached remotely | No admin routes on the remote listener; main and admin stay on loopback; tokens carry no scope (amended 2026-11-04, see below) |

Sending a token is outside what LocalFlow can protect. Anyone who reads it first can redeem it first. The expiry, the single use and the refused second attempt limit the damage; they don't prevent it.

The app link `localflow://pair?address=<origin>#token=<token>` has a risk of its own on iOS. Any installed app may register the `localflow` scheme, and iOS doesn't say which app opens it, so another app could receive the token. Pasting the token avoids this, and the tokens view says so. A link can also come from someone else and name their server, so the client spends nothing until the user has confirmed the host and the consent text.

## Constitution check

A major amendment (5.0.0), applied on 2026-10-31, before implementation started:

- **15 Authenticated, isolated server access:** gains the pairing token as a second way in, alongside OIDC identities. "No shared static secret" stays, because a token is one-time, hashed and expiring. Device binding, short-lived access tokens, revocation, per-user scoping and fair scheduling don't change.
- **8 Server isolation:** gains a note that the client app may hold server mode, with flowd still a separate process.
- **3 Model lifecycle:** flowd still owns its workers. The owner's local model and the server's model are separate runtimes on one Mac. Memory for both is not measured yet.
- **4 Local-first operation:** existing fallback; server mode doesn't touch local dictation.
- **5 Privacy:** consent stays and content stays in the channel. Token values stay out of logs, audit rows and database columns.
- **7, 9 Persistence, recoverability:** schema version 3 rebuilds `users` and `audit` in one transaction, after a `VACUUM INTO` copy that gives a way back from a newer schema.
- **14 Scope:** no relay, roles, discovery or new dependency. Bundling `flowd-speech` and its FluidAudio resources in the client app is the one addition; measured on a local unsigned build it adds 11.8 MB in Release (flowd-speech 10.8 MB for arm64, FluidAudio bundle 1.0 MB, measured before compression), 18.7 MB in Debug.

## Consequences

- Old clients and the Rust client keep working through sign-in. The Rust client gets pairing after Features 025 and 026.
- An old server rejects `pair`, and the client tells the user to update the server with the token unspent.
- A database at schema version 3 can't be opened by an older flowd (`ErrSchemaTooNew`). Going back means restoring `flowd-remote.pre-v3.sqlite`, which loses anything enrolled since the upgrade.
- A proxy on another host shares one rate-limit bucket, 10 account hellos per minute. A `--trusted-proxy` flag can follow if that matters.
- A Mac in server mode needs auto-login, because a launch agent runs in the user's session and the identity key is in the login Keychain.

## Alternatives considered

- **OIDC only.** Leaves every server dependent on app builds with sign-in configured.
- **A long-lived bearer token.** Simple to use, but a copy would work forever, and principle 15 forbids shared static secrets.
- **T3 Code's 12-character code.** Can be typed, but has about 60 bits and carries no server key, so the client would need a manual check or trust in the route.
- **Server mode in LocalFlow Server only.** Keeps ADR 0032 as written, but needs a second app on every server.
- **TLS certificates from flowd.** Adds little beyond metadata protection over the existing channel, and clients would need to trust them. A proxy or Tailscale Serve provides TLS when wanted.

## Amendment: device invites (2026-11-04)

ADR 0039 adds a second kind of pairing token. An approved device may request an invite for its own user: purpose `invite`, scoped to that user, 10 minutes, single use, stored only as a hash. Unlike the tokens above, redeeming an invite creates a pending device, which the inviting device confirms with its device key after the owner compares a 6-digit code on both screens. Administrator tokens still carry no scope beyond the optional target user, and still approve on redemption. Neither kind grants admin rights, and the remote listener still serves no admin operations. Invites count toward the 100 live token cap.
