import Foundation
import OSLog

/// Credentials a dictation session needs. `RemoteEnrollment` provides them; its state
/// updates (revoked, not approved, pin mismatch) happen there.
protocol RemoteSessionCredentials: Sendable {
  func sessionAccessToken() async -> String?
  func sessionAccessTokenExpired() async -> String?
  func sessionServerError(_ code: RemoteErrorCode) async
  func sessionPinMismatch() async
}

extension RemoteEnrollment: RemoteSessionCredentials {
  nonisolated func sessionAccessToken() async -> String? { await accessToken() }
  nonisolated func sessionAccessTokenExpired() async -> String? { await accessTokenExpired() }
  nonisolated func sessionServerError(_ code: RemoteErrorCode) async { await apply(code) }
  nonisolated func sessionPinMismatch() async { await handlePinMismatch() }
}

struct RemoteDictationConfiguration: Sendable {
  let channelURL: URL
  let serverKey: Data
  let boost: RemoteBoost?
  /// No sealed frame for this long after key release while results are outstanding
  /// ends the session with `timeout` (FR-017).
  let threshold: Duration
  var pumpInterval: Duration = .milliseconds(200)
}

/// The windows the server recognized for one dictation, and the open channel for its rewrite.
struct RemoteDictationResult: Sendable {
  let windows: [Int: PrefetchedWindow]
  let model: RemoteModelIdentity
  let channel: RemoteChannel
  /// The next operation number on `channel`.
  let nextOp: Int
}

