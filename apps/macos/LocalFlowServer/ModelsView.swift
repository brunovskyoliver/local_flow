import Observation
import SwiftUI

@MainActor @Observable
final class ModelsModel {
  static let omlxBackend = Server.omlx.appending(path: "v1").absoluteString
  static var analysisKeyFile: URL { Server.dataDir.appending(path: "analysis-api-key") }

  private(set) var mtplxModels: [MTPLXModel] = []
  private(set) var omlxModels: [OMLXModel] = []
  private(set) var rewriteModel: String?
  private(set) var analysis: AnalysisBackend?
  private(set) var flowdKnowsAnalysisBackend = false
  private(set) var progress: String?
  private(set) var outcome: String?
  private(set) var busy = false

  func load() async {
    let flowdArguments = AgentPlist.arguments(Server.plist) ?? []
    let mtplxArguments = AgentPlist.arguments(Server.mtplxPlist) ?? []
    rewriteModel = mtplxArguments.value(after: "--model")
    analysis = AgentArguments.analysisBackend(flowdArguments)
    if let mtplx = AgentArguments.mtplxExecutable(mtplxArguments) {
      mtplxModels = MTPLXModel.parse(
        Data(await runProcess(mtplx, ["models", "--json"]).output.utf8))
    }
    omlxModels = await Self.omlxModels()
    // Builds before b26a743 refuse --analysis-backend and would never come up.
    let help = await runProcess(Server.flowd.path, ["serve", "-h"])
    flowdKnowsAnalysisBackend = (help.output + help.error).contains("-analysis-backend")
  }

  /// oMLX's models, authenticated with the key from its own settings. The key stays in
  /// memory for this request.
  nonisolated private static func omlxModels() async -> [OMLXModel] {
    var request = URLRequest(url: Server.omlx.appending(path: "v1/models"), timeoutInterval: 3)
    if let key = omlxKey() {
      request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
    guard let (data, _) = try? await URLSession.shared.data(for: request) else { return [] }
    return OMLXModel.parse(data)
  }

  nonisolated private static func omlxKey() -> String? {
    guard let data = try? Data(contentsOf: Server.omlxSettings),
      let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let auth = settings["auth"] as? [String: Any], let key = auth["api_key"] as? String,
      !key.isEmpty
    else { return nil }
    return key
  }

  func applyRewriteModel(_ path: String) async {
    guard let arguments = AgentPlist.arguments(Server.mtplxPlist),
      let changed = AgentArguments.replacing("--model", with: path, in: arguments)
    else { return finish(.failed("The MTPLX plist has no --model argument.")) }
    busy = true
    let outcome = await AgentChange.apply(
      label: Server.mtplxLabel, plist: Server.mtplxPlist, arguments: changed,
      progress: { self.progress = $0 },
      healthy: { previous in
        guard let job = await Launchctl.job(Server.mtplxLabel), job.running, job.pid != previous
        else { return false }
        return await ServerMonitor.health("/v1/rewrite/health")?.backend.state == "ready"
      })
    finish(outcome)
  }

  /// nil sends summaries back to the rewrite model.
  func applyAnalysis(omlxModel: String?, copyKey: Bool) async {
    guard let arguments = AgentPlist.arguments(Server.plist) else {
      return finish(.failed("Could not read \(Server.plist.lastPathComponent)."))
    }
    busy = true
    var backend: AnalysisBackend?
    if let omlxModel {
      if copyKey, let key = Self.omlxKey() {
        guard
          FileManager.default.createFile(
            atPath: Self.analysisKeyFile.path, contents: Data(key.utf8),
            attributes: [.posixPermissions: 0o600])
        else {
          return finish(.failed("Could not write \(Self.analysisKeyFile.lastPathComponent)."))
        }
      }
      let keyFile = FileManager.default.fileExists(atPath: Self.analysisKeyFile.path)
      backend = AnalysisBackend(
        url: Self.omlxBackend, model: omlxModel, keyFile: keyFile ? Self.analysisKeyFile.path : nil)
    }
    let outcome = await AgentChange.apply(
      label: Server.label, plist: Server.plist,
      arguments: AgentArguments.setting(backend, in: arguments),
      progress: { self.progress = $0 },
      healthy: { previous in
        guard let job = await Launchctl.job(Server.label), job.running, job.pid != previous
        else { return false }
        async let rewrite = ServerMonitor.health("/v1/rewrite/health")
        async let analysis = ServerMonitor.health("/v1/analysis/health")
        let (rewriteOK, analysisOK) = await (rewrite != nil, analysis != nil)
        return rewriteOK && analysisOK
      })
    finish(outcome)
  }

  private func finish(_ result: AgentChange.Outcome) {
    switch result {
    case .applied: outcome = "Applied."
    case .rolledBack(let reason): outcome = "Rolled back: \(reason)"
    case .failed(let reason): outcome = reason
    }
    progress = nil
    busy = false
    Task { await load() }
  }
}

struct ModelsView: View {
  let model: ModelsModel
  @State private var rewriteSelection = ""
  @State private var analysisSelection = ""  // "" is the rewrite model
  @State private var copyKey = true
  @State private var confirm: (() async -> Void)?

