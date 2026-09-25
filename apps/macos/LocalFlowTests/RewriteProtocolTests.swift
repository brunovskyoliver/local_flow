import XCTest

@testable import LocalFlow

/// Every client validation rule in `contracts/rewrite-protocol.md`, exercised
/// against authored event bytes. No network and no fake server are involved.
final class RewriteProtocolTests: XCTestCase {
  private let requestID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

  private func request(text: String = "peter can you move the deployment") throws
    -> RewriteRequest
  {
    try RewriteRequest(requestID: requestID, mode: .clean, text: text)
  }

  private func resultLine(
    id: String? = nil, mode: String = "clean", text: Any = "Peter, can you move the deployment?",
    schemaVersion: Any = 1, dropping: [String] = [],
    timing: Any = ["queue_ms": 3, "backend_ms": 611]
  ) throws -> Data {
    var object: [String: Any] = [
      "event": "result", "schema_version": schemaVersion,
      "request_id": id ?? requestID.uuidString, "mode": mode, "text": text, "unchanged": false,
      "server": ["name": "flowd", "version": "0.2.0"],
      "backend": ["kind": "openai-compatible", "model": "qwen2.5-3b"],
      "prompt_version": 1, "shield": ["version": 1, "placeholders": 2, "restored": 2],
      "timing": timing,
    ]
    for key in dropping { object.removeValue(forKey: key) }
    return try JSONSerialization.data(withJSONObject: object)
  }

  private func events(_ lines: [Data]) throws -> [RewriteEvent] {
    try lines.map { try RewriteEvent.decode(line: $0) }
  }

  private func category(_ body: () throws -> Void) -> RewriteFailureCategory? {
    do {
      try body()
      return nil
    } catch let failure as RewriteFailure {
      return failure.category
    } catch {
      XCTFail("unexpected error \(error)")
      return nil
    }
  }

  // MARK: Request

  func testClientV1HasEmptyHintsAndNoTranslationFields() throws {
    let value = try request()
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    XCTAssertEqual(object["language_hints"] as? [String], [])
    XCTAssertEqual(
      Set(object.keys),
      ["schema_version", "request_id", "mode", "text", "language_hints", "stream_deltas"])
    XCTAssertThrowsError(
      try RewriteRequest(
        requestID: requestID, mode: .clean, text: "Hello",
        languageHints: ["en", "sk", "de", "fr", "es"]))
    // English and Slovak only, each at most once.
    for hints in [["cs"], ["en-US"], ["sk", "sk"], [""]] {
      XCTAssertThrowsError(
        try RewriteRequest(requestID: requestID, mode: .clean, text: "Hello", languageHints: hints),
        "\(hints)")
    }
    XCTAssertNoThrow(
      try RewriteRequest(
        requestID: requestID, mode: .clean, text: "Hello", languageHints: ["sk", "en"]))
  }

  func testRequestEncodesOnlyTheSixPermittedFields() throws {
    let request = try RewriteRequest(
      requestID: requestID, mode: .polished, text: "hello", languageHints: ["sk", "en"],
      streamDeltas: true)
    let data = try JSONEncoder().encode(request)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(
      Set(object.keys),
      ["schema_version", "request_id", "mode", "text", "language_hints", "stream_deltas"])
    XCTAssertEqual(object["schema_version"] as? Int, 1)
    XCTAssertEqual(object["request_id"] as? String, requestID.uuidString)
    XCTAssertEqual(object["mode"] as? String, "polished")
    XCTAssertEqual(object["text"] as? String, "hello")
    XCTAssertEqual(object["language_hints"] as? [String], ["sk", "en"])
    XCTAssertEqual(object["stream_deltas"] as? Bool, true)
    XCTAssertEqual(request.inputBytes, 5)
  }

  func testRequestRejectsExactModeBlankOrOversizedInput() {
    XCTAssertEqual(
      category { _ = try RewriteRequest(requestID: requestID, mode: .exact, text: "x") },
      .invalidSettings)
    XCTAssertEqual(
      category { _ = try RewriteRequest(requestID: requestID, mode: .clean, text: " \n") },
      .invalidSettings)
    let scalars = String(repeating: "a", count: 20_001)
    XCTAssertEqual(
      category { _ = try RewriteRequest(requestID: requestID, mode: .clean, text: scalars) },
      .inputTooLarge)
    // 16,385 four-byte scalars fit the scalar bound but not the byte bound.
    let bytes = String(repeating: "\u{1F600}", count: 16_385)
    XCTAssertEqual(
      category { _ = try RewriteRequest(requestID: requestID, mode: .clean, text: bytes) },
      .inputTooLarge)
    XCTAssertNil(
      category {
        _ = try RewriteRequest(
          requestID: requestID, mode: .clean, text: String(repeating: "a", count: 20_000))
      })
    XCTAssertEqual(
      category {
        _ = try RewriteRequest(
          requestID: requestID, mode: .clean, text: "x", languageHints: ["a", "b", "c", "d", "e"])
      }, .invalidSettings)
  }

