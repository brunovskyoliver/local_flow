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
  /// flowd's admin API answers, so a summaries switch applies without a restart.
  private(set) var switchesSummariesLive = false
  /// Why a model list is empty, or nil when discovery worked.
  private(set) var mtplxProblem: String?
  private(set) var omlxProblem: String?
  private(set) var loading = false
  private(set) var progress: String?
  private(set) var outcome: String?
  private(set) var busy = false

  func load() async {
    loading = true
    defer { loading = false }
    let flowdArguments = AgentPlist.arguments(Server.plist) ?? []
    let mtplxArguments = AgentPlist.arguments(Server.mtplxPlist) ?? []
    rewriteModel = mtplxArguments.value(after: "--model")
    analysis = AgentArguments.analysisBackend(flowdArguments)
    if let mtplx = AgentArguments.mtplxExecutable(mtplxArguments) {
      let listed = await runProcess(mtplx, ["models", "--json"])
      mtplxModels = MTPLXModel.parse(Data(listed.output.utf8))
      mtplxProblem = ModelDiscovery.mtplxProblem(listed, models: mtplxModels)
    } else {
      mtplxModels = []
      mtplxProblem = "The MTPLX agent plist names no MTPLX executable."
    }
    (omlxModels, omlxProblem) = await Self.omlxModels()
    switchesSummariesLive = await AdminAPI.status() != nil
    // Builds before b26a743 refuse --analysis-backend and would never come up.
    let help = await runProcess(Server.flowd.path, ["serve", "-h"])
    flowdKnowsAnalysisBackend = (help.output + help.error).contains("-analysis-backend")
  }

  /// oMLX's models, authenticated with the key from its own settings, or why there are
  /// none. The key stays in memory for this request.
  nonisolated private static func omlxModels() async -> ([OMLXModel], String?) {
    var request = URLRequest(url: Server.omlx.appending(path: "v1/models"), timeoutInterval: 3)
    if let key = omlxKey() {
      request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
    let data: Data
    let response: URLResponse
    do { (data, response) = try await URLSession.shared.data(for: request) } catch {
      let reason = error.localizedDescription
      return ([], "oMLX did not answer at \(Server.omlx.absoluteString): \(reason)")
    }
    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
      return ([], "oMLX answered HTTP \(http.statusCode).")
    }
    let models = OMLXModel.parse(data)
    return (models, models.isEmpty ? "oMLX lists no models." : nil)
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
    let changed = AgentArguments.setting(backend, in: arguments)
    // With flowd's admin API the switch needs no restart; the plist keeps it for the next start.
    if await AdminAPI.status() != nil {
      guard
        let status = await AdminAPI.setAnalysis(backend: Self.omlxBackend, model: backend?.model)
      else { return finish(.failed("flowd's admin API refused the switch; nothing changed.")) }
      do { try AgentPlist.write(changed, to: Server.plist) } catch {
        return finish(
          .failed("Switched in flowd, but could not save the plist: \(error.localizedDescription)"))
      }
      progress = nil
      busy = false
      outcome =
        "Switched without a restart to \(status.analysis.model.nonEmpty ?? "the rewrite model")."
      return await load()
    }
    let outcome = await AgentChange.apply(
      label: Server.label, plist: Server.plist,
      arguments: changed,
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
  @State private var confirm: ModelChange?

  var body: some View {
    Form {
      Section("Rewrite model (MTPLX)") {
        Picker("Model", selection: $rewriteSelection) {
          ForEach(model.mtplxModels) { pack in
            Text("\(pack.repoID)  \(pack.sizeGB.map { String(format: "%.1f GB", $0) } ?? "")")
              .tag(pack.path)
          }
        }
        if let problem = model.mtplxProblem { discoveryProblem(problem) }
        HStack {
          Text(
            "Current: \(model.rewriteModel.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "–")"
          )
          .foregroundStyle(.secondary)
          Spacer()
          Button("Apply…") { confirm = .rewrite(path: rewriteSelection) }
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
        if let problem = model.omlxProblem { discoveryProblem(problem) }
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
            confirm = .summaries(
              omlxModel: analysisSelection.isEmpty ? nil : analysisSelection, copyKey: copyKey,
              live: model.switchesSummariesLive)
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
          "A rewrite model change restarts MTPLX. "
            + (model.switchesSummariesLive
              ? "A summaries change applies live through flowd's admin API."
              : "A summaries change restarts flowd.")
            + " A restart that does not report healthy within 60 seconds restores the previous plist."
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
    // After an Apply the pickers show what is actually running, including a rollback.
    .onChange(of: model.rewriteModel) { _, applied in rewriteSelection = applied ?? "" }
    .onChange(of: model.analysis?.model) { _, applied in analysisSelection = applied ?? "" }
    .confirmationDialog(
      confirm?.confirmTitle ?? "",
      isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })
    ) {
      Button(confirm?.confirmButton ?? "Apply") {
        guard let change = confirm else { return }
        Task { await apply(change) }
      }
    } message: {
      Text(confirm?.confirmMessage ?? "")
    }
  }

  private func apply(_ change: ModelChange) async {
    switch change {
    case .rewrite(let path): await model.applyRewriteModel(path)
    case .summaries(let omlxModel, let copyKey, _):
      await model.applyAnalysis(omlxModel: omlxModel, copyKey: copyKey)
    }
  }

  private func discoveryProblem(_ problem: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
      Spacer()
      if model.loading {
        ProgressView().controlSize(.small)
      } else {
        Button("Retry") { Task { await model.load() } }
      }
    }
  }
}
