LocalFlow for Apple Silicon. The app targets macOS 14 or later.

This build is ad-hoc signed and is not signed with an Apple Developer ID or
notarized by Apple. If you trust the download, open LocalFlow once, then use
System Settings > Privacy & Security > Open Anyway to approve it. Managed Macs
may prohibit this. Approval and privacy permissions may need renewing after updates.

Homebrew installation (after the tap syncs this release):

```sh
brew install --cask brunovskyoliver/tap/localflow
```

Or download the ZIP, extract it and move LocalFlow.app to Applications.
Models are downloaded separately from inside the app. See the repository's
installation guide for permissions, updates and removal.

This release can use a shared LocalFlow server for dictation, rewriting, summaries
and meetings (Settings › Server, Google sign-in, owner approval). The installation
guide's "Use a shared LocalFlow server" section lists the steps, including Tailscale.

Meetings recorded with the LocalFlow iPhone app can now show up in Meetings, marked
"From iPhone". The phone sends them through the shared server, and the Mac imports them
the next time it connects. This needs a server updated with the same release: redeploy
`flowd` and `flowd-meeting` together (the meeting database moves to migration v19), and add
the iPhone app's Google client ID to flowd's `--google-client-id`. The steps are in
`docs/distribution/remote-server.md`, "Meeting handoff and iPhone meetings".
