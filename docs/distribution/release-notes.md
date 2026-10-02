LocalFlow for Apple Silicon. The app targets macOS 14 or later.

This build is signed with Developer ID (e-Net, s.r.o.) and notarized by Apple.
If you are updating from an ad-hoc 0.1.x build, macOS may ask for Input Monitoring
and Accessibility once more.

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
