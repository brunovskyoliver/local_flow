import SwiftUI

/// Displays one persisted envelope without reprocessing or reconstructing missing stages.
struct TranscriptionDetailView: View {
  let envelope: TranscriptionEnvelope
  /// Supplied by history; nil renders the Feature 002 sections alone.
  var model: HistoryViewModel?
  var copy: ((String) -> Void)?
  /// A nil attempt inserts the saved transcript (the FR-021 action); an attempt
  /// inserts that attempt's rewritten output.
  var insert: ((RewriteAttempt?) -> Void)?
  private enum Stage: String, CaseIterable, Identifiable {
    case normalized = "Normalized"
    case assembled = "Assembled"
    case raw = "Raw recognition"
    var id: String { rawValue }
  }
  @State private var stage = Stage.normalized

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      status
      if let detail = envelope.detail {
        Picker("Transcript stage", selection: $stage) {
          ForEach(Stage.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("history.detail.stage")
        switch stage {
        case .normalized: stageText(envelope.entry.text)
        case .assembled: stageText(detail.assembledText)
        case .raw:
          Text("Exact received windows in order. Overlapping windows can repeat words.")
            .font(.flow(size: 12)).foregroundStyle(.secondary)
          ForEach(detail.rawWindows, id: \.sequence) { window in
            VStack(alignment: .leading, spacing: 6) {
              Text(window.historyLabel).font(.flow(size: 12)).foregroundStyle(.secondary)
              stageText(window.text)
            }
          }
          if detail.rawWindows.isEmpty {
            Text("No raw windows were retained.").foregroundStyle(.secondary)
          }
        }
        DisclosureGroup("Processing details") { processing(detail).padding(.top, 10) }
          .accessibilityIdentifier("history.detail.processing")
      } else {
        Text(TranscriptionEntry.legacyDetailMessage)
          .font(.flow(size: 13)).foregroundStyle(.secondary)
          .accessibilityIdentifier("history.detail.legacy")
        Text("Saved text").font(.flow(size: 14, weight: .semibold))
        stageText(envelope.entry.text)
      }
      if let model {
        ContextSection(model: model)
        RewriteSection(model: model, copy: copy, insert: insert)
      }
    }
    .textSelection(.enabled)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("history.detail")
  }