/// One dictation streamed to the server (Feature 014 R12). It opens the channel at key
/// press, streams the spool's new samples every 200 ms in frames of at most 16,000, and
/// collects `window_result`s by sample start. Any failure ends it with a reason code;
/// the coordinator then recognizes locally or keeps the audio for a retry.
actor RemoteDictationSession {
  enum State: Equatable, Sendable {
    case connecting, streaming, restarting, ending, complete
    case failed(RemoteFailureReason)
  }

  typealias SampleReader = @Sendable (_ start: Int, _ count: Int) throws -> [Float]
  typealias SampleCounter = @Sendable () async -> Int

  private let configuration: RemoteDictationConfiguration
  private let transports: any RemoteTransportOpening
  private let credentials: any RemoteSessionCredentials
  private let clock: any RemoteClock
  private let read: SampleReader
  private let recorded: SampleCounter
  private let log = Logger(subsystem: "org.localflow.LocalFlow", category: "remote")

  private(set) var state: State = .connecting
  private var channel: RemoteChannel?
  private var model: RemoteModelIdentity?
  private var collector: RemoteWindowCollector?
  private var sentSamples = 0
  private var endSent = false
  private var released = false
  private var totalSamples = 0
  private var restarted = false
  private var tokenRetried = false
  private var refreshTokenFirst = false
  private var pumping = false
  private var pumpAgain = false
  private var lastFrame: Duration = .zero
  private var tasks: [Task<Void, Never>] = []
  private var waiters:
    [CheckedContinuation<Result<RemoteDictationResult, RemoteFailureReason>, Never>] = []
  private var failureObserver: (@Sendable (RemoteFailureReason) -> Void)?
  /// Bumped on every restart; loops of an older attempt stop.
  private var generation = 0

  init(
    configuration: RemoteDictationConfiguration, transports: any RemoteTransportOpening,
    credentials: any RemoteSessionCredentials, clock: any RemoteClock,
    read: @escaping SampleReader, recorded: @escaping SampleCounter
  ) {
    self.configuration = configuration
    self.transports = transports
    self.credentials = credentials
    self.clock = clock
    self.read = read
    self.recorded = recorded
  }

  var failure: RemoteFailureReason? {
    if case .failed(let reason) = state { return reason }
    return nil
  }

  /// Called once, at the first failure, so local model acquisition can start early.
  func onFailure(_ observer: @escaping @Sendable (RemoteFailureReason) -> Void) {
    failureObserver = observer
    if let failure { observer(failure) }
  }

  func start() {
    guard state == .connecting, tasks.isEmpty else { return }
    launch()
  }

  /// Key release: sends the tail and `dictation_end`, then waits for the remaining
  /// results. Returns the windows or the failure reason.
  func finish(totalSamples: Int) async -> Result<RemoteDictationResult, RemoteFailureReason> {
    if !released {
      released = true
      self.totalSamples = totalSamples
      lastFrame = clock.now()
      startWatchdog()
      if totalSamples == 0 { fail(.protocolError) }
      if let channel, !isTerminal { await flush(channel, generation: generation) }
    }
    if let result = terminalResult() { return result }
    return await withCheckedContinuation { waiters.append($0) }
  }

  /// The user cancelled: the server drops queued work; nothing is recognized.
  func cancel() {
    guard !isTerminal else { return }
    if let channel, model != nil {
      Task { try? await channel.send(.dictationCancel(op: 1)) }
    }
    end(.failed(.unreachable), closeChannel: true)
  }

  /// The Mac is going to sleep: the session is abandoned and nothing more is sent.
  func systemWillSleep() {
    guard !isTerminal else { return }
    fail(.unreachable)
  }

  // MARK: Attempts

  private func launch() {
    generation += 1
    let current = generation
    tasks.append(Task { await self.run(generation: current) })
  }

  private func run(generation current: Int) async {
    do {
      let first =
        refreshTokenFirst
        ? await credentials.sessionAccessTokenExpired() : await credentials.sessionAccessToken()
      refreshTokenFirst = false
      guard var token = first else { return fail(.unauthorized) }
      var opened: RemoteChannel
      while true {
        let transport = try await transports.open(configuration.channelURL)
        guard current == generation, !isTerminal else {
          transport.close(code: 1000)
          return
        }
        opened = try RemoteChannel(transport: transport, serverKey: configuration.serverKey)
        channel = opened
        do {
          try await opened.open(purpose: .session, accessToken: token)
          break
        } catch RemoteChannelError.server(.tokenExpired) where !tokenRetried && !released {
          // Refresh, then retry the operation once while recording continues.
          tokenRetried = true
          await opened.close()
          guard let fresh = await credentials.sessionAccessTokenExpired() else {
            return fail(.unauthorized)
          }
          token = fresh
        }
      }
      guard current == generation, !isTerminal else { return }
      noteFrame()
      try await opened.send(.dictationStart(op: 1, boost: configuration.boost))
      tasks.append(Task { await self.receiveLoop(opened, generation: current) })
      tasks.append(Task { await self.pumpLoop(opened, generation: current) })
    } catch {
      await channelFailed(error, generation: current)
    }
  }

  private func receiveLoop(_ channel: RemoteChannel, generation current: Int) async {
    while !isTerminal, current == generation {
      let message: RemoteServerMessage
      do { message = try await channel.receive() } catch {
        await channelFailed(error, generation: current)
        return
      }
      guard current == generation, !isTerminal else { return }
      noteFrame()
      await handle(message, channel: channel)
    }
  }

  private func handle(_ message: RemoteServerMessage, channel: RemoteChannel) async {
    if let op = message.op, op != 1 { return fail(.protocolError) }
    switch message {
    case .dictationAccepted(_, let samples, let identity):
      guard model == nil, samples == RemoteProtocol.windowSamples else {
        return fail(.protocolError)
      }
      model = identity
      collector = RemoteWindowCollector(boostingRan: identity.boostingRan)
      if state == .connecting || state == .restarting { state = .streaming }
      if released { await flush(channel, generation: generation) }
    case .windowResult(let result):
      guard var collected = collector else { return fail(.protocolError) }
      do { try collected.append(result) } catch { return fail(.protocolError) }
      collector = collected
    case .progress:
      break
    case .dictationComplete(_, let windows):
      guard released, endSent, let collected = collector, collected.count == windows,
        collected.covers(totalSamples)
      else { return fail(.protocolError) }
      complete(channel: channel)
    case .error(_, let code):
      if code == .tokenExpired, model == nil, !tokenRetried, !released {
        // `token_expired` at operation start: refresh and start again once.
        tokenRetried = true
        refreshTokenFirst = true
        return restart(dueTo: nil)
      }
      await credentials.sessionServerError(code)
      fail(code.failureReason)
    case .cancelled:
      fail(.unreachable)
    default:
      fail(.protocolError)
    }
  }

  /// Streams new spool samples every 200 ms while recording.
  private func pumpLoop(_ channel: RemoteChannel, generation current: Int) async {
    while !isTerminal, current == generation, !released {
      await flush(channel, generation: current)
      do { try await clock.sleep(for: configuration.pumpInterval) } catch { return }
    }
  }

  /// Sends every recorded sample not yet sent, then `dictation_end` once the key is up.
  /// One sender at a time, so frames never interleave; a caller arriving while another
  /// sends makes it loop once more.
  private func flush(_ channel: RemoteChannel, generation current: Int) async {
    guard !pumping else {
      pumpAgain = true
      return
    }
    pumping = true
    defer { pumping = false }
    repeat {
      pumpAgain = false
      guard model != nil, !isTerminal, current == generation else { return }
      do {
        let limit = released ? totalSamples : await recorded()
        while sentSamples < limit, !isTerminal, current == generation {
          let count = min(RemoteProtocol.maximumFrameSamples, limit - sentSamples)
          let samples = try read(sentSamples, count)
          try await channel.sendAudio(samples[...])
          sentSamples += count
        }
        if released, sentSamples == totalSamples, !endSent, !isTerminal, current == generation {
          try await channel.send(.dictationEnd(op: 1, totalSamples: totalSamples))
          endSent = true
          state = .ending
        }
      } catch let error as RemoteChannelError {
        await channelFailed(error, generation: current)
        return
      } catch {
        // The spool could not be read: the server's copy would not be whole.
        fail(.protocolError)
        return
      }
    } while pumpAgain
  }

  private func channelFailed(_ error: any Error, generation current: Int) async {
    guard current == generation, !isTerminal else { return }
    let channelError = error as? RemoteChannelError ?? .unreachable
    switch channelError {
    case .pinMismatch:
      await credentials.sessionPinMismatch()
      fail(.pinMismatch)
    case .server(let code):
      await credentials.sessionServerError(code)
      fail(code.failureReason)
    case .unreachable, .protocolError, .closed, .timeout:
      // Before key release the session reconnects once and starts again from sample 0.
      if !released, !restarted {
        restart(dueTo: channelError.failureReason)
      } else {
        fail(channelError.failureReason)
      }
    }
  }

  private func restart(dueTo reason: RemoteFailureReason?) {
    if reason != nil { restarted = true }
    log.notice(
      "Remote dictation restarting from sample 0: reason=\(reason?.rawValue ?? "token_expired", privacy: .public)"
    )
    if let channel { Task { await channel.close() } }
    channel = nil
    model = nil
    collector = nil
    sentSamples = 0
    endSent = false
    pumpAgain = false
    state = .restarting
    launch()
  }

  // MARK: Threshold

  private func noteFrame() { lastFrame = clock.now() }

  private func startWatchdog() {
    tasks.append(
      Task {
        while await !self.isTerminal {
          let remaining = await self.remainingThreshold()
          if remaining <= .zero {
            await self.fail(.timeout)
            return
          }
          do { try await self.clock.sleep(for: remaining) } catch { return }
        }
      })
  }

  private func remainingThreshold() -> Duration {
    configuration.threshold - (clock.now() - lastFrame)
  }

  // MARK: Terminal states

  private var isTerminal: Bool {
    switch state {
    case .complete, .failed: true
    default: false
    }
  }

  private var completed: RemoteDictationResult?

  private func complete(channel: RemoteChannel) {
    guard !isTerminal, let model, let collector else { return }
    completed = RemoteDictationResult(
      windows: collector.windows, model: model, channel: channel, nextOp: 2)
    log.notice("Remote dictation complete: windows=\(collector.count)")
    end(.complete, closeChannel: false)
  }

  private func fail(_ reason: RemoteFailureReason) {
    guard !isTerminal else { return }
    log.notice("Remote dictation failed: reason=\(reason.rawValue, privacy: .public)")
    end(.failed(reason), closeChannel: true)
    failureObserver?(reason)
  }

  private func end(_ terminal: State, closeChannel: Bool) {
    state = terminal
    generation += 1
    for task in tasks { task.cancel() }
    tasks = []
    if closeChannel, let channel { Task { await channel.close() } }
    if closeChannel { channel = nil }
    guard let result = terminalResult() else { return }
    let pending = waiters
    waiters = []
    for waiter in pending { waiter.resume(returning: result) }
  }

  private func terminalResult() -> Result<RemoteDictationResult, RemoteFailureReason>? {
    switch state {
    case .complete: completed.map { .success($0) }
    case .failed(let reason): .failure(reason)
    default: nil
    }
  }
}

