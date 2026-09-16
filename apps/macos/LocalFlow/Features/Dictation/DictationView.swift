import SwiftUI

// Presentation adapted from Sotto's DictationPage. Copyright (c) 2026 Davis, MIT.
// LocalFlow owns capture, model lifecycle, persistence and delivery.
struct DictationView: View {
  let services: AppServices

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        HStack(spacing: 20) {
          Image(systemName: "globe")
            .font(.system(size: 28, weight: .light))
            .frame(width: 66, height: 66)
            .background(SottoPalette.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(SottoPalette.line, lineWidth: 1))
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 6) {
            Text("Hold to dictate.").font(.system(size: 26, weight: .semibold))
            Text("Speak in Slovak, English, or both.").foregroundStyle(SottoPalette.muted)
          }
          Spacer(minLength: 0)
        }
        .padding(.top, 8)
        HStack(alignment: .top, spacing: 12) {
          Label(
            services.readinessStatus,
            systemImage: services.needsAttention ? "exclamationmark.circle" : "mic"
          )
          .font(.callout)
          Spacer(minLength: 0)
          Button("Settings") { services.router.selection = .settings }
        }
        VStack(alignment: .leading, spacing: 14) {
          HStack {
            Text(services.coordinator?.busy == true ? "Current dictation" : "Last dictation").font(
              .headline)
            Spacer()
            if let entry = services.coordinator?.history.first {
              Button {
                services.coordinator?.copy(entry.text)
              } label: {
                Label("Copy", systemImage: "doc.on.doc")
              }
              .disabled(services.coordinator?.busy == true)
            }
          }
          Divider()
          if services.coordinator?.busy == true {
            Text(services.coordinator?.status ?? "Preparing…").foregroundStyle(SottoPalette.muted)
            Button("Cancel dictation") { services.coordinator?.cancel() }
          } else if let entry = services.coordinator?.history.first {
            Text(entry.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if entry.quality != .complete {
              Label(
                entry.quality == .durationLimited ? "Cut short at 180 seconds" : "Incomplete",
                systemImage: "exclamationmark.circle"
              )
              .font(.caption)
            }
            if entry.recoveryState == .needsReview {
              Label(
                entry.deliveryState == .uncertain || entry.deliveryState == .attempting
                  ? "Delivery uncertain. Check the destination before inserting again."
                  : "Saved for review", systemImage: "tray"
              )
              .font(.caption)
            }
          } else {
            Text("Your next dictation will appear here.")
              .foregroundStyle(SottoPalette.muted)
              .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
          }
        }
        .padding(20)
        .background(SottoPalette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(SottoPalette.line, lineWidth: 1))
        HStack {
          Text("Saved text stays until you delete it.").font(.callout).foregroundStyle(
            SottoPalette.muted)
          Spacer()
          Button("View history") { services.router.selection = .history }
        }
        VStack(alignment: .leading, spacing: 8) {
          Text("Ready when you hold the shortcut").font(.headline)
          Text(
            "Wait for the recording waveform, speak, then release. Speech is processed on this Mac. If insertion is unavailable, your text stays in History for Copy."
          )
          .foregroundStyle(SottoPalette.muted)
          Text(
            "Each recording can last up to 180 seconds. Recordings are removed after processing."
          )
          .font(.caption).foregroundStyle(SottoPalette.muted)
        }
      }
      .padding(26)
      .frame(maxWidth: 940, alignment: .leading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task(id: services.coordinator.map(ObjectIdentifier.init)) {
      services.coordinator?.setPreviewEnabled(true)
      await services.coordinator?.refreshHistory()
    }
    .onDisappear { services.coordinator?.setPreviewEnabled(false) }
  }
}