  func testBoundsFollowTheContractFormulas() {
    XCTAssertEqual(RewriteBounds.maximumResponseBytes(inputBytes: 100), 8_592)
    XCTAssertEqual(RewriteBounds.maximumResponseBytes(inputBytes: 65_536), 73_728)
    XCTAssertEqual(RewriteBounds.maximumResponseBytes(inputBytes: 16_384), 73_728)
    XCTAssertEqual(RewriteBounds.maximumResponseBytes(inputBytes: 16_383), 73_724)
    XCTAssertEqual(RewriteBounds.maximumResultBytes(inputBytes: 100), 400)
    XCTAssertEqual(RewriteBounds.maximumResultBytes(inputBytes: 65_536), 65_536)
    XCTAssertEqual(RewriteBounds.maximumResultBytes(inputBytes: 16_385), 65_536)
    XCTAssertEqual(RewriteBounds.maximumLineBytes, 8_192)
    XCTAssertEqual(RewriteBounds.maximumInputScalars, 20_000)
    XCTAssertEqual(RewriteBounds.maximumInputBytes, 65_536)
  }

  // MARK: Line decoding (rule 2)

  func testNonObjectOrMissingEventLineIsMalformed() {
    XCTAssertEqual(
      category { _ = try RewriteEvent.decode(line: Data("[1,2]".utf8)) }, .malformedResponse)
    XCTAssertEqual(
      category { _ = try RewriteEvent.decode(line: Data("not json".utf8)) }, .malformedResponse)
    XCTAssertEqual(
      category { _ = try RewriteEvent.decode(line: Data(#"{"request_id":"x"}"#.utf8)) },
      .malformedResponse)
    XCTAssertEqual(
      category { _ = try RewriteEvent.decode(line: Data(#"{"event":7}"#.utf8)) },
      .malformedResponse)
  }

  func testEachEventTypeRoundTrips() throws {
    let id = requestID.uuidString
    let decoded = try events([
      Data(#"{"event":"accepted","request_id":"\#(id)"}"#.utf8),
      Data(#"{"event":"progress","request_id":"\#(id)","generated_chars":42}"#.utf8),
      Data(#"{"event":"delta","request_id":"\#(id)","text":"Peter, "}"#.utf8),
      try resultLine(),
      Data(
        #"{"event":"error","request_id":"\#(id)","code":"backend_unavailable","message":"Backend is down."}"#
          .utf8),
      Data(#"{"event":"heartbeat","request_id":"\#(id)"}"#.utf8),
    ])
    XCTAssertEqual(decoded[0], .accepted(requestID: id))
    XCTAssertEqual(decoded[1], .progress(requestID: id, generatedChars: 42))
    XCTAssertEqual(decoded[2], .delta(requestID: id, text: "Peter, "))
    guard case .result(let payload) = decoded[3] else { return XCTFail("result expected") }
    XCTAssertEqual(payload.text, "Peter, can you move the deployment?")
    XCTAssertEqual(payload.server?.name, "flowd")
    XCTAssertEqual(payload.timing?.backendMilliseconds, 611)
    XCTAssertNil(payload.timing?.backendFirstTokenMilliseconds)
    XCTAssertEqual(
      decoded[4], .error(requestID: id, code: "backend_unavailable", message: "Backend is down."))
    XCTAssertEqual(decoded[5], .other(requestID: id))
    XCTAssertTrue(decoded[3].isTerminal)
    XCTAssertTrue(decoded[4].isTerminal)
    XCTAssertFalse(decoded[0].isTerminal)
  }

  // MARK: Result validation (rules 3 to 9)

  func testValidResultProducesValidatedTextAndRecomputedUnchanged() throws {
    let request = try request()
    let result = try RewriteResultValidator.validate(
      events: try events([
        Data(#"{"event":"accepted","request_id":"\#(requestID.uuidString)"}"#.utf8),
        try resultLine(),
      ]),
      for: request, inputBytes: request.inputBytes)
    XCTAssertEqual(result.text, "Peter, can you move the deployment?")
    XCTAssertFalse(result.unchanged)
    XCTAssertEqual(result.serverName, "flowd")
    XCTAssertEqual(result.serverVersion, "0.2.0")
    XCTAssertEqual(result.backendKind, "openai-compatible")
    XCTAssertEqual(result.backendModel, "qwen2.5-3b")
    XCTAssertEqual(result.promptVersion, 1)
    XCTAssertEqual(result.shieldVersion, 1)
    XCTAssertEqual(result.serverQueueMilliseconds, 3)
    XCTAssertNil(result.backendFirstTokenMilliseconds)
    XCTAssertEqual(result.backendMilliseconds, 611)
  }

  func testUnchangedIsRecomputedLocallyNotTrusted() throws {
    let request = try request()
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try resultLine(text: request.text)) as? [String: Any])
    object["unchanged"] = false
    let result = try RewriteResultValidator.validate(
      events: try events([try JSONSerialization.data(withJSONObject: object)]),
      for: request, inputBytes: request.inputBytes)
    XCTAssertTrue(result.unchanged)
  }

  func testUnsupportedSchemaVersion() throws {
    let request = try request()
    XCTAssertEqual(
      category {
        _ = try RewriteResultValidator.validate(
          events: try events([try resultLine(schemaVersion: 2)]), for: request,
          inputBytes: request.inputBytes)
      }, .unsupportedSchemaVersion)
    XCTAssertEqual(
      category {
        _ = try RewriteResultValidator.validate(
          events: try events([try resultLine(dropping: ["schema_version"])]), for: request,
          inputBytes: request.inputBytes)
      }, .unsupportedSchemaVersion)
  }

  func testRequestMismatchOnAnyEvent() throws {
    let request = try request()
    XCTAssertEqual(
      category {
        _ = try RewriteResultValidator.validate(
          events: try events([try resultLine(id: UUID().uuidString)]), for: request,
          inputBytes: request.inputBytes)
      }, .requestMismatch)
    XCTAssertEqual(
      category {
        _ = try RewriteResultValidator.validate(
          events: try events([
            Data(#"{"event":"accepted","request_id":"\#(UUID().uuidString)"}"#.utf8),
            try resultLine(),
          ]), for: request, inputBytes: request.inputBytes)
      }, .requestMismatch)
    XCTAssertEqual(
      category {
        _ = try RewriteResultValidator.validate(
          events: try events([Data(#"{"event":"accepted"}"#.utf8), try resultLine()]),
          for: request, inputBytes: request.inputBytes)
      }, .malformedResponse)
  }

  func testModeMismatchIsMalformed() throws {
    let request = try request()
    XCTAssertEqual(
      category {
        _ = try RewriteResultValidator.validate(
          events: try events([try resultLine(mode: "polished")]), for: request,
          inputBytes: request.inputBytes)
      }, .malformedResponse)
  }

  func testBlankOrNonStringTextIsEmptyResponse() throws {
    let request = try request()
    XCTAssertEqual(
      category {
        _ = try RewriteResultValidator.validate(
          events: try events([try resultLine(text: " \n\t")]), for: request,
          inputBytes: request.inputBytes)
      }, .emptyResponse)
    XCTAssertEqual(
      category {
        _ = try RewriteResultValidator.validate(
          events: try events([try resultLine(text: 12)]), for: request,
          inputBytes: request.inputBytes)
      }, .malformedResponse)
  }

  func testResultTextCapIsFourTimesInputBoundedBySixtyFourKiB() throws {
    let request = try request(text: "abcde")
    XCTAssertEqual(request.inputBytes, 5)
    XCTAssertNil(
      category {
        _ = try RewriteResultValidator.validate(
          events: try events([try resultLine(text: String(repeating: "b", count: 20))]),
          for: request, inputBytes: request.inputBytes)
      })
    XCTAssertEqual(
      category {
        _ = try RewriteResultValidator.validate(
          events: try events([try resultLine(text: String(repeating: "b", count: 21))]),
          for: request, inputBytes: request.inputBytes)
      }, .oversizedResponse)
    let large = try self.request(text: String(repeating: "a", count: 20_000))
    XCTAssertEqual(
      category {
        _ = try RewriteResultValidator.validate(
          events: try events([try resultLine(text: String(repeating: "b", count: 65_537))]),
          for: large, inputBytes: large.inputBytes)
      }, .oversizedResponse)
  }

  func testMissingIdentityOrTimingFieldsAreMalformed() throws {
    let request = try request()
    for field in ["server", "backend", "prompt_version", "shield", "timing"] {
      XCTAssertEqual(
        category {
          _ = try RewriteResultValidator.validate(
            events: try events([try resultLine(dropping: [field])]), for: request,
            inputBytes: request.inputBytes)
        }, .malformedResponse, field)
    }
    XCTAssertEqual(
      category {
        _ = try RewriteResultValidator.validate(
          events: try events([try resultLine(timing: "fast")]), for: request,
          inputBytes: request.inputBytes)
      }, .malformedResponse)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try resultLine()) as? [String: Any])
    object["prompt_version"] = "1"
    XCTAssertEqual(
      category {
        _ = try RewriteResultValidator.validate(
          events: try events([try JSONSerialization.data(withJSONObject: object)]),
          for: request, inputBytes: request.inputBytes)
      }, .malformedResponse)
    object["prompt_version"] = 1
    object["server"] = ["name": "flowd"]
    XCTAssertEqual(
      category {
        _ = try RewriteResultValidator.validate(
          events: try events([try JSONSerialization.data(withJSONObject: object)]),
          for: request, inputBytes: request.inputBytes)
      }, .malformedResponse)
    object["server"] = ["name": String(repeating: "n", count: 129), "version": "1"]
    XCTAssertEqual(
      category {
        _ = try RewriteResultValidator.validate(
          events: try events([try JSONSerialization.data(withJSONObject: object)]),
          for: request, inputBytes: request.inputBytes)
      }, .malformedResponse)
  }

  func testRemainingPlaceholderGlyphIsServerValidationFailure() throws {
    let request = try request()
    for text in ["Peter ⟦1⟧ moved", "left ⟧ only", "⟦"] {
      XCTAssertEqual(
        category {
          _ = try RewriteResultValidator.validate(
            events: try events([try resultLine(text: text)]), for: request,
            inputBytes: request.inputBytes)
        }, .serverValidationFailed)
    }
  }

  /// A rewrite that translates Slovak dictation into English (or the reverse) is a
  /// validation failure, so the faithful transcript is kept. Short text, jargon
  /// and code never decide.
  func testTranslatedResultIsServerValidationFailure() throws {
    let slovak =
      "peter prosím presuň nasadenie na pondelok a daj vedieť zákazníkovi že zálohu urobíme v piatok"
    let english =
      "Peter, please move the deployment to Monday and let the customer know that we will do the backup on Friday."
    let cleanSlovak =
      "Peter, prosím, presuň nasadenie na pondelok a daj vedieť zákazníkovi, že zálohu urobíme v piatok."
    let englishInput =
      "peter please move the deployment to monday and tell the customer about the backup"
    let slovakOutput = "Peter, prosím, presuň nasadenie na pondelok a povedz zákazníkovi o zálohe."
    for (input, output, expected) in [
      (slovak, english, RewriteFailureCategory?.some(.serverValidationFailed)),
      (englishInput, slovakOutput, .serverValidationFailed),
      (slovak, cleanSlovak, nil),
      ("ok thanks", "OK, thanks.", nil),
      ("dobre ďakujem", "Okay, thanks.", nil),
      ("deploy kubernetes cluster backup", "Deploy Kubernetes cluster backup.", nil),
      ("let x = foo(bar); return nil", "let x = foo(bar); return nil", nil),
    ] {
      let request = try request(text: input)
      XCTAssertEqual(
        category {
          _ = try RewriteResultValidator.validate(
            events: try events([try resultLine(text: output)]), for: request,
            inputBytes: request.inputBytes)
        }, expected, input)
    }
  }

  func testMissingTerminalEventIsMalformedAndSecondTerminalIsIgnored() throws {
    let request = try request()
    let id = requestID.uuidString
    XCTAssertEqual(
      category {
        _ = try RewriteResultValidator.validate(
          events: try events([
            Data(#"{"event":"accepted","request_id":"\#(id)"}"#.utf8),
            Data(#"{"event":"progress","request_id":"\#(id)","generated_chars":4}"#.utf8),
          ]), for: request, inputBytes: request.inputBytes)
      }, .malformedResponse)
    XCTAssertEqual(
      category {
        _ = try RewriteResultValidator.validate(
          events: [], for: request, inputBytes: request.inputBytes)
      }, .malformedResponse)
    let result = try RewriteResultValidator.validate(
      events: try events([
        try resultLine(),
        Data(
          #"{"event":"error","request_id":"\#(id)","code":"backend_error","message":"late"}"#.utf8),
        try resultLine(text: "second"),
      ]), for: request, inputBytes: request.inputBytes)
    XCTAssertEqual(result.text, "Peter, can you move the deployment?")
    XCTAssertEqual(
      category {
        _ = try RewriteResultValidator.validate(
          events: try events([
            Data(
              #"{"event":"error","request_id":"\#(id)","code":"backend_unavailable","message":"x"}"#
                .utf8), try resultLine(),
          ]), for: request, inputBytes: request.inputBytes)
      }, .backendUnavailable)
  }

  // MARK: Server error mapping

  func testServerErrorCodesMapToPostAdmissionCategories() throws {
    let request = try request()
    let expectations: [(String, RewriteFailureCategory)] = [
      ("shield_restore_failed", .serverValidationFailed),
      ("backend_error", .serverValidationFailed),
      ("output_too_large", .oversizedResponse),
      ("backend_timeout", .backendUnavailable),
      ("backend_first_token_timeout", .backendUnavailable),
      ("backend_unavailable", .backendUnavailable),
      ("server_busy", .backendUnavailable),
      ("unauthorized", .authenticationFailed),
      ("too_large", .serverValidationFailed),
      ("invalid_request", .serverValidationFailed),
      ("unsupported_version", .unsupportedSchemaVersion),
      ("something_new", .malformedResponse),
    ]
    for (code, expected) in expectations {
      let line = Data(
        #"{"event":"error","request_id":"\#(requestID.uuidString)","code":"\#(code)","message":"m"}"#
          .utf8)
      let category = category {
        _ = try RewriteResultValidator.validate(
          events: try events([line]), for: request, inputBytes: request.inputBytes)
      }
      XCTAssertEqual(category, expected, code)
      XCTAssertEqual(category?.isPersistable, true, code)
    }
  }

  func testHTTPStatusMapping() {
    XCTAssertEqual(RewriteFailureCategory.forHTTPStatus(400, code: nil), .serverValidationFailed)
    XCTAssertEqual(
      RewriteFailureCategory.forHTTPStatus(400, code: "unsupported_version"),
      .unsupportedSchemaVersion)
    XCTAssertEqual(RewriteFailureCategory.forHTTPStatus(401, code: nil), .authenticationFailed)
    XCTAssertEqual(
      RewriteFailureCategory.forHTTPStatus(403, code: "unauthorized"), .authenticationFailed)
    XCTAssertEqual(
      RewriteFailureCategory.forHTTPStatus(413, code: "too_large"), .serverValidationFailed)
    XCTAssertEqual(
      RewriteFailureCategory.forHTTPStatus(429, code: "server_busy"), .backendUnavailable)
    XCTAssertEqual(RewriteFailureCategory.forHTTPStatus(503, code: nil), .backendUnavailable)
    XCTAssertEqual(RewriteFailureCategory.forHTTPStatus(404, code: nil), .transportError)
    XCTAssertEqual(RewriteFailureCategory.forHTTPStatus(500, code: nil), .transportError)
    // A server response is never a pre-admission reason: the request was already admitted.
    for status in [400, 401, 403, 404, 413, 429, 500, 503] {
      for code in [nil, "too_large", "server_busy", "invalid_request"] {
        XCTAssertTrue(RewriteFailureCategory.forHTTPStatus(status, code: code).isPersistable)
      }
    }
  }

  // MARK: Protocol v2 (Feature 012)

  private func contextSnapshot() -> AppContextSnapshot {
    AppContextSnapshot.make(
      .init(
        appName: "Mail", appCategory: .email, fieldKind: .multiLine,
        windowTitle: "Re: NetBird rollout", beforeCursor: "Hi Miroslav, thanks for the update, "))
  }

  func testV2RequestCarriesTheStoredCanonicalContextBytes() throws {
    let snapshot = contextSnapshot()
    let stored = snapshot.canonicalString
    let request = try RewriteRequest(
      requestID: requestID, mode: .clean, text: "sounds good", context: Data(stored.utf8))
    XCTAssertEqual(request.schemaVersion, 2)
    XCTAssertTrue(request.sendsContext)
    let body = try request.httpBody()
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(
      Set(object.keys),
      [
        "schema_version", "request_id", "mode", "text", "language_hints", "stream_deltas",
        "context",
      ])
    XCTAssertEqual(object["schema_version"] as? Int, 2)
    // The context object on the wire is byte-identical to the stored snapshot.
    let wire = String(decoding: body, as: UTF8.self)
    XCTAssertTrue(wire.hasSuffix(#","context":"# + stored + "}"))
    let sent = try JSONSerialization.data(
      withJSONObject: try XCTUnwrap(object["context"]), options: [.sortedKeys])
    XCTAssertEqual(
      try JSONSerialization.jsonObject(with: sent) as? NSDictionary,
      try JSONSerialization.jsonObject(with: Data(stored.utf8)) as? NSDictionary)
    XCTAssertEqual(AppContextSnapshot.hash(Data(stored.utf8)), snapshot.hash)
    // The Encodable form carries the same object for fakes and tests.
    let encoded = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    XCTAssertEqual(
      encoded["context"] as? NSDictionary,
      try JSONSerialization.jsonObject(with: Data(stored.utf8)) as? NSDictionary)
  }

  func testV1RequestNeverHasContext() throws {
    let request = try request()
    XCTAssertEqual(request.schemaVersion, 1)
    XCTAssertFalse(request.sendsContext)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: request.httpBody()) as? [String: Any])
    XCTAssertNil(object["context"])
    XCTAssertEqual(object["schema_version"] as? Int, 1)
    XCTAssertEqual(try request.httpBody(), try JSONEncoder().encode(request))
  }

  func testOversizedOrNonObjectContextIsRefused() {
    XCTAssertEqual(
      category {
        _ = try RewriteRequest(
          requestID: requestID, mode: .clean, text: "x",
          context: Data(repeating: UInt8(ascii: " "), count: 8_193))
      }, .invalidSettings)
    XCTAssertEqual(
      category {
        _ = try RewriteRequest(
          requestID: requestID, mode: .clean, text: "x", context: Data("[1]".utf8))
      }, .invalidSettings)
  }

  func testV2ResultRequiresContextPromptVersion() throws {
    let request = try RewriteRequest(
      requestID: requestID, mode: .clean, text: "peter can you move the deployment",
      context: contextSnapshot().canonicalJSON())
    XCTAssertEqual(
      category {
        _ = try RewriteResultValidator.validate(
          events: try events([try resultLine()]), for: request, inputBytes: request.inputBytes)
      }, .malformedResponse)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try resultLine()) as? [String: Any])
    object["context_prompt_version"] = 1
    let result = try RewriteResultValidator.validate(
      events: try events([try JSONSerialization.data(withJSONObject: object)]), for: request,
      inputBytes: request.inputBytes)
    XCTAssertEqual(result.contextPromptVersion, 1)
    object["context_prompt_version"] = 0
    XCTAssertEqual(
      category {
        _ = try RewriteResultValidator.validate(
          events: try events([try JSONSerialization.data(withJSONObject: object)]),
          for: request, inputBytes: request.inputBytes)
      }, .malformedResponse)
    // A v1 request ignores the field and reports none.
    object["context_prompt_version"] = 1
    let v1 = try self.request()
    XCTAssertNil(
      try RewriteResultValidator.validate(
        events: try events([try JSONSerialization.data(withJSONObject: object)]), for: v1,
        inputBytes: v1.inputBytes
      ).contextPromptVersion)
  }

  func testContextCopiedIsPersistedWithItsNotice() {
    XCTAssertTrue(RewriteFailureCategory.contextCopied.isPersistable)
    XCTAssertEqual(RewriteFailureCategory.contextCopied.rawValue, "context_copied")
    XCTAssertEqual(
      RewriteNotice.text(for: .contextCopied, context: .live),
      "Rewrite used on-screen text you did not say; inserted your transcript.")
  }

  func testHealthReportsContextSupportFromProtocolVersions() throws {
    let both = try HealthResponse.decode(
      Data(#"{"service":"localflow-rewrite","protocol_versions":[1,2]}"#.utf8))
    XCTAssertTrue(both.supportsProtocolOne)
    XCTAssertTrue(both.supportsContext)
    let old = try HealthResponse.decode(
      Data(#"{"service":"localflow-rewrite","protocol_versions":[1]}"#.utf8))
    XCTAssertFalse(old.supportsContext)
  }

  // MARK: Category halves and notices

  func testCategoryHalvesArePartitioned() {
    let persisted: Set<RewriteFailureCategory> = [
      .serverUnreachable, .timeout, .authenticationFailed, .transportError, .backendUnavailable,
      .malformedResponse, .unsupportedSchemaVersion, .emptyResponse, .oversizedResponse,
      .serverValidationFailed, .requestMismatch, .interrupted, .contextCopied,
    ]
    let refusals: Set<RewriteFailureCategory> = [
      .inputTooLarge, .missingCredential, .insecureEndpointBlocked, .concurrencyLimit,
      .attemptLimit, .capacityExceeded, .invalidSettings,
    ]
    // Twelve Feature 003 codes plus Feature 012's `context_copied`.
    XCTAssertEqual(persisted.count, 13)
    XCTAssertEqual(refusals.count, 7)
    XCTAssertEqual(Set(RewriteFailureCategory.allCases), persisted.union(refusals))
    for category in persisted { XCTAssertTrue(category.isPersistable, category.rawValue) }
    for category in refusals { XCTAssertFalse(category.isPersistable, category.rawValue) }
    XCTAssertEqual(RewriteFailureCategory.persisted.count, 13)
  }

  func testNoticeTextMatchesTheContractTable() {
    let live = RewriteNotice.Context.live
    let history = RewriteNotice.Context.history
    XCTAssertEqual(
      RewriteNotice.text(for: .serverUnreachable, context: live),
      "Rewrite server unreachable. Original text inserted.")
    XCTAssertEqual(
      RewriteNotice.text(for: .serverUnreachable, context: history), "Rewrite server unreachable.")
    XCTAssertEqual(
      RewriteNotice.text(for: .timeout, context: live),
      "Rewrite took too long. Original text inserted.")
    XCTAssertEqual(
      RewriteNotice.text(for: .authenticationFailed, context: live),
      "Rewrite server rejected the credential. Check Settings.")
    XCTAssertEqual(
      RewriteNotice.text(for: .backendUnavailable, context: live),
      "Rewrite model is not available on the server.")
    for category in [
      RewriteFailureCategory.malformedResponse, .unsupportedSchemaVersion, .requestMismatch,
    ] {
      XCTAssertEqual(
        RewriteNotice.text(for: category, context: live), "Rewrite server sent an unusable reply.")
    }
    for category in [
      RewriteFailureCategory.emptyResponse, .oversizedResponse, .serverValidationFailed,
    ] {
      XCTAssertEqual(
        RewriteNotice.text(for: category, context: live), "Rewrite result was rejected.")
    }
    for category in [
      RewriteFailureCategory.missingCredential, .insecureEndpointBlocked, .invalidSettings,
      .inputTooLarge, .capacityExceeded,
    ] {
      let text = RewriteNotice.text(for: category, context: live)
      XCTAssertTrue(text.hasPrefix("Rewriting skipped: "), text)
      XCTAssertTrue(text.hasSuffix(". Original text inserted."), text)
      let historyText = RewriteNotice.text(for: category, context: history)
      XCTAssertTrue(historyText.hasPrefix("Rewriting skipped: "), historyText)
      XCTAssertFalse(historyText.contains("Original text inserted"), historyText)
    }
    XCTAssertEqual(
      RewriteNotice.text(for: .attemptLimit, context: live),
      "This dictation already has ten rewrite attempts.")
    XCTAssertEqual(
      RewriteNotice.text(for: .concurrencyLimit, context: live),
      "Two rewrites are still running. Original text inserted.")
    XCTAssertEqual(
      RewriteNotice.text(for: .concurrencyLimit, context: history),
      "Two rewrites are still running.")
    XCTAssertEqual(
      RewriteNotice.text(for: .interrupted, context: live), "Rewrite was interrupted by a restart.")
    XCTAssertEqual(
      RewriteNotice.cancelled(context: live), "Rewrite cancelled. Original text inserted.")
    XCTAssertEqual(RewriteNotice.cancelled(context: history), "Rewrite cancelled.")
    for category in RewriteFailureCategory.allCases {
      for context in [live, history] {
        let text = RewriteNotice.text(for: category, context: context)
        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(text.contains("http"))
      }
    }
  }
}