/// The app's remote dictation wiring (Feature 014): press-time settings, sessions for an
/// approved device, the retry queue and the rewrite channel hand-off. It holds nothing
/// that can connect until remote dictation is on: `enrollment` is created on first use
/// and only when the consent step has been confirmed.
@MainActor
final class RemoteDictationRouter: RemoteDictationRouting {
  private let preferences: AppPreferences
  private let credentials: any RemoteCredentialStoring
  private let transports: any RemoteTransportOpening
  private let clock: any RemoteClock
  private let enrollment: @MainActor () -> RemoteEnrollment?
  private let pending: @MainActor () -> PendingRemoteDictationStore?
  private let provisioned: @MainActor () -> Bool
  private let askAboutAudio: @MainActor (URL, Int) async -> Void
  let rewriteChannels: RemoteRewriteChannels

  init(
    preferences: AppPreferences, credentials: any RemoteCredentialStoring,
    transports: any RemoteTransportOpening, clock: any RemoteClock = SystemRemoteClock(),
    enrollment: @escaping @MainActor () -> RemoteEnrollment?,
    pending: @escaping @MainActor () -> PendingRemoteDictationStore?,
    localModelProvisioned: @escaping @MainActor () -> Bool,
    askAboutAudio: @escaping @MainActor (URL, Int) async -> Void
  ) {
    self.preferences = preferences
    self.credentials = credentials
    self.transports = transports
    self.clock = clock
    self.enrollment = enrollment
    self.pending = pending
    provisioned = localModelProvisioned
    self.askAboutAudio = askAboutAudio
    // A rewrite with no dictation channel left opens its own session channel.
    let open: RemoteRewriteChannels.Opener = { [weak preferences, credentials, transports] in
      guard
        let (url, key, token) = await Self.sessionInputs(
          preferences: preferences, credentials: credentials, enrollment: enrollment)
      else { throw RemoteChannelError.unreachable }
      let channel = try RemoteChannel(transport: try await transports.open(url), serverKey: key)
      try await channel.open(purpose: .session, accessToken: token)
      return channel
    }
    rewriteChannels = RemoteRewriteChannels(open: open)
  }

