import XCTest

final class ModelsTests: XCTestCase {
  private let flowd = [
    "/x/bin/localflow-remote-flowd", "/x/mtplx-api-key", "/x/bin/flowd", "serve", "--listen",
    "127.0.0.1:8091", "--model", "localflow", "--log-file", "/x/flowd.log", "--google-client-id",
    "id",
  ]

  func testSetsAndClearsTheAnalysisBackend() {
    let backend = AnalysisBackend(
      url: "http://127.0.0.1:8443/v1", model: "smart", keyFile: "/x/key")
    let set = AgentArguments.setting(backend, in: flowd)
    XCTAssertEqual(
      Array(set.suffix(6)),
      [
        "--analysis-backend", "http://127.0.0.1:8443/v1", "--analysis-model", "smart",
        "--analysis-backend-key-file", "/x/key",
      ])
    XCTAssertEqual(AgentArguments.analysisBackend(set), backend)
    // Switching replaces rather than appends a second set.
    let switched = AgentArguments.setting(
      AnalysisBackend(url: backend.url, model: "smart:fast", keyFile: nil), in: set)
    XCTAssertEqual(switched.filter { $0 == "--analysis-backend" }.count, 1)
    XCTAssertNil(switched.value(after: "--analysis-backend-key-file"))
    XCTAssertEqual(AgentArguments.setting(nil, in: switched), flowd)
    XCTAssertNil(AgentArguments.analysisBackend(flowd))
  }

  func testReplacesTheRewriteModel() {
    let mtplx = [
      "/usr/bin/env", "MTPLX_CLEAR_CACHE_AFTER_REQUEST=always", "/venv/bin/mtplx", "serve",
      "--port", "8092",
      "--model", "/m/4B", "--model-id", "localflow",
    ]
    let changed = AgentArguments.replacing("--model", with: "/m/9B", in: mtplx)
    XCTAssertEqual(changed?.value(after: "--model"), "/m/9B")
    XCTAssertEqual(changed?.value(after: "--model-id"), "localflow")
    XCTAssertNil(AgentArguments.replacing("--absent", with: "x", in: mtplx))
    XCTAssertEqual(AgentArguments.mtplxExecutable(mtplx), "/venv/bin/mtplx")
  }

  func testParsesModelLists() {
    let mtplx = MTPLXModel.parse(
      Data(
        #"{"cache_dir":"/c","models":[{"repo_id":"Youssofal/Qwen3.5-4B","path":"/c/4B","size_gb":2.567,"validation":{"ok":true}}]}"#
          .utf8))
    XCTAssertEqual(
      mtplx, [MTPLXModel(repoID: "Youssofal/Qwen3.5-4B", path: "/c/4B", sizeGB: 2.567)])
    let omlx = OMLXModel.parse(
      Data(
        #"{"object":"list","data":[{"id":"smart","object":"model","max_model_len":32768},{"id":"smart:fast"}]}"#
          .utf8))
    XCTAssertEqual(omlx.map(\.id), ["smart", "smart:fast"])
    XCTAssertEqual(omlx[0].maxModelLen, 32768)
    XCTAssertEqual(OMLXModel.parse(Data(#"{"error":"unauthorized"}"#.utf8)), [])
  }

  func testWritesOnlyProgramArguments() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".plist")
    defer { try? FileManager.default.removeItem(at: url) }
    let plist: [String: Any] = [
      "Label": "org.localflow.LocalFlow.remote", "ProgramArguments": flowd, "KeepAlive": true,
      "ThrottleInterval": 30,
    ]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(
      to: url)
    try AgentPlist.write(["a", "b"], to: url)
    XCTAssertEqual(AgentPlist.arguments(url), ["a", "b"])
    let back = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        as? [String: Any])
    XCTAssertEqual(back["Label"] as? String, "org.localflow.LocalFlow.remote")
    XCTAssertEqual(back["ThrottleInterval"] as? Int, 30)
    XCTAssertEqual(back["KeepAlive"] as? Bool, true)
  }
}
