import AppKit
import XCTest

@testable import LocalFlow

final class AppConfigurationTests: XCTestCase {
  func testHostIsTheNativeMenuBarApplication() throws {
    let bundle = Bundle.main
    XCTAssertEqual(bundle.bundleIdentifier, "org.localflow.LocalFlow")
    XCTAssertEqual(bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool, true)
    let minimum = try XCTUnwrap(
      bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String)
    XCTAssertEqual(minimum, "14.0")
  }
  @MainActor
  func testIndicatorCannotTakeFocusAndStopsObserversWhenHidden() {
    let panel = IndicatorPanel(animated: false, announce: { _ in })
    defer { panel.orderOut(nil) }
    XCTAssertFalse(panel.canBecomeKey)
    XCTAssertFalse(panel.canBecomeMain)
    XCTAssertEqual(panel.frame.size, NSSize(width: 153, height: 38))
    XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    XCTAssertFalse(panel.observesGeometryChanges)
    panel.update(state: .preparing, level: 0, cancel: {})
    XCTAssertTrue(panel.observesGeometryChanges)
    panel.update(state: .transcribing, level: 0, cancel: {})
    XCTAssertTrue(panel.observesGeometryChanges)
    panel.update(state: .idle, level: 0, cancel: {})
    XCTAssertFalse(panel.observesGeometryChanges)
    XCTAssertFalse(panel.isVisible)
  }

  @MainActor
  func testIndicatorLevelFramesSkipLayoutUntilStateChanges() {
    let panel = IndicatorPanel(animated: false, announce: { _ in })
    defer { panel.orderOut(nil) }
    // Not visible yet: the level path falls back to a full presentation.
    panel.updateLevel(0.1, state: .recording, cancel: {})
    XCTAssertTrue(panel.isVisible)
    let presented = panel.presentCount
    for step in 0..<20 { panel.updateLevel(Float(step) / 20, state: .recording, cancel: {}) }
    XCTAssertEqual(panel.presentCount, presented)
    panel.updateLevel(0.5, state: .transcribing, cancel: {})
    XCTAssertEqual(panel.presentCount, presented + 1)
    panel.update(state: .idle, level: 0, cancel: {})
    XCTAssertFalse(panel.isVisible)
  }

  @MainActor
  func testIndicatorAnnouncesTerminalStatesOnceBeforeHiding() {
    var announcements: [String] = []
    let panel = IndicatorPanel(animated: false) { announcements.append($0) }
    defer { panel.orderOut(nil) }
    panel.update(state: .preparing, level: 0, cancel: {})
    panel.update(state: .cancelling, level: 0, cancel: {})
    panel.update(state: .idle, level: 0, cancel: {})
    panel.update(state: .idle, level: 0, cancel: {})
    XCTAssertEqual(announcements.last, "Dictation cancelled.")
    XCTAssertEqual(announcements.count, 3)
    panel.update(state: .recording, level: 0.5, cancel: {})
    panel.update(state: .recovery, level: 0, cancel: {})
    XCTAssertEqual(announcements.last, "Text saved for review.")
    XCTAssertFalse(panel.isVisible)
    XCTAssertFalse(panel.observesGeometryChanges)
    panel.update(state: .failed, level: 0, cancel: {})
    XCTAssertEqual(announcements.last, "Dictation failed. Open LocalFlow for details.")
  }

  @MainActor
  func testHiddenBackgroundNoticeStaysHiddenAcrossStagesOfTheSameWork() {
    let panel = IndicatorPanel(animated: false, announce: { _ in })
    defer { panel.orderOut(nil) }
    let meeting = UUID()
    let finalizing = BackgroundNotice(
      id: meeting, message: "Finalizing transcript", symbol: "text.badge.checkmark",
      progress: 0.4, destination: .transcript(meetingID: meeting))
    panel.showBackgroundNotice(finalizing, open: {})
    XCTAssertTrue(panel.showsBackgroundNotice)
    panel.hideBackgroundNotice()
    XCTAssertFalse(panel.isVisible)
    // Labeling the same meeting stays hidden; another meeting's work shows.
    var labeling = finalizing
    labeling.message = "Labeling speakers"
    panel.showBackgroundNotice(labeling, open: {})
    XCTAssertFalse(panel.isVisible)
    let other = BackgroundNotice(
      id: UUID(), message: "Summarizing…", symbol: "text.quote", progress: nil,
      destination: .meetings)
    panel.showBackgroundNotice(other, open: {})
    XCTAssertTrue(panel.showsBackgroundNotice)
  }

