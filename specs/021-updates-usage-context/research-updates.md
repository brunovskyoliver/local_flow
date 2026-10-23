# Research: public macOS updates

Date: 2026-10-23. Design investigation only; no release, deployment, credentials or application code changed.

## Scope and decision

The user confirmed public Mac downloads with server access restricted to approved users. Add in-app updates to the existing LocalFlow Mac client, using one stable channel and user-confirmed installation. Keep remote server releases under separate administrator control. iPhone distribution and automatic server upgrades are outside this slice.

Use Sparkle with GitHub Releases for public archives and a stable HTTPS appcast endpoint. GitHub Pages is the proposed feed host, subject to repository configuration at publication time. Public downloads do not grant server access and must contain no server credentials. Existing identity verification, approval and revocation remain authoritative.

## Repository evidence

- `.github/workflows/release.yml` builds the `LocalFlow` scheme on an ARM macOS runner for version tags. It publishes a ZIP, SHA-256 file and generated Homebrew cask.
- `scripts/package-macos.sh` sets the version/build number, signs nested binaries and the app ad hoc, verifies the signature and creates the archive. It does not notarize.
- `docs/distribution/homebrew.md` documents manual upgrades and an hourly sync performed by a separate Homebrew tap. This investigation did not verify the remote tap's operation.
- `packaging/homebrew/localflow.rb.in` points at public GitHub release assets and preserves application data on removal.
- No Sparkle integration or appcast was found.
- `scripts/dev-macos.sh` quits, replaces and reopens the app without explicitly refreshing bundled `flowd`. `LocalAIRuntime.swift` registers missing services and manages MTPLX startup, but its normal lifecycle helper does not restart `flowd`. The referenced thread reports a stale bundled daemon after installation. The new design must cover this failure.
- Both `apps/macos/LocalFlow` and `apps/macos/LocalFlowServer` exist. ADR 0032 describes the latter as a second app, while the supplied AGENTS text describes only the server app. This feature targets the existing client and does not remove or merge either application. Resolve the documentation inconsistency separately.

## Dependency and signing findings

Sparkle supports Swift Package Manager integration, a native updater controller, an HTTPS feed URL and embedded Ed25519 verification key. Use a pinned production release, with an explicit dependency-update policy. The investigated production release is 2.10.0; its macOS 12 minimum is below LocalFlow's documented macOS 14 minimum. Recheck security fixes when implementing. [Setup](https://sparkle-project.org/documentation/), [version compatibility](https://sparkle-project.org/documentation/upgrading/), [release history](https://github.com/sparkle-project/Sparkle/releases)

