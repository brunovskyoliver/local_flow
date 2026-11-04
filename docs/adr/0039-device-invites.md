# 0039: Device invites, confirmed on the inviting device

## Status

Proposed, 2026-11-04 (Feature 028, User Story 4). The owner approved the change in principle on 2026-11-03. Amends the constitution to 7.0.0 (principle 15) and ADR 0037. Implementation (tasks T052 to T064) starts only after the owner accepts this record and the amended principle.

## Context

Today only the administrator issues pairing tokens (ADR 0037). To put a second device on their own account, the owner runs `flowd admin token create --user <id>` on the server Mac or uses the Users page there. The owner wants to add an iPhone from the Mac it will share an account with: choose "Add another device", scan a code, confirm.

Redeeming an ADR 0037 token approves the device at once. If a device could hand out that kind of token, anyone who caught it would get a fully approved device on that user, and could list the user's waiting phone meetings (ADR 0034). Two ways to catch one are realistic: the owner sends the link somewhere it is read, or on iOS another installed app registers `localflow://` and receives the link instead of LocalFlow. The design has to keep a caught invite from becoming access.

Principle 15 says the administrator issues pairing tokens, and ADR 0037 says tokens carry no scope. An invite is scoped to one user and issued by a device, so both need amending.

## Decision

- **A device asks for an invite for its own user.** An approved device on an approved user sends `device_invite` on its session channel. The server creates a pairing token in the ADR 0037 format with purpose `invite`, `created_by = device:<id>`, the caller's user as target, 10 minutes of life and one use, stored only as its SHA-256. Nothing in the request names a user; the target comes from the verified access token. A newer invite from the same device revokes its earlier live one.
- **Redeeming creates a pending device.** The new device sends the unchanged `pair` message. The server creates the device as pending, moves the token to `awaiting_confirm`, stores the 32-byte binding of the channel that carried `pair` and a deadline 10 minutes after redemption, and replies `enrolled` with state `pending`, a refresh token and the inviting device's public key. A pending device's sessions answer `not_approved`.
- **Both screens show a 6-digit code.** Each device computes the first 4 bytes of SHA-256(`"localflow-v1-device-code"` ‖ inviter key ‖ new device key ‖ pair binding) as a big-endian integer mod 1,000,000. The binding is `Export("localflow v1 binding", 32)`, separate from the traffic keys, so passing it to the inviting device reveals nothing about that channel's traffic. Go, Rust and Swift share test vectors in `fixtures/remote/device-code.json`.
- **The inviting device confirms with its device key.** While its invite sheet is open it polls `account_devices` every 2 s and sees the pending device, its key and the pair binding. When the owner confirms, it sends `device_confirm` signed by its device key over `"localflow-v1-device-confirm"` ‖ its own session channel binding ‖ invite ID ‖ new device key ‖ pair binding. The server checks the signature against the stored key of the device that created the invite and approves the new device in the same transaction. Declining, or the deadline passing, deletes the pending device and marks the token `declined`.
- **Revoking the inviter cancels its invites.** Revoking the inviting device or its user revokes its live invites and deletes their pending devices in the same transaction.
- **"Your devices".** `account_devices` lists the caller's own user's devices, at most 100, and revokes any of them, including the caller ("This wasn't me"). A request for another user's device answers `unauthorized` and writes a `cross_user_attempt` audit row.
- **Through the server only.** No client opens a listener; every step runs on channels to the server (principle 8, ADR 0034).

The wire format is in `specs/028-server-users-and-rewrite-warmup/contracts/device-invites.md`, the schema (version 5) in its `data-model.md`, and the reasoning in research R13.

## Threat model

