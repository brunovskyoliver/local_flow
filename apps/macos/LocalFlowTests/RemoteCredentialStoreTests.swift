import XCTest

@testable import LocalFlow

final class RemoteCredentialStoreTests: XCTestCase {
  private var store: RemoteCredentialStore!

  override func setUp() {
    super.setUp()
    // A throwaway service, so the test never touches the app's own items.
    store = RemoteCredentialStore(
      service: "org.localflow.LocalFlowTests.remote.\(UUID().uuidString)")
  }

  override func tearDown() {
    try? store.removeAll()
    super.tearDown()
  }

  func testProductionServiceFollowsTheBundleIdentifier() {
    XCTAssertEqual(RemoteCredentialStore.defaultService, "org.localflow.LocalFlow.remote")
    XCTAssertEqual(
      Set(RemoteCredentialItem.allCases.map(\.rawValue)),
      ["device-key", "server-key", "refresh-token", "access-token"])
  }

  func testRoundTripAndOverwrite() throws {
    let key = Data((0..<32).map { UInt8($0) })
    try store.write(.serverKey, key)
    XCTAssertEqual(try store.read(.serverKey), key)
    try store.write(.refreshToken, Data("lfr_one".utf8))
    try store.write(.refreshToken, Data("lfr_two".utf8))
    XCTAssertEqual(try store.read(.refreshToken), Data("lfr_two".utf8))
    XCTAssertNil(try store.read(.accessToken))
  }

  func testRemoveAllDeletesEveryItem() throws {
    for item in RemoteCredentialItem.allCases { try store.write(item, Data(item.rawValue.utf8)) }
    store.accessTokenIssuedAt = .seconds(5)
    try store.removeAll()
    for item in RemoteCredentialItem.allCases { XCTAssertNil(try store.read(item), item.rawValue) }
    XCTAssertNil(store.accessTokenIssuedAt)
    // Nothing left to delete is not an error.
    XCTAssertNoThrow(try store.removeAll())
  }

  func testIssueTimeIsMemoryOnly() throws {
    try store.write(.accessToken, Data("lfa_x".utf8))
    store.accessTokenIssuedAt = .seconds(42)
    let reopened = RemoteCredentialStore(service: store.service)
    XCTAssertEqual(try reopened.read(.accessToken), Data("lfa_x".utf8))
    XCTAssertNil(reopened.accessTokenIssuedAt)
  }

  func testEmptyValuesAreRefused() {
    XCTAssertThrowsError(try store.write(.refreshToken, Data()))
  }
}