  @MainActor
  func testClipboardNoticeTakesPrecedenceOverBackgroundAndDismissesByID() {
    var announcements: [String] = []
    let panel = IndicatorPanel(animated: false) { announcements.append($0) }
    defer { panel.orderOut(nil) }
    panel.showBackgroundNotice(
      BackgroundNotice(
        id: UUID(), message: "Labeling speakers", symbol: "person.2", progress: nil,
        destination: .meetings), open: {})
    let notice = ClipboardNotice(dictationID: UUID(), reason: .notInserted)
    panel.showClipboardNotice(notice)
    XCTAssertTrue(panel.isVisible)
    XCTAssertFalse(panel.showsBackgroundNotice)
    XCTAssertEqual(
      announcements.last, "Couldn't insert · copied to clipboard. Paste with Command-V.")
    panel.dismissClipboardNotice(id: UUID())
    XCTAssertFalse(panel.showsBackgroundNotice)
    panel.dismissClipboardNotice(id: notice.id)
    XCTAssertTrue(panel.showsBackgroundNotice)
  }

  @MainActor
  func testRecordedWaveformScrollsRightToLeftKeepingEachSlicePeak() {
    let history = WaveformHistory()
    history.advance(to: 0, level: 0.02)
    history.advance(to: 0.03, level: 0.2)
    history.advance(to: 0.05, level: 0.01)
    // The open slice holds its peak at the right edge.
    XCTAssertEqual(history.current, 0.2)
    XCTAssertEqual(history.progress(at: 0.035), 0.5, accuracy: 0.001)
    history.advance(to: 0.071, level: 0.04)
    XCTAssertEqual(history.slices.last, 0.2)
    XCTAssertEqual(history.current, 0.04)
    // The next slice pushes it one bar to the left.
    history.advance(to: 0.142, level: 0)
    XCTAssertEqual(history.slices.suffix(2), [0.2, 0.04])
    // A stalled frame closes the missed slices as silence.
    history.advance(to: 0.142 + 0.07 * 3, level: 0.1)
    XCTAssertEqual(history.slices.suffix(3), [0.0, 0, 0])
    XCTAssertEqual(history.heights.count, DictationIndicator.barCount + 1)
    XCTAssertTrue(
      [WaveformHistory.height(0), WaveformHistory.height(1), WaveformHistory.height(.nan)]
        .allSatisfy { $0.isFinite && $0 >= 3 && $0 <= 28 })
  }

  @MainActor
  func testProcessingPulseStaysWithinThePill() {
    let heights = stride(from: 0.0, to: 1.2, by: 0.05).flatMap { time in
      (0..<DictationIndicator.barCount).map {
        DictationIndicator.processingBarHeight($0, time: time)
      }
    }
    XCTAssertTrue(heights.allSatisfy { $0 >= 4 && $0 <= 16 })
  }

  @MainActor
  func testIndicatorOriginFollowsVisibleFrameAcrossDockAndDisplayChanges() {
    let full = NSRect(x: -1920, y: 200, width: 1920, height: 1080)
    let bottomDock = NSRect(x: -1920, y: 270, width: 1920, height: 1010)
    let leftDock = NSRect(x: -1850, y: 200, width: 1850, height: 1080)
    XCTAssertEqual(IndicatorPanel.origin(in: full), NSPoint(x: -1019, y: 220))
    XCTAssertEqual(IndicatorPanel.origin(in: bottomDock), NSPoint(x: -1019, y: 290))
    XCTAssertEqual(IndicatorPanel.origin(in: leftDock), NSPoint(x: -984, y: 220))
  }

  @MainActor
  func testReducedMotionWaveformIsStaticAndDistinctFromPreparationAndProcessing() {
    let preparation = (0..<15).map {
      DictationIndicator.barHeight($0, state: .preparing, level: 0, reduceMotion: true)
    }
    let recording = (0..<15).map {
      DictationIndicator.barHeight($0, state: .recording, level: 0, reduceMotion: true)
    }
    let loudRecording = (0..<15).map {
      DictationIndicator.barHeight($0, state: .recording, level: 1, reduceMotion: true)
    }
    let processing = (0..<15).map {
      DictationIndicator.barHeight($0, state: .transcribing, level: 0, reduceMotion: true)
    }
    XCTAssertEqual(recording, loudRecording)
    XCTAssertNotEqual(preparation, recording)
    XCTAssertNotEqual(recording, processing)
    XCTAssertNotEqual(preparation, processing)
    XCTAssertTrue((preparation + recording + processing).allSatisfy { $0 > 0 && $0 <= 38 })
    XCTAssertTrue(
      DictationIndicator.barHeight(
        0, state: .recording, level: .nan,
        reduceMotion: false
      ).isFinite)
  }

}

final class MeetingRuntimeOptionsTests: XCTestCase {
  func testTranscriptionOptionsDefaultOff() {
    let options = MeetingRuntimeOptions.parse(environment: [:], arguments: ["LocalFlow"])
    XCTAssertNil(options.debugSlowRecognition)
    XCTAssertNil(options.debugFailRecognition)
    XCTAssertFalse(options.debugFailPersistence)
    XCTAssertNil(options.debugSeedTranscript)
    XCTAssertNil(options.debugFailDiarizationWindow)
    XCTAssertNil(options.debugSlowDiarization)
    XCTAssertFalse(options.debugSeedDiarization)
  }