| Threat | Mitigation |
| --- | --- |
| Leaked invite: someone reads the link or QR code and redeems it first | They get a pending device with no sessions. The owner's real device gets `pairing_token_invalid`, shows no code, and the inviting device shows a redemption the owner didn't make. Declining it, or 10 minutes passing, deletes it. The invite can't be used again |
| Link caught by another app's `localflow://` claim on iOS | Same as a leaked invite: the catching app can redeem it and gets a pending device only. Pasting the token avoids the scheme |
| Stolen access token of an approved device, without its device key | The thief can create invites and redeem one into a pending device, but can't confirm it, because `device_confirm` needs a signature by the inviting device's key over the thief's own channel binding. Access tokens last 15 minutes, and refresh needs the device key |
| Relay between client and server | The `pair` hello is sealed to the server key in the token, so a relay can't read or change it. A relay that also holds the token can only redeem with its own key, which gives a different code from the one the owner's device would show, and the single use leaves no second try. A captured `device_confirm` can't be replayed on another channel, because it signs the inviting device's channel binding |
| Inviting device or its user revoked while an invite is open | Its live invites are revoked and their pending devices deleted in the same transaction. A later `pair` answers `pairing_token_invalid`, and `device_confirm` from a revoked device has no session to arrive on |
| Device already enrolled under another user | `pair` answers `unauthorized` with the invite unspent, as `accounts/pairing.go:270` does today. Moving a device between users stays an administrator action |
| Invite used to gain more than one device | An invite names only the inviter's user. It can't target another user or an existing device, and grants no admin rights; the remote listener serves no admin operations |
| Invite flooding or code grinding | The limits below. The code is compared, not typed, so there is nothing to guess against the server |

## Limits

- An invite lives 10 minutes before redemption and is single use.
- A redeemed invite waits at most 10 minutes for confirmation. The sweep runs at most once a minute, and the invite, confirm and list operations sweep the rows they touch first.
- At most 3 open invites (live or awaiting confirmation) per user.
- At most 10 invites created by one device in any hour, counted from token rows, which are kept 90 days.
- The server-wide cap of 100 live tokens from ADR 0037 counts invites too.
- Past any of these limits `device_invite` answers `busy`.

Tokens, codes, bindings and keys never reach logs or audit rows. `scripts/check-remote-logs.sh` keeps rejecting `lfp_`.

## Constitution check

A major amendment (7.0.0), applied on 2026-11-04, before implementation:

- **15 Authenticated, isolated server access:** an approved device may request a one-time, 10-minute invite for its own user only, redeemed into a pending device that the inviting device confirms with its device key after a code compared on both screens. Administrator tokens, short-lived access tokens, device-bound refresh, immediate revocation and per-user scoping don't change.
- **8 Server isolation:** no client opens a listener; pairing between devices is relayed through flowd.
- **5 Privacy:** no audio or text is involved. Device keys and bindings sent to the inviting device are public or derived values.
- **7, 9 Persistence, recoverability:** schema version 5 adds the token columns in one transaction, after a `VACUUM INTO` copy (`flowd-remote.pre-v5.sqlite`).
- **14 Scope:** no new dependency, relay service or role. QR codes in the Rust app are covered by research R14.

## Consequences

- The owner adds their own devices without going to the server Mac. The Users page's "Add device for <user>" stays for administrators and is the only way while this record is not accepted.
- The owner must compare the codes. Confirming a redemption the other device didn't show defeats the check, so the confirm sheet has to tell the owner to confirm only when both screens show the same code.
- An approved device, or anyone holding its access token for up to 15 minutes, can revoke the user's other devices through `account_devices`. That is a denial of service, not access, and the audit row names the acting device.
- An old server doesn't list `device_invite` in `ready.capabilities.ops`, and clients hide the controls.
- An administrator approving a pending invited device with `flowd admin approve device <id>` also confirms its invite.
- A database at schema version 5 can't be opened by an older flowd; going back means restoring `flowd-remote.pre-v5.sqlite`.

## Alternatives considered

- **Approve on redemption, as administrator tokens do.** Simplest, but a caught invite becomes a fully approved device.
- **A code derived from the token alone.** Whoever caught the token could compute the same code.
- **A long-lived operation that pushes the redemption to the inviting device.** The handoff watch pattern exists, but polling `account_devices`, which the "Your devices" list needs anyway, is less code.
- **Direct pairing between the two devices over the LAN.** Needs a listener on a client, which principle 8 forbids, and doesn't work across Tailscale or a proxy.
