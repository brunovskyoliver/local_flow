import Darwin
import Foundation
import LocalFlowCore
import Network
import XCTest

/// T032, research R9. The test host is the app, so its ATS keys apply. No listener binds
/// anything but 127.0.0.1, so no prompt appears; the probes for other classes dial a closed
/// port and read only whether ATS stopped the request before it left. A connection refused or
/// a timeout means ATS let it through; nothing here shows a server answering on those classes.
final class TransportSecurityTests: XCTestCase {
  private static let blockedByATS = URLError.Code.appTransportSecurityRequiresSecureConnection

  func testTheAppDeclaresTheExceptions() throws {
    let info = try XCTUnwrap(Bundle.main.infoDictionary)
    XCTAssertNotNil(info["NSLocalNetworkUsageDescription"])
    let ats = try XCTUnwrap(info["NSAppTransportSecurity"] as? [String: Any])
    XCTAssertEqual(ats["NSAllowsLocalNetworking"] as? Bool, true)
    XCTAssertNil(ats["NSAllowsArbitraryLoads"])
    let domains = try XCTUnwrap(ats["NSExceptionDomains"] as? [String: [String: Bool]])
    XCTAssertEqual(
      domains["ts.net"], ["NSIncludesSubdomains": true, "NSExceptionAllowsInsecureHTTPLoads": true])
  }

  /// Real frames over `ws://` through the transport the app uses, loopback only.
  func testAWebSocketRoundTripOverLoopback() async throws {
    let listener = try EchoListener()
    let port = try await listener.start()
    defer { listener.stop() }
    for host in ["127.0.0.1", "localhost"] {
      let url = try XCTUnwrap(URL(string: "ws://\(host):\(port)/v1/remote/channel"))
      let transport = URLSessionRemoteTransport(url: url)
      let frame = Data("sealed frame over \(host)".utf8)
      try await transport.send(frame)
      let answer = try await transport.receive()
      XCTAssertEqual(answer, .binary(frame), host)
      transport.close(code: 1000)
    }
  }

  /// The control must be blocked, or the other results mean nothing.
  func testWhatATSBlocksAndWhatItLets() async throws {
    var targets = [
      ("public name, control", "ats-control.invalid", true),
      ("IPv4 loopback", "127.0.0.1", false),
      ("IPv6 loopback", "[::1]", false),
      (".local name", "localflow-ats-probe.local", false),
      ("single-label name", "localflow-ats-probe", false),
    ]
    if let own = Self.ownPrivateIPv4() { targets.append(("own private IPv4 \(own)", own, false)) }
    for (label, host, expectBlocked) in targets {
      let http = await Self.probe(URLRequest(url: try XCTUnwrap(URL(string: "http://\(host):9/"))))
      let ws = await Self.probeWebSocket(try XCTUnwrap(URL(string: "ws://\(host):9/")))
      print("ATS-PROBE \(label): http \(http.rawValue), ws \(ws.rawValue)")
      XCTAssertEqual(http == Self.blockedByATS, expectBlocked, "\(label) http \(http.rawValue)")
      XCTAssertEqual(ws == Self.blockedByATS, expectBlocked, "\(label) ws \(ws.rawValue)")
    }
  }

  private static func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 4
    configuration.timeoutIntervalForResource = 4
    configuration.waitsForConnectivity = false
    return URLSession(configuration: configuration)
  }

  private static func probe(_ request: URLRequest) async -> URLError.Code {
    do {
      _ = try await session().data(for: request)
      return .unknown
    } catch { return (error as? URLError)?.code ?? .unknown }
  }

  private static func probeWebSocket(_ url: URL) async -> URLError.Code {
    let task = session().webSocketTask(with: url)
    task.resume()
    defer { task.cancel() }
    do {
      _ = try await task.receive()
      return .unknown
    } catch { return (error as? URLError)?.code ?? .unknown }
  }

  /// This machine's own RFC 1918 address, if it has one. Read, never bound.
  private static func ownPrivateIPv4() -> String? {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return nil }
    defer { freeifaddrs(head) }
    var entry = head
    while let current = entry {
      defer { entry = current.pointee.ifa_next }
      guard let address = current.pointee.ifa_addr, address.pointee.sa_family == AF_INET else {
        continue
      }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard
        getnameinfo(
          address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
          NI_NUMERICHOST) == 0
      else { continue }
      let text = String(cString: host)
      let octets = text.split(separator: ".").compactMap { Int($0) }
      if octets[0] == 10 || (octets[0] == 192 && octets[1] == 168)
        || (octets[0] == 172 && (16...31).contains(octets[1]))
      {
        return text
      }
    }
    return nil
  }
}

/// A WebSocket echo on 127.0.0.1 and a free port.
private final class EchoListener: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "TransportSecurityTests.echo")

  init() throws {
    let parameters = NWParameters.tcp
    parameters.defaultProtocolStack.applicationProtocols.insert(
      NWProtocolWebSocket.Options(), at: 0)
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
  }

  func start() async throws -> UInt16 {
    listener.newConnectionHandler = { [queue] connection in
      connection.start(queue: queue)
      Self.echo(connection)
    }
    return try await withCheckedThrowingContinuation { continuation in
      listener.stateUpdateHandler = { [listener] state in
        switch state {
        case .ready:
          listener.stateUpdateHandler = nil
          continuation.resume(returning: listener.port?.rawValue ?? 0)
        case .failed(let error):
          listener.stateUpdateHandler = nil
          continuation.resume(throwing: error)
        default: break
        }
      }
      listener.start(queue: queue)
    }
  }

  func stop() { listener.cancel() }

  private static func echo(_ connection: NWConnection) {
    connection.receiveMessage { data, context, _, error in
      guard error == nil, let data, let context else { return connection.cancel() }
      connection.send(
        content: data, contentContext: context,
        completion: .contentProcessed { _ in echo(connection) })
    }
  }
}