  var body: some View {
    Form {
      Section("Rewrite model (MTPLX)") {
        Picker("Model", selection: $rewriteSelection) {
          ForEach(model.mtplxModels) { pack in
            Text("\(pack.repoID)  \(pack.sizeGB.map { String(format: "%.1f GB", $0) } ?? "")")
              .tag(pack.path)
          }
        }
        HStack {
          Text(
            "Current: \(model.rewriteModel.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "–")"
          )
          .foregroundStyle(.secondary)
          Spacer()
          Button("Apply…") {
            let path = rewriteSelection
            confirm = { await model.applyRewriteModel(path) }
          }
          .disabled(rewriteSelection.isEmpty || rewriteSelection == model.rewriteModel)
        }
      }
      Section("Summaries") {
        Picker("Backend", selection: $analysisSelection) {
          Text("The rewrite model (MTPLX)").tag("")
          ForEach(model.omlxModels) { item in
            Text("oMLX: \(item.id)\(item.maxModelLen.map { "  (\($0 / 1024)K context)" } ?? "")")
              .tag(item.id)
          }
        }
        if !analysisSelection.isEmpty {
          Toggle("Copy oMLX's API key to analysis-api-key (0600) for flowd", isOn: $copyKey)
        }
        if !model.flowdKnowsAnalysisBackend {
          Text("This flowd does not accept --analysis-backend. Update the server first.")
            .foregroundStyle(.orange)
        }
        HStack {
          Text(
            "Current: \(model.analysis.map { "\($0.model) at \($0.url)" } ?? "the rewrite model")"
          )
          .foregroundStyle(.secondary)
          Spacer()
          Link("oMLX Dashboard", destination: Server.omlx.appending(path: "admin"))
          Button("Apply…") {
            let (selection, copy) = (analysisSelection, copyKey)
            confirm = {
              await model.applyAnalysis(
                omlxModel: selection.isEmpty ? nil : selection, copyKey: copy)
            }
          }
          .disabled(
            analysisSelection == (model.analysis?.model ?? "")
              || (!analysisSelection.isEmpty && !model.flowdKnowsAnalysisBackend))
        }
      }
      Section {
        if let progress = model.progress {
          HStack {
            ProgressView().controlSize(.small)
            Text(progress)
          }
        }
        if let outcome = model.outcome { Text(outcome) }
        Text(
          "Apply rewrites the agent's plist and restarts it: remote dictation stops for about 30 seconds. If the agent does not report healthy within 60 seconds, the previous plist is restored."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .disabled(model.busy)
    .task {
      await model.load()
      rewriteSelection = model.rewriteModel ?? ""
      analysisSelection = model.analysis?.model ?? ""
    }
    .confirmationDialog(
      "Restart the agent?",
      isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })
    ) {
      Button("Apply and Restart") {
        guard let confirm else { return }
        Task { await confirm() }
      }
    } message: {
      Text("Remote dictation stops for about 30 seconds.")
    }
  }
}
