# Optional-engine experiment disposition

Date: 2026-09-17. Scope: T043 and the Whisper large-v3-turbo follow-up. This records whether the processing evidence collected under Feature 002 warrants an alternative-engine or production-fallback experiment, and what was decided. The Whisper candidate was tested in an evaluation-only helper; no alternative engine was wired into production.

## Disposition: candidate tested, Parakeet retained

Parakeet v3 through FluidAudio 0.15.7 (revision `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`) remains the only production engine. Whisper large-v3-turbo was benchmarked with automatic detection and explicit Slovak and English hints. The measured result and retention decision are in [whisper-benchmark.md](whisper-benchmark.md). It did not meet a safe adoption bar because long-form and mixed-language quality regressed sharply, and resource and latency cost increased.

The original no-experiment disposition below remains the historical rationale for why this candidate was not previously provisioned:

1. **The owner explicitly declined it.** [The owner priority revision](owner-priorities.md) states "Keep Parakeet. Do not begin another broad corpus or engine experiment to unblock this work" and "No alternative engine or new broad experiment is requested." That instruction is in force for this increment.
2. **The measured failures are not engine-localized.** The category regressions that remain against the T014 historical baseline (`public_sk_longer` +4.6 points, `public_sk_general` +1.0 point, `public_technology` +0.4 points under fixed contiguous windows; see [chunk-planner-final.md](chunk-planner-final.md) and [phase4-regression-investigation.md](phase4-regression-investigation.md)) are attributable to the change from anchored overlap splicing to conservative contiguous assembly, not to acoustic recognition failure. The same engine, same model and same audio produce the T014 numbers under the historical splicer. An engine swap addresses none of that.
3. **Mixed-language performance is deferred, not failing an engine gate.** Within-sentence Slovak/English switching, the one area where SC-003 contemplates a bounded fallback, has no authentic fixtures ([coverage-gaps.md](coverage-gaps.md)). Without an authentic mixed set there is no declared target category for SC-007's "at least 20% relative WER reduction", so a comparison could not be scored even if a second engine were available. Synthetic stress concatenations are labeled synthetic and do not count.

Retaining the current engine is a valid explicit decision under FR-014 when evidence does not support a safe advantage. That is the decision here.

## What an experiment would require, if reopened

Nothing below has been done. It is listed so a future decision cannot skip it:

- **Provisioning.** Explicit local installation through the existing `ModelProvisioner` with a pinned descriptor, complete artifact hashes and no implicit download, exactly as the Silero VAD capability was added for T050. A model card, license text and dependency record go in `docs/licenses/` before any run; the current directory holds only `FluidAudio-0.15.7.txt`, `GRDB-7.10.0.txt`, `fastcluster.md` and `parakeet-v3-model-card.md`.
- **Boundary.** The candidate is constructed behind `TranscriptionRuntime` and owned by `ModelLifecycleCoordinator`. No second lifecycle owner, no concurrent residency of two ASR models, no change to the server or wire schema.
- **Ownership tests.** `apps/macos/LocalFlowTests/ModelOwnershipTests.swift` already covers exclusive leases, stale release, cancelled preparation joining before another runtime, load failure clearing ownership, repeated cancellation joining an uninterruptible shutdown, installation blocked during an active lease, and application shutdown joining an in-flight release. A fallback experiment would add the sequential release-before-acquire handover between two distinct runtime factories, a missing second model, cancellation during handover and a failed handover that leaves the first engine's result as the delivered result. Those four tests are not written because no second runtime exists to drive them.
- **Comparison.** Same frozen manifests (`10b9873c…988b` short, `53b0a220…5f97` long), same recorded hardware/conditions, at least three resource/timing repeats, absolute per-fixture counts, and the full sequential fallback path measured including its triggering policy. Adoption also needs every inherited resource gate in [resources.md](resources.md) to pass with the second model's working set included.

## Constitution check

This disposition adds no dependency, model, process, server API or wire schema. It changes no production code. It does not waive SC-007; it records that SC-007 was never invoked because no candidate was proposed.