Sparkle's top-level license is permissive and includes notice requirements. Its license file also includes bundled component licenses. Preserve the complete license file in distribution notices and review the exact pinned binary's bundled components; recording only “MIT” would omit those notices. Sparkle is justified here because it owns update verification and installation that would otherwise require custom security-sensitive code. [Sparkle 2.10.0 license](https://raw.githubusercontent.com/sparkle-project/Sparkle/2.10.0/LICENSE)

Use Developer ID Application signing with hardened runtime, notarization and a stapled ticket for public production builds. The existing Apple Development identity in the development script does not establish that a Developer ID identity exists. Availability of the production certificate and notarization credentials remains unverified. [Apple Developer ID distribution](https://developer.apple.com/developer-id/)

Archive signing is separate from Apple code signing. Generate Sparkle archive signatures and feed metadata with the pinned Sparkle tools. Preserve framework symlinks during packaging. Keep the private update key out of the application and hosting repository. Use Keychain locally and protected secret injection in CI, never a command-line secret argument. [Publishing updates](https://sparkle-project.org/documentation/publishing/), [security guidance](https://sparkle-project.org/documentation/security-and-reliability/)

## Update contract

1. The production client has a fixed stable feed and embedded update public key. Development variants cannot install production updates. Public update requests carry no LocalFlow account token, user identifier, transcript, audio or application context. Disable Sparkle system-profile submission.
2. Offer manual checks and an optional automatic-check preference. Default to user-confirmed installation. No required update check blocks offline dictation or startup.
3. Advertise only complete, verified production artifacts. Require an increasing numeric build number, version, minimum supported OS, immutable archive URL, archive length and cryptographic signature. Preserve published bytes. GitHub immutable releases can protect assets and tags; configure them only during an authorized release setup. [GitHub immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
4. Permit at most one update operation at a time. Coalesce repeated checks. Initial engineering limits are a 1 MiB feed, 4 GiB archive, 30-second check timeout and 30-minute download timeout. These are proposed bounds, not observed package sizes. Implementation must verify how the pinned updater enforces them before enabling updates, or revise the documented limits with evidence. Stream downloads to disk; retain at most one pending download and one installation staging set. Failure cleanup and next-launch cleanup must remove abandoned staging data without touching recordings or models.
5. Installation waits for recording, dictation finalization, meeting capture and other writes to reach the existing safe shutdown boundary. User cancellation leaves the current app usable. Do not terminate in-flight work to satisfy an update deadline.
6. Reconcile the bundled helper build on every launch, including after a manual/Homebrew replacement. Refresh only the current variant's registered helpers, after work has drained. Verify the responding daemon's build identity and health before routing requests to it. Never restart the separately administered remote server or another app variant. A stale/unhealthy helper leaves its capability unavailable with a retry action; completed text and stored data remain intact.
7. Download, verification or pre-install failure leaves the existing app installed. A post-install helper failure does not trigger an automatic app/database downgrade. Recovery uses a corrected forward release unless migration compatibility has been explicitly established.
8. Remote server compatibility is a release gate. The present server rejects unknown request fields, so deploy and verify a compatible server before advertising a client requiring those fields. Do not treat the updater as authority to deploy the server.

## Bootstrap from current installations

Existing builds have no updater or trusted Sparkle key. Their first updater-enabled version therefore needs one manual ZIP replacement or Homebrew upgrade. Publish that bootstrap version with Developer ID signing, notarization and the long-lived update public key already embedded. Preserve the bundle identifier and data paths.

Test ad-hoc-to-Developer-ID and Apple-Development-to-Developer-ID transitions separately. Do not promise that macOS privacy permissions, background-item approvals or Keychain access survive a signing-identity transition. Explain any observed reapproval steps, and preserve existing data and credentials rather than silently resetting them. Later updates must retain the production signing identity and update-key continuity. Document and test the framework's supported key-rotation procedure before rotating either key.

Homebrew remains a bootstrap/manual route. Add its `auto_updates` declaration once in-app updating is shipped, document the resulting command behavior, and test an app that was updated by Sparkle followed by an explicit Homebrew upgrade. Do not run both installers concurrently.

## Implementation sequence

1. Complete the feature spec, constitution check and dependency/notice review. Confirm the distribution identity, feed ownership and signing-key backup procedure without exposing credentials.
2. Add the pinned Sparkle package to `apps/macos/LocalFlow.xcodeproj/project.pbxproj` and its resolved dependencies. Add the update wrapper, app ownership, manual action and preference. Configure `Info.plist` with production-only feed/key settings.
3. Implement helper version reconciliation in the `LocalAIRuntime`/app-lifecycle boundary with protocol-backed test doubles. Extend helper health metadata only if existing metadata cannot identify the running build.
4. Extend `scripts/package-macos.sh`, nested signing in `scripts/bundle-local-ai.sh` and `.github/workflows/release.yml` for production signing, notarization, archive signatures and appcast generation. Missing credentials fail production packaging; they must not silently select ad-hoc signing.
5. Update Homebrew generation, distribution instructions, release notes and `THIRD_PARTY_NOTICES.md`. Generate and verify all assets before publication; do not publish a feed pointing at unavailable artifacts.
6. Validate locally, then perform an explicitly authorized bootstrap/release exercise. No publishing or deployment is part of this research task.

## Acceptance and remaining work

- Run `make check` after implementation. Test the update wrapper's busy/cancel/failure transitions and helper reconciliation with doubles.
- On real installed builds, verify the manual bootstrap and a subsequent signed in-app upgrade. Verify signatures, notarization, advertised version and the running bundled daemon's version independently.
- Exercise invalid signatures, wrong update keys, older builds, unsupported OS, unavailable feed, interrupted download, insufficient disk space and staging cleanup. Failure must preserve the installed app and user data.
- Attempt installation during dictation and meeting capture; complete or cancel safely, with no missing text/audio. Test user cancellation of quit.
- Upgrade while an older helper remains running; confirm automatic refresh, variant isolation and explicit failure behavior if restart fails.
- Check permissions, Keychain access, registered background services and preservation of recordings, transcripts, models and settings across bootstrap and ordinary upgrades.
- Verify clean-Mac installation and server/client compatibility separately. Record hardware, OS, build and conditions for idle/update RSS, downloaded size, disk peak and update duration; none has been measured here.

Constitution assessment: the client remains native; Sparkle adds no inference runtime or storage authority. Update hosting is optional infrastructure and must not become mandatory for dictation. Update checks exclude content and analytics. The dependency requires documented notice review, bounded resource behavior and measured acceptance. No architecture exception is proposed. This document completes research/design only; application changes, credentials, release publication and hardware acceptance remain outstanding.

## Implementation resolution

The supported Sparkle 2.10.0 public API cannot cap feed accumulation. Its
`Downloader/SPUDownloader.m` explicitly rejects `file://`, so a prefetched local
feed is not supported. The approved implementation uses a reproducible source
framework at commit `eef1a539a373c1f1a320624b1130fc5de7b2e100`, replacing the
original binary-package proposal. `packaging/sparkle/bounded-downloads.patch`
bounds actual downloader buffering/deadlines, enforces HTTPS and reduces old
cache retention; `scripts/prepare-sparkle.sh` builds it and its signing tools.
The same patched downloader source serves in-process and XPC paths. See its
README for the archive progress-callback disk-overrun caveat and test harness.

The implemented feed URL uses GitHub's latest-release `appcast.xml` asset, so no
GitHub Pages deployment is needed. Archives retain immutable version-tag URLs.
The existing Developer ID Application identity was found in Keychain on
2026-10-23; production notarization and Sparkle update-key availability remain
separate prerequisites. A signed local artifact can be prepared without sending
the app to Apple, using the explicit `--signed-local` packaging mode. This is not
a notarized production release and does not enable update checks.