  private var status: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Completeness: \(envelope.entry.qualityLabel ?? "Complete")")
      Text(
        "Delivery: \(envelope.entry.deliveryState.rawValue.replacingOccurrences(of: "_", with: " "))"
      )
      Text(
        "Stopped: \(envelope.entry.stopReason.rawValue.replacingOccurrences(of: "_", with: " "))")
    }.font(.flow(size: 13))
  }

  private func stageText(_ text: String) -> some View {
    Text(verbatim: text.isEmpty ? "(Empty stage)" : text)
      .font(.flow(size: 14)).frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func processing(_ detail: TranscriptionQualityDetail) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      metadata("Engine", detail.provenance.engine)
      metadata("SDK", detail.provenance.sdkVersion)
      metadata("Model", detail.provenance.modelID)
      metadata("Model revision", detail.provenance.modelRevision)
      metadata("Build", detail.provenance.build)
      metadata("Uncommitted build changes", detail.provenance.dirty.map { $0 ? "Yes" : "No" })
      metadata(
        "Language",
        detail.provenance.automaticLanguage ? "Automatic; no hint" : detail.provenance.languageHint)
      metadata("Assembly", detail.assemblyVersion)
      metadata("Normalization", detail.normalizationVersion)
      metadata("Vocabulary revision", String(detail.vocabularyRevision))
      metadata(
        "Applied formatting rules",
        detail.appliedRuleIDs.isEmpty ? "None" : detail.appliedRuleIDs.joined(separator: ", "))
      metadata(
        "Applied vocabulary entries",
        detail.appliedEntryIDs.isEmpty ? "None" : detail.appliedEntryIDs.joined(separator: ", "))
      metadata(
        "Ambiguous vocabulary entries",
        detail.ambiguousEntryIDs.isEmpty
          ? "None" : detail.ambiguousEntryIDs.joined(separator: ", "))
      metadata("Operating system", detail.provenance.operatingSystem)
      metadata("Unicode runtime", detail.provenance.foldingRuntime)
      metadata(
        "Audio",
        "\(detail.provenance.sampleRate) Hz, \(detail.provenance.channels) channel, \(detail.provenance.inputSampleFormat)"
      )
      metadata(
        "Input",
        "\(detail.provenance.inputSamples) samples; \(detail.provenance.inputDurationSeconds) seconds"
      )
      metadata(
        "Windows",
        "\(detail.provenance.windowSamples) samples; overlap \(detail.provenance.overlapSamples); stride \(detail.provenance.strideSamples)"
      )
      metadata("Minimum padded input", "\(detail.provenance.minimumPaddedSamples) samples")
      ForEach(detail.provenance.stageDurations.keys.sorted(), id: \.self) { key in
        metadata(
          "\(key.capitalized) duration",
          detail.provenance.stageDurations[key].map { "\($0) seconds" })
      }
      ForEach(detail.rawWindows, id: \.sequence) { window in
        metadata(
          "Window \(window.sequence + 1) timing evidence",
          "\(window.timingValidation.rawValue); \(window.timings?.count ?? 0) recorded tokens; \(window.paddedSampleCount) padded samples"
        )
      }
      ForEach(detail.seams, id: \.window) { seam in
        metadata(
          "Join before window \(seam.window + 1)",
          "\(seam.decision); \(seam.discardedLexicalWords) words discarded")
      }
      Text("Processing reasons").font(.flow(size: 14, weight: .semibold))
      if detail.completionReasons.isEmpty { Text("None recorded") }
      ForEach(Array(detail.completionReasons.enumerated()), id: \.offset) { _, reason in
        Text(reason.code.rawValue + (reason.window.map { " (window \($0 + 1))" } ?? ""))
      }
      Text("Unavailable evidence").font(.flow(size: 14, weight: .semibold))
      if detail.provenance.unavailableMetadata.isEmpty { Text("None recorded") }
      ForEach(detail.provenance.unavailableMetadata, id: \.field) { item in
        metadata(item.field, item.reason.rawValue)
      }
      ForEach(Array(detail.attempts.enumerated()), id: \.offset) { index, attempt in
        metadata(
          "Attempt \(index + 1)\(index == detail.selectedAttempt ? " (selected)" : "")",
          "\(attempt.engine); \(attempt.status.rawValue); "
            + (attempt.duration.map { "\($0) seconds" } ?? "Duration unavailable"))
      }
      DisclosureGroup("Evidence hashes") {
        VStack(alignment: .leading, spacing: 8) {
          metadata("Content", detail.contentHash)
          metadata("Assembled", detail.assembledHash)
          metadata("Normalized", detail.normalizedHash)
          metadata("Vocabulary", detail.vocabularyHash)
          metadata("Model manifest", detail.provenance.modelManifestHash)
          ForEach(detail.rawWindows, id: \.sequence) {
            metadata("Raw window \($0.sequence + 1)", $0.textHash)
          }
          ForEach(detail.provenance.artifactHashes.keys.sorted(), id: \.self) { key in
            metadata(key, detail.provenance.artifactHashes[key])
          }
        }.padding(.top, 8)
      }
    }.font(.flow(size: 13))
  }

  private func metadata(_ label: String, _ value: String?) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).foregroundStyle(.secondary)
      Text(verbatim: value ?? "Unavailable").fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// What app context this dictation read and what local spelling it changed.
private struct ContextSection: View {
  let model: HistoryViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Divider()
      Text("App context").font(.flow(size: 14, weight: .semibold))
      Text(model.contextLabel).font(.flow(size: 13))
        .accessibilityIdentifier("history.detail.context.outcome")
      if let line = model.contextRewriteLine {
        Text(line).font(.flow(size: 13)).foregroundStyle(.secondary)
          .accessibilityIdentifier("history.detail.context.rewrite")
      }
      ForEach(Array(model.contextSpellingChanges.enumerated()), id: \.offset) { _, change in
        Text(
          verbatim:
            "“\(change.original)” → “\(change.replacement)” · on screen (\(change.sourcePart.historyLabel.lowercased()))"
        ).font(.flow(size: 13))
      }
      if let before = model.contextPreSpellingText {
        DisclosureGroup("Text before context spelling") {
          Text(verbatim: before).font(.flow(size: 13))
            .frame(maxWidth: .infinity, alignment: .leading)
        }.font(.flow(size: 13))
      }
      if let snapshot = model.contextSnapshot {
        DisclosureGroup("Context as captured") {
          VStack(alignment: .leading, spacing: 8) {
            if let app = snapshot.appName { labeled("App", app) }
            labeled("Field", snapshot.fieldKind.rawValue.replacingOccurrences(of: "_", with: " "))
            ForEach(ContextPart.allCases, id: \.self) { part in
              if let text = snapshot.text(of: part) { labeled(part.historyLabel, text) }
            }
            if !snapshot.terms.isEmpty {
              labeled("Terms", snapshot.terms.map(\.text).joined(separator: ", "))
            }
            if !snapshot.truncated.isEmpty {
              labeled("Shortened", snapshot.truncated.joined(separator: ", "))
            }
          }.padding(.top, 8)
        }.font(.flow(size: 13)).accessibilityIdentifier("history.detail.context.snapshot")
      }
    }
    .accessibilityIdentifier("history.detail.context")
  }

  private func labeled(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).foregroundStyle(.secondary)
      Text(verbatim: value).fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// The "Rewrite" section: saved text beside the current rewrite, what was
