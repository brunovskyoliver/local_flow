import SwiftUI

/// Settings › Known speakers (contracts/ui.md, FR-042, FR-043): each profile with its
/// name, sample count and recognition switch, inline rename, delete with confirmation,
/// and a disclosure to the sample list. Nothing here shows a vector, score or audio.
struct KnownSpeakersView: View {
  @State var model: KnownSpeakersModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if model.rows.isEmpty {
        Text(model.isLoading ? "Loading…" : "No known speakers yet.")
          .font(.system(size: 12)).foregroundStyle(SottoPalette.muted)
          .padding(.vertical, 14)
      }
      ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
        if index > 0 { SottoPalette.line.frame(height: 1) }
        speakerRow(row)
        if model.expanded == row.id { sampleList(row) }
      }
      if let notice = model.notice {
        Text(notice).font(.system(size: 12)).foregroundStyle(SottoPalette.warning)
          .padding(.vertical, 8)
          .accessibilityIdentifier("settings.knownSpeakers.notice")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings.knownSpeakers")
    .task { await model.load() }
    .sheet(
      isPresented: Binding(
        get: { model.pendingDelete != nil }, set: { if !$0 { model.cancelDelete() } })
    ) {
      deleteSheet
    }
  }

  private func speakerRow(_ row: KnownSpeakerRow) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        if model.renaming == row.id {
          TextField("Name", text: $model.renameDraft)
            .textFieldStyle(.roundedBorder).frame(width: 220)
            .onSubmit { Task { await model.commitRename() } }
            .onExitCommand { model.cancelRename() }
            .accessibilityIdentifier("settings.knownSpeakers.rename")
          if let error = model.renameError {
            Text(error).font(.system(size: 11)).foregroundStyle(SottoPalette.warning)
          }
        } else {
          HStack(spacing: 8) {
            Text(row.name).font(.system(size: 14))
            if row.isLocalUser {
              Text("You").font(.system(size: 11)).foregroundStyle(SottoPalette.muted)
            }
            if KnownSpeakersModel.needsReenrollment(row) {
              Text("Needs re-enrollment").font(.system(size: 11))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(SottoPalette.surface, in: Capsule())
                .foregroundStyle(SottoPalette.muted)
                .accessibilityIdentifier("settings.knownSpeakers.needsReenrollment")
            }
          }
          Button(KnownSpeakersModel.sampleCountText(row)) {
            Task { await model.toggleSamples(row.id) }
          }
          .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(SottoPalette.muted)
          .accessibilityIdentifier("settings.knownSpeakers.samples")
        }
      }
      Spacer(minLength: 0)
      Toggle(
        "Recognize",
        isOn: Binding(
          get: { row.recognitionEnabled },
          set: { value in Task { await model.setRecognition(row.id, enabled: value) } })
      )
      .labelsHidden().toggleStyle(.switch)
      .accessibilityLabel("Recognize \(row.name)")
      .accessibilityIdentifier("settings.knownSpeakers.recognition")
      Menu {
        Button("Rename") { model.beginRename(row.id) }
        Button("Delete…", role: .destructive) { model.requestDelete(row.id) }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton).fixedSize()
      .accessibilityLabel("Actions for \(row.name)")
    }
    .padding(.vertical, 12)
  }

  private func sampleList(_ row: KnownSpeakerRow) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      let samples = model.samples[row.id] ?? []
      if samples.isEmpty {
        Text("No voice samples.").font(.system(size: 12)).foregroundStyle(SottoPalette.muted)
      }
      ForEach(samples) { sample in
        HStack(spacing: 10) {
          Text(KnownSpeakersModel.sourceText(sample)).font(.system(size: 12))
          Text(KnownSpeakersModel.durationText(sample)).font(.system(size: 12))
            .foregroundStyle(SottoPalette.muted).monospacedDigit()
          Text(KnownSpeakersModel.qualityText(sample)).font(.system(size: 12))
            .foregroundStyle(SottoPalette.muted)
          Spacer(minLength: 0)
          Button("Remove") { Task { await model.removeSample(sample.id, of: row.id) } }
            .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
            .accessibilityLabel("Remove voice sample")
        }
        .accessibilityElement(children: .contain)
      }
    }
    .padding(.leading, 12).padding(.bottom, 12)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings.voiceSamples")
  }

  private var deleteSheet: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(KnownSpeakersModel.deleteConfirmation(for: model.pendingDelete?.name ?? ""))
        .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("settings.knownSpeakers.deleteConfirmation")
      HStack {
        Spacer()
        Button("Cancel") { model.cancelDelete() }.keyboardShortcut(.cancelAction)
        Button("Delete", role: .destructive) { Task { await model.confirmDelete() } }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("settings.knownSpeakers.delete")
      }
    }
    .padding(20).frame(width: 380)
  }
}
