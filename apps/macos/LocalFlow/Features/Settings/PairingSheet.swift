import LocalFlowCore
import SwiftUI

/// Feature 027: the address, the token and the existing consent text. Pair connects;
/// opening a link only fills this in.
struct PairingSheet: View {
  @Bindable var model: RemoteDictationModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Pair with a token").font(.flow(size: 17, weight: .medium))
      RewriteInputSurface(symbol: "server.rack") {
        TextField("https://server.example.com" as String, text: $model.serverDraft)
          .accessibilityIdentifier("settings.remoteServerURL")
      }
      RewriteInputSurface(symbol: "key") {
        SecureField("lfp_…", text: $model.pairingToken)
          .accessibilityIdentifier("settings.remotePairToken")
      }
      Text(model.currentConsentText).font(.flow(size: 13)).lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
      if let notice = RemoteDictationSettings.addressNotice(model.serverDraft) {
        Text(notice).font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let origin = model.draftOrigin {
        Text("Server: \(origin.host() ?? origin.absoluteString)").font(
          .flow(size: 13, weight: .medium))
      }
      if let error = model.error {
        Text(error).font(.flow(size: 12)).foregroundStyle(SottoPalette.warning)
      }
      HStack {
        Spacer()
        Button("Cancel") { model.cancelPairing() }.keyboardShortcut(.cancelAction)
        Button("Pair") { Task { await model.confirmPairing() } }
          .keyboardShortcut(.defaultAction).disabled(!model.canConfirmPairing)
          .accessibilityIdentifier("settings.remotePairConfirm")
      }
    }
    .padding(24).frame(width: 460)
  }
}