  func testDiarizationArgumentsAreEnabledOnlyInDebugBuilds() {
    let options = MeetingRuntimeOptions.parse(
      environment: [:],
      arguments: [
        "LocalFlow", "--debug-fail-diarization", "window=2", "--debug-slow-diarization", "1.5",
        "--debug-seed-diarization",
      ])
    if MeetingRuntimeOptions.slowFinalizeSupported {
      XCTAssertEqual(options.debugFailDiarizationWindow, 2)
      XCTAssertEqual(options.debugSlowDiarization, 1.5)
      XCTAssertTrue(options.debugSeedDiarization)
    } else {
      XCTAssertNil(options.debugFailDiarizationWindow)
      XCTAssertNil(options.debugSlowDiarization)
      XCTAssertFalse(options.debugSeedDiarization)
    }
    let malformed = MeetingRuntimeOptions.parse(
      environment: [:],
      arguments: ["LocalFlow", "--debug-fail-diarization", "2", "--debug-slow-diarization", "-1"])
    XCTAssertNil(malformed.debugFailDiarizationWindow)
    XCTAssertNil(malformed.debugSlowDiarization)
  }

  func testTranscriptionArgumentsAreEnabledOnlyInDebugBuilds() {
    let options = MeetingRuntimeOptions.parse(
      environment: [:],
      arguments: [
        "LocalFlow", "--debug-slow-recognition", "3.5", "--debug-fail-recognition", "5",
        "--debug-fail-persistence", "--debug-seed-transcript", "12000",
      ])
    if MeetingRuntimeOptions.slowFinalizeSupported {
      XCTAssertEqual(options.debugSlowRecognition, 3.5)
      XCTAssertEqual(options.debugFailRecognition, 5)
      XCTAssertTrue(options.debugFailPersistence)
      XCTAssertEqual(options.debugSeedTranscript, 12_000)
    } else {
      XCTAssertNil(options.debugSlowRecognition)
      XCTAssertNil(options.debugFailRecognition)
      XCTAssertFalse(options.debugFailPersistence)
      XCTAssertNil(options.debugSeedTranscript)
    }
  }

  func testInvalidTranscriptionArgumentsAreIgnored() {
    for value in ["no", "", "0", "-1", "nan", "inf", "1e999", "--debug-fail-persistence"] {
      let options = MeetingRuntimeOptions.parse(
        environment: [:],
        arguments: [
          "--debug-slow-recognition", value, "--debug-fail-recognition", value,
          "--debug-seed-transcript", value,
        ])
      XCTAssertNil(options.debugSlowRecognition, value)
      XCTAssertNil(options.debugFailRecognition, value)
      XCTAssertNil(options.debugSeedTranscript, value)
    }
    for flag in ["--debug-slow-recognition", "--debug-fail-recognition", "--debug-seed-transcript"]
    {
      XCTAssertEqual(
        MeetingRuntimeOptions.parse(environment: [:], arguments: [flag]),
        MeetingRuntimeOptions())
    }
    let fractionalCounts = MeetingRuntimeOptions.parse(
      environment: [:],
      arguments: ["--debug-fail-recognition", "1.5", "--debug-seed-transcript", "2.5"])
    XCTAssertNil(fractionalCounts.debugFailRecognition)
    XCTAssertNil(fractionalCounts.debugSeedTranscript)
  }

  func testBothOptionsDefaultOff() {
    let options = MeetingRuntimeOptions.parse(environment: [:], arguments: ["LocalFlow"])
    XCTAssertNil(options.storageRootOverride)
    XCTAssertFalse(options.debugSlowFinalize)
  }

  func testRootOverrideIsIgnoredUnlessAbsolute() {
    for relative in ["Meetings", "./Meetings", "~/Meetings", ""] {
      let options = MeetingRuntimeOptions.parse(
        environment: [MeetingRuntimeOptions.rootVariable: relative], arguments: [])
      XCTAssertNil(options.storageRootOverride, relative)
    }
    let absolute = MeetingRuntimeOptions.parse(
      environment: [MeetingRuntimeOptions.rootVariable: "/Volumes/Spike/Meetings"], arguments: [])
    XCTAssertEqual(absolute.storageRootOverride?.path, "/Volumes/Spike/Meetings")
  }

  func testSlowFinalizeIsAnExplicitDebugArgument() {
    let options = MeetingRuntimeOptions.parse(
      environment: [:], arguments: ["LocalFlow", MeetingRuntimeOptions.slowFinalizeFlag])
    XCTAssertEqual(options.debugSlowFinalize, MeetingRuntimeOptions.slowFinalizeSupported)
    XCTAssertFalse(
      MeetingRuntimeOptions.parse(environment: [:], arguments: ["LocalFlow", "--debug-slow"])
        .debugSlowFinalize)
  }
}
