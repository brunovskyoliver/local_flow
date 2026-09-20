import XCTest

@testable import LocalFlow

/// Research R3: one forward pass per stretch file, exact region sample counts, missing
/// and unreadable files.
final class VoiceRegionReaderTests: XCTestCase {
  private var fixture: MeetingTestStore!

  override func setUpWithError() throws { fixture = try MeetingTestStore.make() }
  override func tearDown() { fixture.cleanup() }

  /// 60 blocks of 4,096 frames at 48 kHz: 5,120 ms per stretch.
  private static let blocks = 60
  private static let stretchMs = Int64(blocks) * TranscriptMeetingFixture.blockMs

  private func makeReader(
    stretches: Int = 1, missingSystem: Set<Int> = [], bases: Bool = true,
    lengthMs: Int64 = VoiceRegionReaderTests.stretchMs
  ) async throws -> (VoiceRegionReader, TranscriptMeetingFixture) {
    let meeting = try await TranscriptMeetingFixture.make(
      in: fixture,
      stretches: (1...stretches).map {
        .init(
          microphone: .blocks(Self.blocks),
          system: missingSystem.contains($0) ? .missing : .blocks(Self.blocks))
      })
    let loaded = try await fixture.store.detail(id: meeting.meetingID)
    let detail = try XCTUnwrap(loaded)
    var map: [Int: (Int64, Int64?)] = [:]
    if bases {
      for index in 0..<stretches {
        map[index + 1] = (Int64(index) * lengthMs, lengthMs)
      }
    }
    return (VoiceRegionReader(storageRoot: fixture.root, detail: detail, bases: map), meeting)
  }

  private func region(_ startMs: Int64, _ endMs: Int64, track: MeetingTrackKind = .system)
    -> VoiceRegion
  {
    VoiceRegion(track: track, startMs: startMs, endMs: endMs, engineQuality: nil)
  }

  func testRegionsArriveInStartOrderWithExactSampleCounts() async throws {
    let (reader, _) = try await makeReader()
    let received = Received()
    let summary = try await reader.read([region(3_500, 4_900), region(200, 3_400)]) {
      region, samples in
      await received.add(region, samples.count)
      XCTAssertLessThanOrEqual(samples.count, VoiceRegionRequest.maxSamples)
    }
    let calls = await received.calls
    XCTAssertEqual(calls.map(\.0.startMs), [200, 3_500])
    XCTAssertEqual(calls.map(\.1), [51_200, 22_400], "16 kHz mono: 3.2 s and 1.4 s")
    XCTAssertEqual(summary, .init(read: 2, missing: 0))
  }

  func testTheHandlerRunsBeforeTheNextRegionIsDecodedAndOnlyOneRegionIsResident() async throws {
    let (reader, _) = try await makeReader()
    let received = Received()
    _ = try await reader.read([region(200, 1_200), region(1_500, 2_500), region(3_000, 4_000)]) {
      region, samples in
      // Each call sees exactly its own region; the previous one was dropped already.
      let active = await received.enter()
      XCTAssertEqual(active, 1, "The handler is never re-entered")
      XCTAssertEqual(samples.count, Int(region.durationMs) * 16)
      await received.add(region, samples.count)
      await received.leave()
    }
    let calls = await received.calls
    XCTAssertEqual(calls.count, 3)
    XCTAssertEqual(calls.map(\.0.startMs), [200, 1_500, 3_000])
  }

  func testARegionInASecondStretchMapsThroughTheTranscriptBases() async throws {
    let (reader, _) = try await makeReader(stretches: 2)
    let received = Received()
    let second = Self.stretchMs
    let summary = try await reader.read(
      [region(second + 200, second + 1_200, track: .microphone), region(100, 1_100)]
    ) { region, samples in
      await received.add(region, samples.count)
    }
    let calls = await received.calls
    XCTAssertEqual(calls.map(\.0.startMs), [100, second + 200])
    XCTAssertEqual(calls.map(\.1), [16_000, 16_000])
    XCTAssertEqual(summary.read, 2)
    // Without bases, the work items' own bases apply and give the same answer.
    let (bare, _) = try await makeReader(stretches: 2, bases: false)
    let again = Received()
    _ = try await bare.read([region(second + 200, second + 1_200)]) { region, samples in
      await again.add(region, samples.count)
    }
    let repeated = await again.calls
    XCTAssertEqual(repeated.map(\.1), [16_000])
  }

  func testAMissingStretchFileSkipsItsRegionsAndEveryFileMissingFails() async throws {
    let (reader, _) = try await makeReader(stretches: 2, missingSystem: [2])
    let received = Received()
    let second = Self.stretchMs
    let summary = try await reader.read([region(100, 1_100), region(second + 100, second + 1_100)])
    {
      region, samples in
      await received.add(region, samples.count)
    }
    let calls = await received.calls
    XCTAssertEqual(calls.map(\.0.startMs), [100])
    XCTAssertEqual(summary, .init(read: 1, missing: 1))
    let (allMissing, _) = try await makeReader(stretches: 1, missingSystem: [1])
    do {
      _ = try await allMissing.read([region(100, 1_100)]) { _, _ in }
      XCTFail("Every file missing must fail")
    } catch { XCTAssertEqual(error as? VoiceRegionReader.Failure, .audioMissing) }
    // A region past every stretch maps nowhere: missing, not decoded.
    let (reader2, _) = try await makeReader()
    do {
      _ = try await reader2.read([region(100_000, 101_000)]) { _, _ in }
      XCTFail("Nothing to decode")
    } catch { XCTAssertEqual(error as? VoiceRegionReader.Failure, .audioMissing) }
  }

  func testARegionTheFileEndsBeforeIsCountedMissingNotHandedOverPartially() async throws {
    // The transcript recorded a 9 s stretch, but the file holds 5.12 s of audio.
    let (reader, _) = try await makeReader(lengthMs: 9_000)
    let received = Received()
    let summary = try await reader.read([region(200, 1_200), region(4_000, 9_000)]) {
      region, samples in
      await received.add(region, samples.count)
    }
    let calls = await received.calls
    XCTAssertEqual(calls.map(\.0.startMs), [200])
    XCTAssertEqual(summary, .init(read: 1, missing: 1))
  }

  func testUnreadableFilesMapToAudioDecodeFailure() async throws {
    let (reader, meeting) = try await makeReader()
    let url = try XCTUnwrap(meeting.files[1]?[.system])
    try Data(repeating: 0x55, count: 4_096).write(to: url)
    do {
      _ = try await reader.read([region(200, 1_200)]) { _, _ in }
      XCTFail("Garbage must not decode")
    } catch {
      guard case .audioDecodeFailure(let detail)? = error as? VoiceRegionReader.Failure else {
        return XCTFail("\(error)")
      }
      XCTAssertTrue(["open", "read", "convert"].contains(detail))
    }
  }

  private actor Received {
    private(set) var calls: [(VoiceRegion, Int)] = []
    private var active = 0
    func add(_ region: VoiceRegion, _ count: Int) { calls.append((region, count)) }
    func enter() -> Int {
      active += 1
      return active
    }
    func leave() { active -= 1 }
  }
}