/// delivered, every attempt, and the history-only Retry/Rewrite and Cancel.
private struct RewriteSection: View {
  @Bindable var model: HistoryViewModel
  let copy: ((String) -> Void)?
  let insert: ((RewriteAttempt?) -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Divider()
      Text("Rewrite").font(.flow(size: 14, weight: .semibold))
      Text(model.rewriteStateLine).font(.flow(size: 13)).foregroundStyle(.secondary)
      Text(model.deliveredLine)
        .font(.flow(size: 13)).accessibilityIdentifier("history.detail.rewrite.delivered")
      if let notice = model.rewriteNotice {
        Text(notice).font(.flow(size: 13)).foregroundStyle(.secondary)
          .accessibilityIdentifier("history.detail.rewrite.notice")
      }
      if let explanation = model.rewriteLimitExplanation {
        Text(explanation).font(.flow(size: 13)).foregroundStyle(.secondary)
      }
      HStack(alignment: .top, spacing: 16) {
        text(
          title: "Saved text", caption: "The faithful transcript.",
          body: model.detailEnvelope?.entry.text ?? "", attempt: nil)
        if let current = model.currentRewrite, let output = current.outputText {
          text(
            title: "Current rewrite (\(current.mode.title))",
            caption: "AI-generated rewrite, not the transcript.",
            body: output, attempt: current)
        }
      }
      HStack(spacing: 8) {
        Picker("Mode", selection: $model.rewriteMode) {
          ForEach(RewriteMode.allCases.filter(\.sendsRequest), id: \.self) {
            Text($0.title).tag($0)
          }
        }
        .frame(width: 180).accessibilityIdentifier("history.detail.rewrite.mode")
        Button(model.detailAttempts.isEmpty ? "Rewrite" : "Retry") { model.requestRewrite() }
          .disabled(!model.canRequestRewrite)
          .accessibilityIdentifier("history.detail.rewrite.retry")
        if model.pendingRewrite != nil {
          Button("Cancel rewrite") { model.cancelRewrite() }
            .accessibilityIdentifier("history.detail.rewrite.cancel")
        }
      }
      if model.detailAttempts.isEmpty {
        Text("No rewrite attempts.").font(.flow(size: 13)).foregroundStyle(.secondary)
      }
      ForEach(model.detailAttempts) { attempt in
        DisclosureGroup(
          "Attempt \(attempt.ordinal) · \(attempt.mode.title) · \(attempt.state.rawValue)"
        ) {
          VStack(alignment: .leading, spacing: 8) {
            Text(summary(attempt)).foregroundStyle(.secondary)
            if attempt.failureCategory == .contextCopied {
              Text(RewriteNotice.text(for: .contextCopied, context: .history))
            }
            Text("Input snapshot").font(.flow(size: 12))
            Text(verbatim: attempt.inputText)
            if let output = attempt.outputText {
              Text("AI-generated rewrite, not the transcript.").font(.flow(size: 12))
              Text(verbatim: output)
              HStack {
                Button("Copy") { copy?(output) }
                  .accessibilityLabel("Copy rewrite attempt \(attempt.ordinal)")
                Button("Insert…") { insert?(attempt) }
                  .disabled(attempt.deliverableText == nil)
                  .accessibilityLabel("Insert rewrite attempt \(attempt.ordinal)")
              }
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.flow(size: 13))
        .accessibilityIdentifier("history.detail.rewrite.attempt.\(attempt.ordinal)")
      }
    }
    .accessibilityIdentifier("history.detail.rewrite")
  }

  private func summary(_ attempt: RewriteAttempt) -> String {
    var parts: [String] = []
    parts.append(
      attempt.spans.durationMilliseconds.map { "\($0) ms total" } ?? "duration unavailable")
    if let first = attempt.spans.firstByteMilliseconds { parts.append("\(first) ms to first byte") }
    if let category = attempt.failureCategory { parts.append(category.rawValue) }
    if attempt.contextHash != nil { parts.append("context sent") }
    if attempt.stale { parts.append("stale") }
    if attempt.delivered { parts.append("delivered") }
    parts.append(attempt.identity.groupKey)
    return parts.joined(separator: " · ")
  }

  private func text(title: String, caption: String, body: String, attempt: RewriteAttempt?)
    -> some View
  {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.flow(size: 12))
      Text(caption).font(.flow(size: 12)).foregroundStyle(.secondary)
      Text(verbatim: body).font(.flow(size: 14)).fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        Button("Copy") { copy?(body) }
          .accessibilityLabel("Copy \(title)")
        Button("Insert…") { insert?(attempt) }
          .accessibilityLabel("Insert \(title)")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

extension TranscriptionQualityDetail.RawWindow {
  var historyLabel: String {
    "Window \(sequence + 1) · samples \(sampleStart)–\(sampleStart + sampleCount)"
  }
}
