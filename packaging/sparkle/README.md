# Pinned updater dependency

Sparkle 2.10.0, commit `eef1a539a373c1f1a320624b1130fc5de7b2e100`, is built
from source by `scripts/prepare-sparkle.sh`. Source, products and tools live in
ignored `build/Sparkle/`; no source checkout is committed. The Xcode app target
runs preparation before compilation and embeds/signs the resulting framework.
The final embedding phase runs `scripts/sign-embedded-sparkle.sh` for signed
builds: it signs Mach-O files, nested XPC/app bundles and the framework in that
order, then verifies the complete framework. CodeSignOnCopy alone does not seal
the nested bundles produced by the unsigned dependency build. Unsigned test
builds skip this step; distribution packaging has its own nested signing pass.
Test targets inherit its framework search path. No extra Swift package is added.

The upstream binary package cannot enforce the feature's feed memory bound.
`SPUDownloader` also rejects file URLs, ruling out a bounded prefetched local feed.
The local patch therefore changes the actual transport used by both the in-process
and XPC downloader, rather than relying on a post-download size check.

- Temporary feeds/release notes accumulate at most 1 MiB, checked before each
  append. Overflow discards partial data and reports failure.
- URLSession resource deadlines are 30 seconds for feeds and 1,800 seconds for
  archives, with a 30-second inactivity timeout.
- Archive progress above 4 GiB cancels the task. Final file size is checked again
  before it can enter installation staging. URLSession may write an in-flight
  network chunk before its progress callback runs; 4 GiB is the accepted archive
  limit, not a measured exact peak-disk guarantee.
- Production transport and redirects require HTTPS. The test executable alone
  compiles an explicit loopback HTTP allowance.
- Starting a new completed download removes prior cached download directories.
  One updater owns the operation; automatic downloads/installations are disabled.

The script fingerprints the patch, commit and Xcode version. Changing any forces
a rebuild. Its lock serializes preparation across concurrent app/test builds.
A dead build can leave `prepare.lock`; inspect for a live preparation process
before manually removing that generated lock directory.

Run `scripts/test-sparkle-bounds.sh` for loopback tests of the actual patched
implementation: exact cap, unknown-length overflow, deadline configuration,
cancellation and archive overflow. Cache methods are forbidden stubs in this
harness so no installed app's cache can be touched. Run upstream signature tests
separately via the pinned Sparkle scheme's `SUSignatureVerifierTest` suite.

Keep the complete LICENSE with the dependency and packaged app. When updating
Sparkle, review upstream security changes, rebase and inspect this small patch,
rerun transport/signature tests and verify the app from a clean build directory.
Do not replace the patched framework with upstream's binary package silently.
