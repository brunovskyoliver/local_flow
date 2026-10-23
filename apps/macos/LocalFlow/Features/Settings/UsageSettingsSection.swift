import SwiftUI

struct UsageSettingsSection: View {
  @Bindable var model: UsageReportingModel
  @State private var confirmingEnable = false
  @State private var confirmingDelete = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Usage sharing").font(.flow(size: 16, weight: .medium))
      Text(
        "Optionally share daily dictation counts and audio duration, including local processing, with your server owner. These totals are linked to your approved account and kept for 90 days. Audio, dictated text and field context are never included."
      )
      .font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
      .fixedSize(horizontal: false, vertical: true)
      Toggle(
        "Share usage with my server owner",
        isOn: Binding(
          get: { model.enabled },
          set: { value in
            if value { confirmingEnable = true } else { Task { await model.disable() } }
          })
      )
      .toggleStyle(.switch)
      .disabled(!model.enabled && (model.busy || !model.canEnable))
      .accessibilityIdentifier("settings.usageSharing")
      Text(model.notice).font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
        .fixedSize(horizontal: false, vertical: true)
      if !model.available {
        Text("Connect an approved account in Server settings to enable sharing.")
          .font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
      }
      HStack {
        Button("Retry reporting") { Task { await model.synchronize() } }
          .disabled(model.busy || !model.available)
        Button("Delete this device's shared usage…") { confirmingDelete = true }
          .disabled(model.busy)
      }.buttonStyle(PrototypeButtonStyle())
      if let date = model.lastReport {
        Text("Last report: \(date.formatted(date: .abbreviated, time: .shortened))")
          .font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
      }
    }
    .padding(.top, 24)
    .confirmationDialog(
      "Share daily usage with your server owner?", isPresented: $confirmingEnable,
      titleVisibility: .visible
    ) {
      Button("Enable usage sharing") { Task { await model.enable() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Your approved account will be associated with counts and audio duration from this Mac. Earlier dictations are not uploaded. You can stop sharing and delete shared usage here."
      )
    }
    .confirmationDialog(
      "Delete this device's shared usage?", isPresented: $confirmingDelete,
      titleVisibility: .visible
    ) {
      Button("Delete shared usage", role: .destructive) {
        Task { await model.disable(delete: true) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This stops sharing and requests removal of all retained reporting periods for this device. Dictation history is kept. Hosted removal needs a connection to your server."
      )
    }
  }
}
