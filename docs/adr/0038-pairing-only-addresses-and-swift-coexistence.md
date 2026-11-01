# 0038: Pairing only, several addresses, and living beside the Swift app

## Status

Accepted by the owner, 2026-11-01. Amends the constitution to 6.0.0.

## Context

The owner dropped provider sign-in: a client needs a pairing token and a URL it can reach, over Tailscale, a LAN or any proxy. The owner also wants to try the Rust client while keeping the Swift app, with their data copied and without a second copy of the models.

## Decision

- The Rust client has no Google or Apple sign-in. Turning the server on opens the pairing form.
- A device keeps several addresses for one server. It tries the last one that worked, then the others, moving on only when an address can't be reached. Every address is still checked against the pinned key.
- `scripts/install-remote-server.sh` binds the remote listener to `0.0.0.0`. `--listen` and `--admin-listen` stay on loopback. The remote listener serves only the identity route and sealed channels.
- On first launch the Rust client copies the Swift app's rows, meeting files and settings into its own folder, reading the source only. Settings can repeat the copy, which adds what's new. Keychain items and waiting dictations don't move. Setup still runs, because macOS grants permissions per app.
- Beside the Swift app, the Rust client keeps its own `Models` folder and fills it at launch with APFS clones of the models Swift has. A clone shares its blocks with the original until one is rewritten. The two apps can't share the folder itself: the running Swift app holds an exclusive lock per model there for its whole life, so a second app reads the model as missing.

## Consequences

- flowd, the Swift app and the iOS app keep their OIDC code, so existing clients keep working. flowd refuses Google unless `--google-client-id` is set. Removing the rest is a separate change once those clients stop needing it.
- `http://` stays limited to private and Tailscale addresses (FR-012a). A public address needs `https://`.
- After a copy, each app has its own data; a change in one reaches the other only through another copy, and only from Swift to Rust.
- Removing a model in one app doesn't remove it from the other, and the disk space comes back only once both have removed it. A model the Rust client removes returns at its next launch while Swift still has it. A model the Rust client downloads isn't visible to Swift.
- The Rust client starts and stops the Swift app's local rewrite model service (`org.localflow.LocalFlow.mtplx`) as Swift does, and writes Swift's `LocalAI/app-pid`, the one write into that folder. Its binary is named `LocalFlow` so the service's check accepts it. With both apps open, whichever stops the model last wins until the other's next dictation. It doesn't yet follow games or memory pressure, or install the model.
- Both apps must not listen to one shortcut at once.
- The `plist` crate (MIT) joins the Mac build, to read the settings export.

## Alternatives considered

- Copying the database file: not consistent while Swift runs, and it would fail on a schema difference. A row copy in one transaction handles both.
- Using the Swift `Models` folder directly: built first, and it fails on the real machine because of the lock above. The installed Swift app can't be changed to release it.
- Symlinking `Models`: dangles when the Swift folder has no models yet, and the provisioner refuses symlinks.
- Pointing Rust at the Swift database itself: two apps would own one schema before the cutover.
