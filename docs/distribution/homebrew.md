# Homebrew distribution

LocalFlow uses free ad-hoc signing. This makes the bundle executable on Apple
Silicon but does not verify the publisher's identity or provide Apple notarization.
No Apple account, certificate or signing secret is needed to build it.

## Install

The command below becomes available after the first release is published and
its cask is synced to [homebrew-tap](https://github.com/brunovskyoliver/homebrew-tap).
Homebrew discovers that repository automatically from the tap name.

```sh
brew install --cask brunovskyoliver/tap/localflow
```

Open LocalFlow from Applications. If macOS blocks it, dismiss the warning and,
if you trust the download, go to System Settings > Privacy & Security and click
Open Anyway for LocalFlow. Confirm the dialog. This is Apple's per-app exception;
Gatekeeper stays enabled. Managed Macs may prohibit it. See
[Apple's instructions](https://support.apple.com/102445).

Allow Microphone access and follow the app's permission setup. Global shortcuts
need Input Monitoring; insertion may need Accessibility. Meeting capture requests
Screen & System Audio Recording. Install models through the app. Homebrew does
not download model weights or grant privacy permissions.

Quit the app before updating:

```sh
brew update
brew upgrade --cask brunovskyoliver/tap/localflow
```

Ad-hoc signatures change between builds. Approval may be needed again. If
shortcuts or insertion stop working, remove and re-add LocalFlow in the relevant
Privacy & Security list, then restart the app.

Quit LocalFlow before `brew uninstall --cask localflow`. The cask preserves
Application Support data, including recordings, transcripts, models and settings.
There is deliberately no destructive `zap` stanza.

## Make a release

1. Commit the distribution setup to main and push it. The repository and release
   assets must be publicly readable for these installation commands.
2. Ensure GitHub Actions can write repository contents in both repositories.
   The app workflow publishes releases; the tap workflow updates its own main
   branch. No cross-repository token is required.
3. Push a new version tag, such as `v0.1.0`. Use increasing X.Y.Z versions.
   To retry a failed release after fixing CI, run the release workflow manually
   from main with the original tag. This preserves the tagged source commit.
4. The workflow runs `make check`, builds on Apple Silicon, ad-hoc signs all
   nested binaries and the app, verifies signatures, creates a ZIP and checksum,
   publishes the GitHub Release with the generated `localflow.rb` asset.
   The tap checks for releases hourly and commits that cask to its main branch.
   For an immediate update, run its Sync LocalFlow release workflow manually.
5. Check the workflow, download URL, checksum and generated cask. Test installation,
   launch approval, dictation, helper services, upgrading and uninstalling on a
   clean Mac before advertising the release.

The workflow uses the macos-26 ARM runner and its default Xcode. The local project
was developed with Xcode 26.4.1; hosted-runner compatibility must be established
by the first CI run. There are no Apple signing credentials in this workflow.
If tap synchronization fails, rerun its workflow or copy the release's
`localflow.rb` asset into `Casks/localflow.rb` in homebrew-tap through a pull
request. Scheduled runs may be delayed; GitHub can disable schedules after
60 days without repository activity, so check the tap Actions page if it falls
behind. Never replace a published ZIP with different bytes.

For a local package, install Xcode, Go, CMake and FFmpeg, then run:

```sh
make check
./scripts/package-macos.sh 0.1.0 1
```

Artifacts are written to `build/distribution/0.1.0/`. Packaging does not install
or open the app and does not modify the source Info.plist. The existing
`make release` command remains a development launch command.

This setup does not establish clean-Mac acceptance, macOS 14 runtime compatibility,
resource measurements or Apple security approval. Optional local AI provisioning
and background services also need clean-Mac testing. An unsigned release belongs
in this custom tap, not the official Homebrew cask repository.

Constitution check: distribution tooling only; no app architecture, model lifecycle,
wire schema, storage or runtime dependency changes. No architecture exception.