  /// Where and with what a new session channel connects, or nil when this device
  /// cannot use the server now.
  private static func sessionInputs(
    preferences: AppPreferences?, credentials: any RemoteCredentialStoring,
    enrollment: @MainActor () -> RemoteEnrollment?
  ) async -> (URL, Data, String)? {
    guard let settings = preferences?.remoteSettings(), settings.routesToServer,
      let origin = settings.serverOrigin, let url = RemoteEnrollment.channelURL(origin: origin),
      let key = try? credentials.read(.serverKey), let enrollment = enrollment(),
      let token = await enrollment.accessToken()
    else { return nil }
    return (url, key, token)
  }

  func settings() -> RemoteDictationSettings { preferences.remoteSettings() }

  func dictationStarted(settings: RemoteDictationSettings) {
    guard settings.enabled, settings.state == .pending else { return }
    enrollment()?.refreshIfPending()
  }

  func makeSession(
    settings: RemoteDictationSettings, boost: RemoteBoost?,
    read: @escaping RemoteDictationSession.SampleReader,
    recorded: @escaping RemoteDictationSession.SampleCounter
  ) -> RemoteDictationSession? {
    guard settings.routesToServer, let origin = settings.serverOrigin,
      let url = RemoteEnrollment.channelURL(origin: origin),
      let key = try? credentials.read(.serverKey), let enrollment = enrollment()
    else { return nil }
    return RemoteDictationSession(
      configuration: .init(
        channelURL: url, serverKey: key, boost: boost, threshold: settings.fallbackThreshold),
      transports: transports, credentials: enrollment, clock: clock, read: read,
      recorded: recorded)
  }

  var localModelProvisioned: Bool { provisioned() }

  func keepForRetry(
    id: UUID, audio: URL, sampleCount: Int, failure: RemoteFailureReason, targetBundleID: String?
  ) async throws {
    guard let store = pending() else { throw PendingRemoteDictationStore.Failure.missing }
    _ = try await store.add(
      id: id, audio: audio, sampleCount: sampleCount, failure: failure,
      targetBundleID: targetBundleID, now: Int64(Date().timeIntervalSince1970 * 1_000))
  }

  func retryQueueFull(audio: URL, sampleCount: Int) async {
    await askAboutAudio(audio, sampleCount)
  }

  func completed(_ result: RemoteDictationResult, dictation: UUID) {
    let channels = rewriteChannels
    Task { await channels.park(result) }
  }
}

extension RemoteDictationRouter: RemoteRetryStarting {
  nonisolated func makeRetrySession(
    boost: RemoteBoost?, read: @escaping RemoteDictationSession.SampleReader,
    recorded: @escaping RemoteDictationSession.SampleCounter
  ) async -> RemoteDictationSession? {
    await MainActor.run {
      makeSession(settings: settings(), boost: boost, read: read, recorded: recorded)
    }
  }
}
